#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/session.h"
#include "multipoint/protocol/session_crypto.h"
#include "multipoint/transport/receiver_engine.h"

#include <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

constexpr std::size_t kRingCapacityFrames = 48'000;
constexpr std::size_t kMaxRenderFrames = 8'192;
constexpr std::uint32_t kHardResyncGapPackets = 20;
volatile std::sig_atomic_t g_running = 1;

void handle_signal(int) { g_running = 0; }

NSString* persistent_receiver_id() {
    NSUserDefaults* defaults = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.skandavyas.soundmux"];
    NSString* value = [defaults stringForKey:@"soundMuxDeviceID"];
    if (!value.length) {
        value = NSUUID.UUID.UUIDString;
        [defaults setObject:value forKey:@"soundMuxDeviceID"];
    }
    return value;
}

NSString* receiver_device_name() {
    NSString* value = NSHost.currentHost.localizedName;
    return value.length ? value : @"Mac";
}

multipoint::protocol::DeviceKeyPair persistent_receiver_key() {
    NSDictionary* query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.skandavyas.soundmux.device-key",
        (__bridge id)kSecAttrAccount: @"mac-receiver",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = nullptr;
    const auto status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess) {
        NSData* data = CFBridgingRelease(result);
        if (data.length != multipoint::protocol::kCryptoKeyBytes) {
            throw std::runtime_error("stored receiver key has the wrong size");
        }
        multipoint::protocol::CryptoKey secret{};
        std::memcpy(secret.data(), data.bytes, secret.size());
        return {secret, multipoint::protocol::public_key_for(secret)};
    }
    if (status != errSecItemNotFound) {
        throw std::runtime_error("could not read receiver identity from Keychain");
    }
    auto pair = multipoint::protocol::generate_device_key_pair();
    NSData* data = [NSData dataWithBytes:pair.secret.data() length:pair.secret.size()];
    NSDictionary* add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.skandavyas.soundmux.device-key",
        (__bridge id)kSecAttrAccount: @"mac-receiver",
        (__bridge id)kSecAttrAccessible:
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        (__bridge id)kSecValueData: data,
    };
    if (SecItemAdd((__bridge CFDictionaryRef)add, nullptr) != errSecSuccess) {
        throw std::runtime_error("could not save receiver identity in Keychain");
    }
    return pair;
}

std::optional<multipoint::protocol::CryptoKey> trusted_sender_key(
    const std::string& sender_id) {
    NSDictionary* trusted = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"macReceiverTrustedKeys"];
    NSString* identifier = [NSString stringWithUTF8String:sender_id.c_str()];
    NSString* encoded = trusted[identifier];
    if (![encoded isKindOfClass:NSString.class]) return std::nullopt;
    multipoint::protocol::CryptoKey key{};
    return multipoint::protocol::hex_decode(encoded.UTF8String, key)
        ? std::optional(key) : std::nullopt;
}

void remember_sender_key(
    const std::string& sender_id,
    const multipoint::protocol::CryptoKey& key) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary* trusted = [[defaults dictionaryForKey:@"macReceiverTrustedKeys"]
        mutableCopy];
    if (!trusted) trusted = [NSMutableDictionary dictionary];
    NSString* identifier = [NSString stringWithUTF8String:sender_id.c_str()];
    trusted[identifier] = [NSString stringWithUTF8String:
        multipoint::protocol::hex_encode(key).c_str()];
    [defaults setObject:trusted forKey:@"macReceiverTrustedKeys"];
}

NSData* receiver_txt_record(
    NSString* identifier,
    NSString* name,
    const multipoint::protocol::CryptoKey& public_key) {
    NSDictionary<NSString*, NSString*>* text = @{
        @"id": identifier,
        @"name": name,
        @"platform": @"macos",
        @"protocol": @"3",
        @"session": @"3",
        @"security": @"x25519+xchacha20poly1305",
        @"public_key": [NSString stringWithUTF8String:
            multipoint::protocol::hex_encode(public_key).c_str()],
        @"capabilities": @"audio,latency,pairing,encryption",
        @"pairing": @"approval",
    };
    NSMutableDictionary<NSString*, NSData*>* encoded = [NSMutableDictionary dictionary];
    for (NSString* key in text) {
        encoded[key] = [text[key] dataUsingEncoding:NSUTF8StringEncoding];
    }
    return [NSNetService dataFromTXTRecordDictionary:encoded];
}

