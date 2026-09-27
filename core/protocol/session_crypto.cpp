#include "multipoint/protocol/session_crypto.h"

#include "monocypher.h"

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#else
#include <stdlib.h>
#endif

#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>
#include <utility>

namespace multipoint::protocol {
namespace {

constexpr std::array<std::byte, 4> kEncryptedMagic = {
    std::byte{'S'}, std::byte{'M'}, std::byte{'E'}, std::byte{'1'},
};

const std::uint8_t* bytes(const std::byte* value) {
    return reinterpret_cast<const std::uint8_t*>(value);
}

std::uint8_t* bytes(std::byte* value) {
    return reinterpret_cast<std::uint8_t*>(value);
}

template <std::size_t Size>
void hash_part(crypto_blake2b_ctx& context, const std::array<std::byte, Size>& part) {
    crypto_blake2b_update(&context, bytes(part.data()), part.size());
}

CryptoProof keyed_hash(
    const CryptoKey& key,
    std::string_view label,
    std::span<const std::byte> content = {}) {
    CryptoProof output{};
    crypto_blake2b_ctx context;
    crypto_blake2b_keyed_init(&context, output.size(), bytes(key.data()), key.size());
    crypto_blake2b_update(
        &context, reinterpret_cast<const std::uint8_t*>(label.data()), label.size());
    if (!content.empty()) {
        crypto_blake2b_update(&context, bytes(content.data()), content.size());
    }
    crypto_blake2b_final(&context, bytes(output.data()));
    return output;
}

CryptoNonce nonce_prefix(const CryptoKey& key, std::string_view label) {
    const auto digest = keyed_hash(key, label);
    CryptoNonce output{};
    std::copy_n(digest.begin(), output.size(), output.begin());
    return output;
}

void store_u64_be(std::byte* output, std::uint64_t value) {
    for (int index = 7; index >= 0; --index) {
        output[index] = static_cast<std::byte>(value & 0xffU);
        value >>= 8U;
    }
}

std::uint64_t load_u64_be(const std::byte* input) {
    std::uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value = (value << 8U) | std::to_integer<std::uint8_t>(input[index]);
    }
    return value;
}

std::array<std::uint8_t, 24> make_nonce(
    const CryptoNonce& prefix,
    std::uint64_t counter) {
    std::array<std::uint8_t, 24> nonce{};
    std::memcpy(nonce.data(), prefix.data(), prefix.size());
    for (int index = 23; index >= 16; --index) {
        nonce[static_cast<std::size_t>(index)] = static_cast<std::uint8_t>(counter & 0xffU);
        counter >>= 8U;
    }
    return nonce;
}

bool is_all_zero(const CryptoKey& key) {
    std::byte combined{};
    for (const auto value : key) combined |= value;
    return combined == std::byte{};
}

}  // namespace

