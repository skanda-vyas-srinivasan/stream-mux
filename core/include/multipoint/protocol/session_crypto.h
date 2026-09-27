#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace multipoint::protocol {

inline constexpr std::size_t kCryptoKeyBytes = 32;
inline constexpr std::size_t kCryptoNonceBytes = 16;
inline constexpr std::size_t kCryptoProofBytes = 32;
inline constexpr std::size_t kEncryptedHeaderBytes = 16;
inline constexpr std::size_t kEncryptedTagBytes = 16;
inline constexpr std::size_t kEncryptedOverheadBytes =
    kEncryptedHeaderBytes + kEncryptedTagBytes;

using CryptoKey = std::array<std::byte, kCryptoKeyBytes>;
using CryptoNonce = std::array<std::byte, kCryptoNonceBytes>;
using CryptoProof = std::array<std::byte, kCryptoProofBytes>;

struct DeviceKeyPair {
    CryptoKey secret;
    CryptoKey public_key;
};

struct SessionSecrets {
    CryptoKey sender_to_receiver_key;
    CryptoKey receiver_to_sender_key;
    CryptoNonce sender_nonce_prefix;
    CryptoNonce receiver_nonce_prefix;
    CryptoProof welcome_proof;
};

struct DecryptResult {
    bool recognized = false;
    bool valid = false;
    std::vector<std::byte> plaintext;
    std::string error;
};

[[nodiscard]] bool secure_random(std::span<std::byte> destination);
[[nodiscard]] DeviceKeyPair generate_device_key_pair();
[[nodiscard]] CryptoKey public_key_for(const CryptoKey& secret_key);
[[nodiscard]] SessionSecrets derive_session_secrets(
    const CryptoKey& local_secret_key,
    const CryptoKey& remote_public_key,
    const CryptoKey& sender_public_key,
    const CryptoKey& receiver_public_key,
    const CryptoNonce& client_nonce,
    const CryptoNonce& server_nonce);
[[nodiscard]] std::string pairing_code(
    const CryptoKey& sender_public_key,
    const CryptoKey& receiver_public_key);
[[nodiscard]] std::string hex_encode(std::span<const std::byte> bytes);
[[nodiscard]] bool hex_decode(std::string_view text, std::span<std::byte> output);
[[nodiscard]] bool proof_matches(const CryptoProof& expected, const CryptoProof& actual);

class SessionCipher {
public:
    SessionCipher(CryptoKey key, CryptoNonce nonce_prefix);
    ~SessionCipher();
    SessionCipher(const SessionCipher&) = delete;
    SessionCipher& operator=(const SessionCipher&) = delete;
    SessionCipher(SessionCipher&&) noexcept;
    SessionCipher& operator=(SessionCipher&&) noexcept;

    [[nodiscard]] std::vector<std::byte> encrypt(
        std::span<const std::byte> plaintext);
    [[nodiscard]] DecryptResult decrypt(std::span<const std::byte> datagram);

private:
    CryptoKey key_{};
    CryptoNonce nonce_prefix_{};
    std::uint64_t send_counter_ = 0;
    std::uint64_t highest_received_ = 0;
    std::uint64_t received_window_ = 0;
    bool has_received_ = false;
};

}  // namespace multipoint::protocol