struct AudioState {
    multipoint::audio::SpscAudioRing ring{
        kRingCapacityFrames,
        multipoint::protocol::kChannelCount};
    std::vector<float> scratch = std::vector<float>(
        kMaxRenderFrames * multipoint::protocol::kChannelCount,
        0.0F);
    std::atomic<bool> playout_active{false};
};

OSStatus render_audio(
    void* context,
    AudioUnitRenderActionFlags*,
    const AudioTimeStamp*,
    UInt32,
    UInt32 frame_count,
    AudioBufferList* output) {
    auto& state = *static_cast<AudioState*>(context);
    if (!state.playout_active.load(std::memory_order_acquire) ||
        frame_count > kMaxRenderFrames) {
        for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
            std::memset(output->mBuffers[index].mData, 0, output->mBuffers[index].mDataByteSize);
        }
        return noErr;
    }

    state.ring.read(state.scratch.data(), frame_count);
    if (output->mNumberBuffers == 1) {
        const auto byte_count = static_cast<std::size_t>(frame_count) *
            multipoint::protocol::kChannelCount * sizeof(float);
        std::memcpy(output->mBuffers[0].mData, state.scratch.data(), byte_count);
    } else {
        const auto channels = std::min<UInt32>(
            output->mNumberBuffers,
            multipoint::protocol::kChannelCount);
        for (UInt32 channel = 0; channel < channels; ++channel) {
            auto* destination = static_cast<float*>(output->mBuffers[channel].mData);
            for (UInt32 frame = 0; frame < frame_count; ++frame) {
                destination[frame] = state.scratch[
                    static_cast<std::size_t>(frame) *
                    multipoint::protocol::kChannelCount + channel];
            }
        }
    }
    return noErr;
}

void check_status(OSStatus status, const char* operation) {
    if (status != noErr) {
        throw std::runtime_error(std::string(operation) + " failed: " + std::to_string(status));
    }
}

class DefaultOutput {
public:
    explicit DefaultOutput(AudioState& state) {
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = kAudioUnitSubType_DefaultOutput;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        const auto component = AudioComponentFindNext(nullptr, &description);
        if (!component) throw std::runtime_error("default output AudioUnit not found");
        check_status(AudioComponentInstanceNew(component, &unit_), "create AudioUnit");

        AudioStreamBasicDescription format{};
        format.mSampleRate = multipoint::protocol::kSampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = sizeof(float) * multipoint::protocol::kChannelCount;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = sizeof(float) * multipoint::protocol::kChannelCount;
        format.mChannelsPerFrame = multipoint::protocol::kChannelCount;
        format.mBitsPerChannel = 32;
        check_status(
            AudioUnitSetProperty(
                unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, sizeof(format)),
            "set AudioUnit format");

        AURenderCallbackStruct callback{
            .inputProc = render_audio,
            .inputProcRefCon = &state,
        };
        check_status(
            AudioUnitSetProperty(
                unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, sizeof(callback)),
            "set render callback");
        check_status(AudioUnitInitialize(unit_), "initialize AudioUnit");
        check_status(AudioOutputUnitStart(unit_), "start AudioUnit");
    }

    ~DefaultOutput() {
        if (unit_) {
            AudioOutputUnitStop(unit_);
            AudioUnitUninitialize(unit_);
            AudioComponentInstanceDispose(unit_);
        }
    }

private:
    AudioUnit unit_ = nullptr;
};

}  // namespace