bool secure_random(std::span<std::byte> destination) {
    if (destination.empty()) return true;
#ifdef _WIN32
    return BCryptGenRandom(
               nullptr, bytes(destination.data()),
               static_cast<ULONG>(destination.size()),
               BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#else
    arc4random_buf(destination.data(), destination.size());
    return true;
#endif
}

DeviceKeyPair generate_device_key_pair() {
    DeviceKeyPair pair{};
    if (!secure_random(pair.secret)) throw std::runtime_error("secure random failed");
    pair.public_key = public_key_for(pair.secret);
    return pair;
}

CryptoKey public_key_for(const CryptoKey& secret_key) {
    CryptoKey output{};
    crypto_x25519_public_key(bytes(output.data()), bytes(secret_key.data()));
    return output;
}

SessionSecrets derive_session_secrets(
    const CryptoKey& local_secret_key,
    const CryptoKey& remote_public_key,
    const CryptoKey& sender_public_key,
    const CryptoKey& receiver_public_key,
    const CryptoNonce& client_nonce,
    const CryptoNonce& server_nonce) {
    CryptoKey shared{};
    crypto_x25519(
        bytes(shared.data()), bytes(local_secret_key.data()),
        bytes(remote_public_key.data()));
    if (is_all_zero(shared)) {
        crypto_wipe(shared.data(), shared.size());
        throw std::invalid_argument("invalid remote public key");
    }

    std::array<std::byte, 64> root{};
    crypto_blake2b_ctx context;
    crypto_blake2b_init(&context, root.size());
    constexpr std::string_view label = "SoundMux session v3";
    crypto_blake2b_update(
        &context, reinterpret_cast<const std::uint8_t*>(label.data()), label.size());
    hash_part(context, shared);
    hash_part(context, sender_public_key);
    hash_part(context, receiver_public_key);
    hash_part(context, client_nonce);
    hash_part(context, server_nonce);
    crypto_blake2b_final(&context, bytes(root.data()));
    crypto_wipe(shared.data(), shared.size());

    SessionSecrets result{};
    std::copy_n(root.begin(), result.sender_to_receiver_key.size(),
                result.sender_to_receiver_key.begin());
    std::copy_n(root.begin() + 32, result.receiver_to_sender_key.size(),
                result.receiver_to_sender_key.begin());
    result.sender_nonce_prefix = nonce_prefix(
        result.sender_to_receiver_key, "SoundMux sender nonce");
    result.receiver_nonce_prefix = nonce_prefix(
        result.receiver_to_sender_key, "SoundMux receiver nonce");
    result.welcome_proof = keyed_hash(
        result.receiver_to_sender_key, "SoundMux welcome proof",
        std::span<const std::byte>(root.data(), root.size()));
    crypto_wipe(root.data(), root.size());
    return result;
}

std::string pairing_code(
    const CryptoKey& sender_public_key,
    const CryptoKey& receiver_public_key) {
    std::array<std::byte, 8> digest{};
    crypto_blake2b_ctx context;
    crypto_blake2b_init(&context, digest.size());
    constexpr std::string_view label = "SoundMux pairing v1";
    crypto_blake2b_update(
        &context, reinterpret_cast<const std::uint8_t*>(label.data()), label.size());
    hash_part(context, sender_public_key);
    hash_part(context, receiver_public_key);
    crypto_blake2b_final(&context, bytes(digest.data()));
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) {
        value = (value << 8U) | std::to_integer<std::uint8_t>(digest[index]);
    }
    value %= 1'000'000U;
    std::string output = std::to_string(value);
    output.insert(output.begin(), 6 - output.size(), '0');
    return output;
}

std::string hex_encode(std::span<const std::byte> input) {
    constexpr char digits[] = "0123456789abcdef";
    std::string output(input.size() * 2, '0');
    for (std::size_t index = 0; index < input.size(); ++index) {
        const auto value = std::to_integer<unsigned>(input[index]);
        output[index * 2] = digits[value >> 4U];
        output[index * 2 + 1] = digits[value & 0x0fU];
    }
    return output;
}

bool hex_decode(std::string_view text, std::span<std::byte> output) {
    if (text.size() != output.size() * 2) return false;
    auto nibble = [](char value) -> int {
        if (value >= '0' && value <= '9') return value - '0';
        if (value >= 'a' && value <= 'f') return value - 'a' + 10;
        if (value >= 'A' && value <= 'F') return value - 'A' + 10;
        return -1;
    };
    for (std::size_t index = 0; index < output.size(); ++index) {
        const int high = nibble(text[index * 2]);
        const int low = nibble(text[index * 2 + 1]);
        if (high < 0 || low < 0) return false;
        output[index] = static_cast<std::byte>((high << 4) | low);
    }
    return true;
}

bool proof_matches(const CryptoProof& expected, const CryptoProof& actual) {
    return crypto_verify32(bytes(expected.data()), bytes(actual.data())) == 0;
}

SessionCipher::SessionCipher(CryptoKey key, CryptoNonce nonce_prefix)
    : key_(key), nonce_prefix_(nonce_prefix) {}

SessionCipher::~SessionCipher() {
    crypto_wipe(key_.data(), key_.size());
    crypto_wipe(nonce_prefix_.data(), nonce_prefix_.size());
}