int main(int argc, char** argv) {
    try {
        const auto port = static_cast<std::uint16_t>(argc > 1 ? std::stoi(argv[1]) : 48100);
        const auto target_latency_ms = argc > 2 ? std::stoi(argv[2]) : 40;
        const auto recovery_grace_ms = argc > 3 ? std::stoi(argv[3]) : 30;
        const auto packet_ms = 1000.0 * multipoint::protocol::kFramesPerPacket /
            multipoint::protocol::kSampleRate;
        const auto target_packets = std::max<std::size_t>(
            1, static_cast<std::size_t>(target_latency_ms / packet_ms));
        const auto reorder_packets = std::min<std::size_t>(
            8, std::max<std::size_t>(1, target_packets / 4));

        multipoint::network::UdpReceiver receiver(port);
        const auto receiver_key = persistent_receiver_key();
        NSString* receiver_id = persistent_receiver_id();
        NSString* receiver_name = receiver_device_name();
        NSNetService* discovery = [[NSNetService alloc]
            initWithDomain:@"local."
                      type:@"_soundmux._udp."
                      name:[NSString stringWithFormat:@"%@ · SoundMux", receiver_name]
                      port:port];
        [discovery setTXTRecordData:receiver_txt_record(
            receiver_id, receiver_name, receiver_key.public_key)];
        [discovery publish];
        multipoint::transport::ReceiverEngine transport({
            .reorder_packets = reorder_packets,
            .capacity_packets = 512,
            .hard_resync_gap_packets = kHardResyncGapPackets,
            .maximum_fec_groups = 128,
        });
        AudioState audio;
        DefaultOutput output(audio);
        std::atomic<bool> receive_running{true};

        std::string active_sender_id;
        multipoint::protocol::CryptoKey active_sender_public{};
        multipoint::protocol::CryptoNonce active_client_nonce{};
        multipoint::protocol::CryptoNonce active_server_nonce{};
        std::optional<multipoint::protocol::SessionSecrets> active_secrets;
        std::unique_ptr<multipoint::protocol::SessionCipher> inbound_cipher;
        std::unique_ptr<multipoint::protocol::SessionCipher> outbound_cipher;
        std::uint16_t active_reply_port = 0;

        std::thread receive_thread([&] {
            std::array<std::byte, 2'048> datagram{};
            while (receive_running.load(std::memory_order_relaxed)) {
                try {
                    multipoint::network::UdpEndpoint source;
                    const auto size = receiver.receive_from(datagram, source);
                    if (size == 0) continue;
                    const auto session = multipoint::protocol::deserialize_session(
                        std::span<const std::byte>(datagram.data(), size));
                    if (session.recognized) {
                        if (!session.valid) continue;
                        const auto reply_port_field =
                            session.message.fields.find("reply_port");
                        std::uint16_t reply_port = 0;
                        if (reply_port_field != session.message.fields.end()) {
                            const auto parsed = std::stoi(reply_port_field->second);
                            if (parsed > 0 && parsed <= 65'535) {
                                reply_port = static_cast<std::uint16_t>(parsed);
                            }
                        }
                        if (session.message.type ==
                            multipoint::protocol::SessionMessageType::hello) {
                            const auto& fields = session.message.fields;
                            if (reply_port == 0 || !fields.contains("device_id") ||
                                !fields.contains("name") ||
                                !fields.contains("public_key") ||
                                !fields.contains("client_nonce") ||
                                !fields.contains("session") ||
                                fields.at("session") != "3") continue;
                            const auto sender_id = fields.at("device_id");
                            multipoint::protocol::CryptoKey sender_public{};
                            multipoint::protocol::CryptoNonce client_nonce{};
                            if (!multipoint::protocol::hex_decode(
                                    fields.at("public_key"), sender_public) ||
                                !multipoint::protocol::hex_decode(
                                    fields.at("client_nonce"), client_nonce)) continue;

                            if (active_secrets && sender_id == active_sender_id &&
                                sender_public == active_sender_public &&
                                client_nonce == active_client_nonce) {
                                active_reply_port = reply_port;
                            } else {
                                const auto trusted = trusted_sender_key(sender_id);
                                if (trusted && *trusted != sender_public) {
                                    const auto rejected =
                                        multipoint::protocol::serialize_session({
                                            .type = multipoint::protocol::
                                                SessionMessageType::rejected,
                                            .fields = {{"reason", "Sender security key changed"}},
                                        });
                                    receiver.send_to(rejected, source, reply_port);
                                    continue;
                                }
                                multipoint::protocol::CryptoNonce server_nonce{};
                                if (!multipoint::protocol::secure_random(server_nonce)) {
                                    continue;
                                }
                                const auto code = multipoint::protocol::pairing_code(
                                    sender_public, receiver_key.public_key);
                                if (!trusted) {
                                    const auto required =
                                        multipoint::protocol::serialize_session({
                                            .type = multipoint::protocol::
                                                SessionMessageType::pair_required,
                                            .fields = {
                                                {"receiver_id", receiver_id.UTF8String},
                                                {"receiver_name", receiver_name.UTF8String},
                                                {"platform", "macos"},
                                                {"public_key", multipoint::protocol::
                                                    hex_encode(receiver_key.public_key)},
                                                {"server_nonce", multipoint::protocol::
                                                    hex_encode(server_nonce)},
                                                {"code", code},
                                            },
                                        });
                                    receiver.send_to(required, source, reply_port);
                                    std::cout << "Pair " << fields.at("name")
                                              << " with code " << code
                                              << ". Type yes to approve: " << std::flush;
                                    std::string answer;
                                    std::getline(std::cin, answer);
                                    if (answer != "yes" && answer != "y") {
                                        const auto rejected =
                                            multipoint::protocol::serialize_session({
                                                .type = multipoint::protocol::
                                                    SessionMessageType::rejected,
                                                .fields = {{"reason", "Pairing declined"}},
                                            });
                                        receiver.send_to(rejected, source, reply_port);
                                        continue;
                                    }
                                    remember_sender_key(sender_id, sender_public);
                                }
                                const auto secrets =
                                    multipoint::protocol::derive_session_secrets(
                                        receiver_key.secret, sender_public, sender_public,
                                        receiver_key.public_key, client_nonce, server_nonce);
                                active_sender_id = sender_id;
                                active_sender_public = sender_public;
                                active_client_nonce = client_nonce;
                                active_server_nonce = server_nonce;
                                active_secrets = secrets;
                                inbound_cipher = std::make_unique<
                                    multipoint::protocol::SessionCipher>(
                                        secrets.sender_to_receiver_key,
                                        secrets.sender_nonce_prefix);
                                outbound_cipher = std::make_unique<
                                    multipoint::protocol::SessionCipher>(
                                        secrets.receiver_to_sender_key,
                                        secrets.receiver_nonce_prefix);
                                active_reply_port = reply_port;
                            }
                            if (!active_secrets) continue;
                            const auto welcome = multipoint::protocol::serialize_session({
                                .type = multipoint::protocol::SessionMessageType::welcome,
                                .fields = {
                                    {"receiver_id", receiver_id.UTF8String},
                                    {"receiver_name", receiver_name.UTF8String},
                                    {"platform", "macos"},
                                    {"protocol", "3"},
                                    {"session", "3"},
                                    {"public_key", multipoint::protocol::
                                        hex_encode(receiver_key.public_key)},
                                    {"server_nonce", multipoint::protocol::
                                        hex_encode(active_server_nonce)},
                                    {"proof", multipoint::protocol::
                                        hex_encode(active_secrets->welcome_proof)},
                                    {"heartbeat_ms", "1000"},
                                    {"capabilities", "audio,latency,pairing,encryption"},
                                    {"pairing", "approval"},
                                },
                            });
                            receiver.send_to(welcome, source, reply_port);
                        }
                        continue;
                    }
                    if (!inbound_cipher) continue;
                    auto opened = inbound_cipher->decrypt(
                        std::span<const std::byte>(datagram.data(), size));
                    if (!opened.valid) continue;
                    const auto secure_session = multipoint::protocol::deserialize_session(
                        opened.plaintext);
                    if (secure_session.valid && secure_session.message.type ==
                        multipoint::protocol::SessionMessageType::ping) {
                        if (!outbound_cipher || active_reply_port == 0) continue;
                        const auto pong = multipoint::protocol::serialize_session({
                            .type = multipoint::protocol::SessionMessageType::pong,
                            .fields = {
                                {"receiver_id", receiver_id.UTF8String},
                                {"counter", secure_session.message.fields.contains("counter")
                                    ? secure_session.message.fields.at("counter") : "0"},
                            },
                        });
                        receiver.send_to(
                            outbound_cipher->encrypt(pong), source, active_reply_port);
                        continue;
                    }
                    const auto arrival_ns = static_cast<std::uint64_t>(
                        std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now().time_since_epoch()).count());
                    const auto result = transport.ingest(
                        opened.plaintext, arrival_ns);
                    if (result.first_valid_datagram) {
                        std::cout << "First valid UDP audio datagram received ("
                                  << size << " bytes)\n";
                    }
                    if (!result.error.empty()) {
                        const auto stats = transport.snapshot();
                        if (stats.malformed_packets == 1 ||
                            stats.malformed_packets % 100 == 0) {
                            std::cerr << "raw_udp=" << stats.raw_datagrams
                                      << " bytes=" << size
                                      << " malformed=" << stats.malformed_packets
                                      << " decode_error=\"" << result.error << "\"\n";
                        }
                    }
                    if (result.hard_resync) {
                        std::cerr << "Transport hard resync requested\n";
                    }
                } catch (const std::exception& error) {
                    std::cerr << "network receive error: " << error.what() << '\n';
                }
            }
        });

        std::signal(SIGINT, handle_signal);
        std::signal(SIGTERM, handle_signal);
        std::cout << "multipoint receiver listening on UDP port " << port << '\n'
                  << "Format: 48 kHz stereo PCM16 wire / float32 output, "
                  << multipoint::protocol::kFramesPerPacket << " frames/packet\n"
                  << "Target jitter buffer: " << target_packets << " packets ("
                  << target_packets * packet_ms << " ms)\n"
                  << "Reorder reserve: " << reorder_packets << " packets ("
                  << reorder_packets * packet_ms << " ms)\n"
                  << "Missing-packet recovery grace: " << recovery_grace_ms << " ms\n"
                  << "Using the current macOS default output. Ctrl-C to stop.\n";

        std::vector<float> concealment(multipoint::protocol::kSamplesPerPacket, 0.0F);
        constexpr std::size_t plc_history_packets = 4;
        std::vector<float> plc_history(
            multipoint::protocol::kSamplesPerPacket * plc_history_packets, 0.0F);
        std::size_t plc_history_write = 0;
        std::size_t plc_history_samples = 0;
        std::size_t plc_replay_read = 0;
        std::array<float, multipoint::protocol::kChannelCount> last_output{};
        std::uint64_t concealed_packets = 0;
        const auto ring_packets = std::max<std::size_t>(
            1, target_packets - reorder_packets);
        const auto ring_target_frames =
            ring_packets * multipoint::protocol::kFramesPerPacket;
        auto next_stats = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        bool playout_started = false;
        std::size_t consecutive_missing = 0;
        std::optional<std::chrono::steady_clock::time_point> missing_since;
        bool gap_grace_exhausted = false;
        const auto reorder_grace = std::chrono::milliseconds(recovery_grace_ms);
        std::uint64_t observed_resync_generation = 0;

        while (g_running) {
            @autoreleasepool {
                [NSRunLoop.currentRunLoop
                    runMode:NSDefaultRunLoopMode
                    beforeDate:[NSDate date]];
            }
            const auto transport_snapshot = transport.snapshot();
            const auto current_resync_generation =
                transport_snapshot.resync_generation;
            if (current_resync_generation != observed_resync_generation) {
                audio.playout_active.store(false, std::memory_order_release);
                audio.ring.discard();
                playout_started = false;
                consecutive_missing = 0;
                missing_since.reset();
                gap_grace_exhausted = false;
                plc_history_write = 0;
                plc_history_samples = 0;
                plc_replay_read = 0;
                std::fill(plc_history.begin(), plc_history.end(), 0.0F);
                last_output.fill(0.0F);
                observed_resync_generation = current_resync_generation;
            }
            // CoreAudio is the playout clock. Keep a small amount of decoded
            // audio ahead of its render callback instead of independently
            // popping the jitter buffer from a sleep-based wall clock. The
            // latter can run in destructive catch-up bursts after a stall.
            if (playout_started &&
                audio.ring.available_to_read() >= ring_target_frames) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            } else {
            // Keep a generous emergency ceiling. Normal clock drift must be
            // corrected gradually; bulk-dropping at twice the target produced
            // an audible discontinuity during short Wi-Fi stalls.
            if (transport_snapshot.depth > target_packets * 4) {
                const auto discarded =
                    transport.discard_oldest_until(target_packets * 2);
                (void)discarded;
            }
            auto result = transport.pop(false);
            if (result.status == multipoint::jitter::PopStatus::not_ready &&
                transport_snapshot.started) {
                if (gap_grace_exhausted) {
                    result = transport.pop(true);
                } else {
                    const auto now = std::chrono::steady_clock::now();
                    if (!missing_since) missing_since = now;
                    if (now - *missing_since >= reorder_grace) {
                        gap_grace_exhausted = true;
                        result = transport.pop(true);
                    }
                }
            } else if (result.packet) {
                missing_since.reset();
                gap_grace_exhausted = false;
            }
            if (result.status == multipoint::jitter::PopStatus::not_ready) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            if (result.packet) {
                auto& samples = result.packet->interleaved_samples;
                if (consecutive_missing > 0) {
                    constexpr std::size_t fade_frames = 48;
                    for (std::size_t frame = 0; frame < fade_frames; ++frame) {
                        const auto gain = static_cast<float>(frame + 1) /
                            static_cast<float>(fade_frames);
                        for (std::size_t channel = 0;
                             channel < multipoint::protocol::kChannelCount;
                             ++channel) {
                            const auto index = frame *
                                multipoint::protocol::kChannelCount + channel;
                            samples[index] = last_output[channel] * (1.0F - gain) +
                                samples[index] * gain;
                        }
                    }
                }
                consecutive_missing = 0;
                audio.ring.write(
                    samples.data(),
                    multipoint::protocol::kFramesPerPacket);
                for (const auto sample : samples) {
                    plc_history[plc_history_write] = sample;
                    plc_history_write = (plc_history_write + 1) % plc_history.size();
                    plc_history_samples = std::min(
                        plc_history_samples + 1, plc_history.size());
                }
                for (std::size_t channel = 0;
                     channel < multipoint::protocol::kChannelCount;
                     ++channel) {
                    last_output[channel] = samples[
                        (multipoint::protocol::kFramesPerPacket - 1) *
                        multipoint::protocol::kChannelCount + channel];
                }
            } else {
                ++consecutive_missing;
                ++concealed_packets;
                std::fill(concealment.begin(), concealment.end(), 0.0F);
                constexpr std::size_t maximum_replay_packets = 10;
                if (plc_history_samples == plc_history.size() &&
                    consecutive_missing <= maximum_replay_packets) {
                    if (consecutive_missing == 1) {
                        plc_replay_read = plc_history_write;
                    }
                    for (auto& sample : concealment) {
                        sample = plc_history[plc_replay_read];
                        plc_replay_read = (plc_replay_read + 1) % plc_history.size();
                    }

                    if (consecutive_missing == 1) {
                        constexpr std::size_t fade_frames = 48;
                        for (std::size_t frame = 0; frame < fade_frames; ++frame) {
                            const auto gain = static_cast<float>(frame + 1) /
                                static_cast<float>(fade_frames);
                            for (std::size_t channel = 0;
                                 channel < multipoint::protocol::kChannelCount;
                                 ++channel) {
                                const auto index = frame *
                                    multipoint::protocol::kChannelCount + channel;
                                concealment[index] = last_output[channel] * (1.0F - gain) +
                                    concealment[index] * gain;
                            }
                        }
                    }

                    if (consecutive_missing > maximum_replay_packets - 2) {
                        const auto packets_into_fade = consecutive_missing -
                            (maximum_replay_packets - 2);
                        for (std::size_t frame = 0;
                             frame < multipoint::protocol::kFramesPerPacket;
                             ++frame) {
                            const auto fade_position =
                                (packets_into_fade - 1) *
                                    multipoint::protocol::kFramesPerPacket + frame + 1;
                            const auto fade_total = 2 *
                                multipoint::protocol::kFramesPerPacket;
                            const auto gain = std::max(
                                0.0F,
                                1.0F - static_cast<float>(fade_position) /
                                    static_cast<float>(fade_total));
                            for (std::size_t channel = 0;
                                 channel < multipoint::protocol::kChannelCount;
                                 ++channel) {
                                concealment[frame *
                                    multipoint::protocol::kChannelCount + channel] *= gain;
                            }
                        }
                    }
                }
                audio.ring.write(
                    concealment.data(), multipoint::protocol::kFramesPerPacket);
                for (std::size_t channel = 0;
                     channel < multipoint::protocol::kChannelCount;
                     ++channel) {
                    last_output[channel] = concealment[
                        (multipoint::protocol::kFramesPerPacket - 1) *
                        multipoint::protocol::kChannelCount + channel];
                }
            }

            if (!playout_started &&
                audio.ring.available_to_read() >= ring_target_frames) {
                    playout_started = true;
                    audio.playout_active.store(true, std::memory_order_release);
                    next_stats = std::chrono::steady_clock::now() +
                        std::chrono::seconds(1);
            }

            if (consecutive_missing >= reorder_packets) {
                const bool empty = transport.snapshot().depth == 0;
                bool advanced = false;
                if (empty) {
                    transport.rebuffer();
                } else {
                    advanced = transport.advance_to_oldest_available();
                }
                if (empty) {
                    audio.playout_active.store(false, std::memory_order_release);
                    audio.ring.discard();
                    playout_started = false;
                    consecutive_missing = 0;
                    missing_since.reset();
                    gap_grace_exhausted = false;
                    continue;
                }
                if (advanced) consecutive_missing = 0;
            }
            }
            const auto stats_now = std::chrono::steady_clock::now();
            if (stats_now >= next_stats) {
                const auto receiver_stats = transport.snapshot();
                const auto& stats = receiver_stats.jitter;
                std::cout << "received=" << stats.packets_received
                          << " raw_udp=" << receiver_stats.raw_datagrams
                          << " raw_bytes=" << receiver_stats.raw_bytes
                          << " lost=" << stats.packets_lost
                          << " reordered=" << stats.packets_reordered
                          << " late=" << stats.late_packets
                          << " duplicate=" << stats.duplicate_packets
                          << " overflow=" << stats.overflow_drops
                          << " latency_drop=" << stats.latency_drops
                          << " concealed=" << concealed_packets
                          << " fec_recovered=" << receiver_stats.fec_recovered
                          << " hard_resyncs=" << receiver_stats.hard_resyncs
                          << " max_arrival_gap_ms=" << std::fixed
                          << std::setprecision(1)
                          << static_cast<double>(receiver_stats.max_arrival_gap_ns) /
                              1'000'000.0
                          << " arrival_gap_events=" << receiver_stats.arrival_gap_events
                          << " stale_stream=" << receiver_stats.stale_stream_packets
                          << " depth=" << receiver_stats.depth
                          << " ring_frames=" << audio.ring.available_to_read()
                          << " underruns=" << audio.ring.underruns()
                          << " malformed=" << receiver_stats.malformed_packets << '\n';
                next_stats = stats_now + std::chrono::seconds(1);
            }
        }

        receive_running.store(false, std::memory_order_relaxed);
        receive_thread.join();
        [discovery stop];
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "receiver error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