SessionCipher::SessionCipher(SessionCipher&& other) noexcept
    : key_(other.key_),
      nonce_prefix_(other.nonce_prefix_),
      send_counter_(other.send_counter_),
      highest_received_(other.highest_received_),
      received_window_(other.received_window_),
      has_received_(other.has_received_) {
    crypto_wipe(other.key_.data(), other.key_.size());
    crypto_wipe(other.nonce_prefix_.data(), other.nonce_prefix_.size());
}

SessionCipher& SessionCipher::operator=(SessionCipher&& other) noexcept {
    if (this == &other) return *this;
    crypto_wipe(key_.data(), key_.size());
    key_ = other.key_;
    nonce_prefix_ = other.nonce_prefix_;
    send_counter_ = other.send_counter_;
    highest_received_ = other.highest_received_;
    received_window_ = other.received_window_;
    has_received_ = other.has_received_;
    crypto_wipe(other.key_.data(), other.key_.size());
    crypto_wipe(other.nonce_prefix_.data(), other.nonce_prefix_.size());
    return *this;
}

std::vector<std::byte> SessionCipher::encrypt(
    std::span<const std::byte> plaintext) {
    if (send_counter_ == UINT64_MAX) throw std::overflow_error("session nonce exhausted");
    const auto counter = send_counter_++;
    std::vector<std::byte> output(kEncryptedOverheadBytes + plaintext.size());
    std::copy(kEncryptedMagic.begin(), kEncryptedMagic.end(), output.begin());
    output[4] = std::byte{1};
    store_u64_be(output.data() + 8, counter);
    const auto nonce = make_nonce(nonce_prefix_, counter);
    auto* cipher_text = output.data() + kEncryptedHeaderBytes;
    auto* mac = cipher_text + plaintext.size();
    crypto_aead_lock(
        bytes(cipher_text), bytes(mac), bytes(key_.data()), nonce.data(),
        bytes(output.data()), kEncryptedHeaderBytes,
        bytes(plaintext.data()), plaintext.size());
    return output;
}

DecryptResult SessionCipher::decrypt(std::span<const std::byte> datagram) {
    if (datagram.size() < kEncryptedMagic.size() ||
        !std::equal(kEncryptedMagic.begin(), kEncryptedMagic.end(), datagram.begin())) {
        return {};
    }
    if (datagram.size() < kEncryptedOverheadBytes || datagram[4] != std::byte{1}) {
        return {.recognized = true, .error = "invalid encrypted envelope"};
    }
    const auto counter = load_u64_be(datagram.data() + 8);
    if (has_received_) {
        if (counter <= highest_received_) {
            const auto distance = highest_received_ - counter;
            if (distance >= 64 || (received_window_ & (UINT64_C(1) << distance)) != 0) {
                return {.recognized = true, .error = "replayed encrypted datagram"};
            }
        }
    }

    const auto text_size = datagram.size() - kEncryptedOverheadBytes;
    std::vector<std::byte> plaintext(text_size);
    const auto nonce = make_nonce(nonce_prefix_, counter);
    const auto* cipher_text = datagram.data() + kEncryptedHeaderBytes;
    const auto* mac = cipher_text + text_size;
    if (crypto_aead_unlock(
            bytes(plaintext.data()), bytes(mac), bytes(key_.data()), nonce.data(),
            bytes(datagram.data()), kEncryptedHeaderBytes,
            bytes(cipher_text), text_size) != 0) {
        return {.recognized = true, .error = "encrypted datagram authentication failed"};
    }

    if (!has_received_) {
        has_received_ = true;
        highest_received_ = counter;
        received_window_ = 1;
    } else if (counter > highest_received_) {
        const auto shift = counter - highest_received_;
        received_window_ = shift >= 64 ? 1 : (received_window_ << shift) | 1;
        highest_received_ = counter;
    } else {
        received_window_ |= UINT64_C(1) << (highest_received_ - counter);
    }
    return {
        .recognized = true,
        .valid = true,
        .plaintext = std::move(plaintext),
    };
}

}  // namespace multipoint::protocol
