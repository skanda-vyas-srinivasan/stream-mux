#include "receiver_runtime.h"

#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/session.h"
#include "multipoint/protocol/session_crypto.h"
#include "multipoint/transport/receiver_engine.h"

#include <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr std::size_t kRingFrames = 48'000;
constexpr std::size_t kMaxRenderFrames = 8'192;

void check_status(OSStatus status, const char* operation) {
    if (status != noErr) {
        throw std::runtime_error(
            std::string(operation) + " failed: " + std::to_string(status));
    }
}

multipoint::protocol::DeviceKeyPair receiver_device_key() {
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

std::optional<multipoint::protocol::CryptoKey> trusted_key(const std::string& id) {
    NSDictionary* trusted = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"macReceiverTrustedKeys"];
    NSString* identifier = [NSString stringWithUTF8String:id.c_str()];
    NSString* encoded = trusted[identifier];
    if (![encoded isKindOfClass:NSString.class]) return std::nullopt;
    multipoint::protocol::CryptoKey key{};
    return multipoint::protocol::hex_decode(encoded.UTF8String, key)
        ? std::optional(key) : std::nullopt;
}

void remember_key(
    const std::string& id,
    const std::string& name,
    const multipoint::protocol::CryptoKey& key) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary* trusted = [[defaults dictionaryForKey:@"macReceiverTrustedKeys"]
        mutableCopy];
    if (!trusted) trusted = [NSMutableDictionary dictionary];
    NSMutableDictionary* names = [[defaults dictionaryForKey:@"macReceiverTrustedNames"]
        mutableCopy];
    if (!names) names = [NSMutableDictionary dictionary];
    NSString* identifier = [NSString stringWithUTF8String:id.c_str()];
    trusted[identifier] = [NSString stringWithUTF8String:
        multipoint::protocol::hex_encode(key).c_str()];
    names[identifier] = [NSString stringWithUTF8String:name.c_str()];
    [defaults setObject:trusted forKey:@"macReceiverTrustedKeys"];
    [defaults setObject:names forKey:@"macReceiverTrustedNames"];
}

NSData* txt_record(
    const MacReceiverConfig& config,
    const multipoint::protocol::CryptoKey& public_key) {
    NSDictionary<NSString*, NSString*>* text = @{
        @"id": [NSString stringWithUTF8String:config.device_id.c_str()],
        @"name": [NSString stringWithUTF8String:config.device_name.c_str()],
        @"platform": @"macos",
        @"protocol": @"3",
        @"session": @"3",
        @"security": @"x25519+xchacha20poly1305",
        @"public_key": [NSString stringWithUTF8String:
            multipoint::protocol::hex_encode(public_key).c_str()],
        @"capabilities": @"audio,latency,pairing,encryption,volume",
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
        kRingFrames, multipoint::protocol::kChannelCount};
    std::array<float, kMaxRenderFrames * multipoint::protocol::kChannelCount> scratch{};
    std::atomic<bool> playing{false};
    std::atomic<float> volume{1.0F};
};

std::uint64_t now_ns() {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

OSStatus render_audio(
    void* context,
    AudioUnitRenderActionFlags*,
    const AudioTimeStamp*,
    UInt32,
    UInt32 frame_count,
    AudioBufferList* output) {
    auto& state = *static_cast<AudioState*>(context);
    if (!state.playing.load(std::memory_order_acquire) || frame_count > kMaxRenderFrames) {
        for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
            std::memset(
                output->mBuffers[index].mData, 0,
                output->mBuffers[index].mDataByteSize);
        }
        return noErr;
    }
    state.ring.read(state.scratch.data(), frame_count);
    const float volume = state.volume.load(std::memory_order_relaxed);
    for (std::size_t index = 0;
         index < static_cast<std::size_t>(frame_count) * 2; ++index) {
        state.scratch[index] *= volume;
    }
    if (output->mNumberBuffers == 1) {
        std::memcpy(
            output->mBuffers[0].mData, state.scratch.data(),
            static_cast<std::size_t>(frame_count) * 2 * sizeof(float));
    } else {
        for (UInt32 channel = 0; channel < std::min<UInt32>(2, output->mNumberBuffers);
             ++channel) {
            auto* destination = static_cast<float*>(output->mBuffers[channel].mData);
            for (UInt32 frame = 0; frame < frame_count; ++frame) {
                destination[frame] = state.scratch[static_cast<std::size_t>(frame) * 2 + channel];
            }
        }
    }
    return noErr;
}

AudioDeviceID audio_device_for_uid(const std::string& uid) {
    if (uid.empty()) return kAudioObjectUnknown;
    CFStringRef value = CFStringCreateWithCString(
        kCFAllocatorDefault, uid.c_str(), kCFStringEncodingUTF8);
    AudioValueTranslation translation{
        .mInputData = &value,
        .mInputDataSize = sizeof(value),
        .mOutputData = nullptr,
        .mOutputDataSize = sizeof(AudioDeviceID),
    };
    AudioDeviceID device = kAudioObjectUnknown;
    translation.mOutputData = &device;
    AudioObjectPropertyAddress address{
        kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(translation);
    const auto status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, 0, nullptr, &size, &translation);
    CFRelease(value);
    if (status != noErr || device == kAudioObjectUnknown) {
        throw std::runtime_error("selected audio output is no longer available");
    }
    return device;
}

class AudioOutput {
public:
    AudioOutput(AudioState& state, const std::string& device_uid) {
        AudioComponentDescription description{};
        description.componentType = kAudioUnitType_Output;
        description.componentSubType = device_uid.empty()
            ? kAudioUnitSubType_DefaultOutput
            : kAudioUnitSubType_HALOutput;
        description.componentManufacturer = kAudioUnitManufacturer_Apple;
        const auto component = AudioComponentFindNext(nullptr, &description);
        if (!component) throw std::runtime_error("Core Audio output not found");
        check_status(AudioComponentInstanceNew(component, &unit_), "create output");
        if (!device_uid.empty()) {
            UInt32 enabled = 1;
            check_status(AudioUnitSetProperty(
                unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                &enabled, sizeof(enabled)), "enable device output");
            UInt32 disabled = 0;
            check_status(AudioUnitSetProperty(
                unit_, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                &disabled, sizeof(disabled)), "disable device input");
            const auto device = audio_device_for_uid(device_uid);
            check_status(AudioUnitSetProperty(
                unit_, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, sizeof(device)), "select audio output");
        }
        AudioStreamBasicDescription format{};
        format.mSampleRate = multipoint::protocol::kSampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = sizeof(float) * 2;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = sizeof(float) * 2;
        format.mChannelsPerFrame = 2;
        format.mBitsPerChannel = 32;
        check_status(AudioUnitSetProperty(
            unit_, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, sizeof(format)), "configure output");
        AURenderCallbackStruct callback{.inputProc = render_audio, .inputProcRefCon = &state};
        check_status(AudioUnitSetProperty(
            unit_, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, sizeof(callback)), "set output callback");
        check_status(AudioUnitInitialize(unit_), "initialize output");
        check_status(AudioOutputUnitStart(unit_), "start output");
    }
    ~AudioOutput() {
        if (!unit_) return;
        AudioOutputUnitStop(unit_);
        AudioUnitUninitialize(unit_);
        AudioComponentInstanceDispose(unit_);
    }
private:
    AudioUnit unit_ = nullptr;
};

}  // namespace

struct MacReceiverRuntime::Impl {
    Impl(MacReceiverConfig input, PairingHandler handler)
        : config(std::move(input)),
          pairing_handler(std::move(handler)),
          device_key(receiver_device_key()),
          socket(config.port),
          transport({
              .reorder_packets = std::max<std::size_t>(3, config.latency_ms / 20),
              .capacity_packets = 512,
              .hard_resync_gap_packets = 20,
              .maximum_fec_groups = 128,
          }),
          target_frames(std::max<std::size_t>(
              multipoint::protocol::kFramesPerPacket,
              static_cast<std::size_t>(multipoint::protocol::kSampleRate) *
                  config.latency_ms / 1'000)),
          output(audio, config.output_device_uid) {
        if (config.device_id.empty() || config.device_name.empty()) {
            throw std::invalid_argument("receiver identity is empty");
        }
        NSString* name = [NSString stringWithFormat:@"%s · SoundMux", config.device_name.c_str()];
        service = [[NSNetService alloc]
            initWithDomain:@"local." type:@"_soundmux._udp." name:name port:config.port];
        [service setTXTRecordData:txt_record(config, device_key.public_key)];
        [service publish];
        running.store(true, std::memory_order_release);
        network_thread = std::thread([this] { network_loop(); });
        pump_thread = std::thread([this] { pump_loop(); });
    }

    ~Impl() { stop(); }

    void stop() {
        if (!running.exchange(false, std::memory_order_acq_rel)) return;
        if (network_thread.joinable()) network_thread.join();
        if (pump_thread.joinable()) pump_thread.join();
        [service stop];
        service = nil;
        audio.playing.store(false, std::memory_order_release);
    }

    void send_plain(
        const multipoint::protocol::SessionMessage& message,
        const multipoint::network::UdpEndpoint& endpoint,
        std::uint16_t port) {
        socket.send_to(multipoint::protocol::serialize_session(message), endpoint, port);
    }

    void send_welcome(
        const multipoint::network::UdpEndpoint& endpoint,
        std::uint16_t port) {
        if (!secrets) return;
        send_plain({
            .type = multipoint::protocol::SessionMessageType::welcome,
            .fields = {
                {"receiver_id", config.device_id},
                {"receiver_name", config.device_name},
                {"platform", "macos"},
                {"protocol", "3"},
                {"session", "3"},
                {"public_key", multipoint::protocol::hex_encode(device_key.public_key)},
                {"server_nonce", multipoint::protocol::hex_encode(server_nonce)},
                {"proof", multipoint::protocol::hex_encode(secrets->welcome_proof)},
                {"heartbeat_ms", "1000"},
                {"capabilities", "audio,latency,pairing,encryption,volume"},
            },
        }, endpoint, port);
    }

    void handle_hello(
        const multipoint::protocol::SessionMessage& message,
        const multipoint::network::UdpEndpoint& endpoint) {
        const auto& fields = message.fields;
        if (!fields.contains("device_id") || !fields.contains("name") ||
            !fields.contains("public_key") || !fields.contains("client_nonce") ||
            !fields.contains("reply_port") || !fields.contains("session") ||
            fields.at("session") != "3") return;
        const int parsed_port = std::stoi(fields.at("reply_port"));
        if (parsed_port < 0 || parsed_port > 65'535) return;
        const auto reply_port = static_cast<std::uint16_t>(parsed_port);
        multipoint::protocol::CryptoKey sender_key{};
        multipoint::protocol::CryptoNonce new_client_nonce{};
        if (!multipoint::protocol::hex_decode(fields.at("public_key"), sender_key) ||
            !multipoint::protocol::hex_decode(fields.at("client_nonce"), new_client_nonce)) {
            return;
        }
        const auto sender_id = fields.at("device_id");
        if (secrets && sender_id == active_sender_id && sender_key == active_sender_key &&
            new_client_nonce == client_nonce) {
            active_reply_port = reply_port;
            send_welcome(endpoint, reply_port);
            return;
        }
        const auto trusted = trusted_key(sender_id);
        const bool pair_requested = fields.contains("pair_requested") &&
            fields.at("pair_requested") == "1";
        if (trusted && *trusted != sender_key) {
            send_plain({
                .type = multipoint::protocol::SessionMessageType::rejected,
                .fields = {{"reason", "Sender security key changed"}},
            }, endpoint, reply_port);
            return;
        }
        multipoint::protocol::CryptoNonce new_server_nonce{};
        if (!multipoint::protocol::secure_random(new_server_nonce)) return;
        if (!trusted || pair_requested) {
            const auto code = multipoint::protocol::pairing_code(
                sender_key, device_key.public_key);
            send_plain({
                .type = multipoint::protocol::SessionMessageType::pair_required,
                .fields = {
                    {"receiver_id", config.device_id},
                    {"receiver_name", config.device_name},
                    {"platform", "macos"},
                    {"public_key", multipoint::protocol::hex_encode(device_key.public_key)},
                    {"server_nonce", multipoint::protocol::hex_encode(new_server_nonce)},
                    {"code", code},
                },
            }, endpoint, reply_port);
            if (!pairing_handler || !pairing_handler(fields.at("name"), code)) {
                send_plain({
                    .type = multipoint::protocol::SessionMessageType::rejected,
                    .fields = {{"reason", "Pairing declined"}},
                }, endpoint, reply_port);
                return;
            }
            remember_key(sender_id, fields.at("name"), sender_key);
        }
        const auto new_secrets = multipoint::protocol::derive_session_secrets(
            device_key.secret, sender_key, sender_key, device_key.public_key,
            new_client_nonce, new_server_nonce);
        active_sender_id = sender_id;
        active_sender_key = sender_key;
        client_nonce = new_client_nonce;
        server_nonce = new_server_nonce;
        active_reply_port = reply_port;
        secrets = new_secrets;
        inbound = std::make_unique<multipoint::protocol::SessionCipher>(
            new_secrets.sender_to_receiver_key, new_secrets.sender_nonce_prefix);
        outbound = std::make_unique<multipoint::protocol::SessionCipher>(
            new_secrets.receiver_to_sender_key, new_secrets.receiver_nonce_prefix);
        {
            std::lock_guard lock(state_mutex);
            sender_name = fields.at("name");
            connected = true;
        }
        last_activity_ns.store(now_ns(), std::memory_order_relaxed);
        transport.reset();
        audio.ring.discard();
        audio.playing.store(false, std::memory_order_release);
        send_welcome(endpoint, reply_port);
    }

    void network_loop() {
        std::array<std::byte, 2'048> datagram{};
        while (running.load(std::memory_order_acquire)) {
            try {
                multipoint::network::UdpEndpoint endpoint;
                const auto size = socket.receive_from(datagram, endpoint);
                if (size == 0) continue;
                const auto raw = std::span<const std::byte>(datagram.data(), size);
                const auto message = multipoint::protocol::deserialize_session(raw);
                if (message.valid && message.message.type ==
                    multipoint::protocol::SessionMessageType::hello) {
                    handle_hello(message.message, endpoint);
                    continue;
                }
                if (!inbound) continue;
                auto opened = inbound->decrypt(raw);
                if (!opened.valid) continue;
                const auto control = multipoint::protocol::deserialize_session(
                    opened.plaintext);
                if (control.valid && control.message.type ==
                    multipoint::protocol::SessionMessageType::ping) {
                    last_activity_ns.store(now_ns(), std::memory_order_relaxed);
                    if (!outbound) continue;
                    const auto pong = multipoint::protocol::serialize_session({
                        .type = multipoint::protocol::SessionMessageType::pong,
                        .fields = {
                            {"receiver_id", config.device_id},
                            {"counter", control.message.fields.contains("counter")
                                ? control.message.fields.at("counter") : "0"},
                        },
                    });
                    socket.send_to(outbound->encrypt(pong), endpoint, active_reply_port);
                    continue;
                }
                const auto arrival = now_ns();
                const auto result = transport.ingest(opened.plaintext, arrival);
                if (result.accepted) {
                    last_activity_ns.store(arrival, std::memory_order_relaxed);
                }
                if (result.hard_resync) {
                    reset_audio.store(true, std::memory_order_release);
                }
            } catch (const std::exception&) {
                if (!running.load(std::memory_order_acquire)) break;
            }
        }
    }

    void pump_loop() {
        std::array<float, multipoint::protocol::kSamplesPerPacket> silence{};
        std::optional<std::chrono::steady_clock::time_point> missing_since;
        while (running.load(std::memory_order_acquire)) {
            if (reset_audio.exchange(false, std::memory_order_acq_rel)) {
                audio.ring.discard();
                audio.playing.store(false, std::memory_order_release);
                missing_since.reset();
            }
            if (audio.ring.available_to_write() >= multipoint::protocol::kFramesPerPacket &&
                audio.ring.available_to_read() < target_frames * 2) {
                auto result = transport.pop(false);
                if (result.status == multipoint::jitter::PopStatus::not_ready) {
                    const auto current = transport.snapshot();
                    if (current.started && current.depth > 0) {
                        const auto now = std::chrono::steady_clock::now();
                        if (!missing_since) missing_since = now;
                        if (now - *missing_since >= std::chrono::milliseconds(30)) {
                            result = transport.pop(true);
                        }
                    } else if (current.started && current.depth == 0 &&
                               audio.ring.available_to_read() == 0) {
                        transport.rebuffer();
                        audio.playing.store(false, std::memory_order_release);
                    }
                }
                if (result.packet) {
                    missing_since.reset();
                    audio.ring.write(
                        result.packet->interleaved_samples.data(),
                        multipoint::protocol::kFramesPerPacket);
                } else if (result.status == multipoint::jitter::PopStatus::missing) {
                    audio.ring.write(silence.data(), multipoint::protocol::kFramesPerPacket);
                    concealed.fetch_add(1, std::memory_order_relaxed);
                }
                if (!audio.playing.load(std::memory_order_acquire) &&
                    audio.ring.available_to_read() >= target_frames) {
                    audio.playing.store(true, std::memory_order_release);
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    MacReceiverSnapshot snapshot() const {
        const auto stats = transport.snapshot();
        std::lock_guard lock(state_mutex);
        const auto activity = last_activity_ns.load(std::memory_order_relaxed);
        const bool session_alive = connected && activity != 0 &&
            now_ns() - activity < 4'000'000'000ULL;
        NSDictionary* trusted = [NSUserDefaults.standardUserDefaults
            dictionaryForKey:@"macReceiverTrustedKeys"];
        return {
            .running = running.load(std::memory_order_acquire),
            .connected = session_alive,
            .playing = session_alive && audio.playing.load(std::memory_order_acquire),
            .sender_name = sender_name,
            .packets_received = stats.jitter.packets_received,
            .packets_lost = stats.jitter.packets_lost,
            .fec_recovered = stats.fec_recovered,
            .concealed_packets = concealed.load(std::memory_order_relaxed),
            .audio_underruns = audio.ring.underruns(),
            .buffered_frames = audio.ring.available_to_read(),
            .trusted_senders = trusted.count,
        };
    }

    MacReceiverConfig config;
    PairingHandler pairing_handler;
    multipoint::protocol::DeviceKeyPair device_key;
    multipoint::network::UdpReceiver socket;
    multipoint::transport::ReceiverEngine transport;
    const std::size_t target_frames;
    AudioState audio;
    AudioOutput output;
    NSNetService* service = nil;
    std::atomic<bool> running{false};
    std::thread network_thread;
    std::thread pump_thread;
    std::optional<multipoint::protocol::SessionSecrets> secrets;
    std::unique_ptr<multipoint::protocol::SessionCipher> inbound;
    std::unique_ptr<multipoint::protocol::SessionCipher> outbound;
    std::string active_sender_id;
    multipoint::protocol::CryptoKey active_sender_key{};
    multipoint::protocol::CryptoNonce client_nonce{};
    multipoint::protocol::CryptoNonce server_nonce{};
    std::uint16_t active_reply_port = 0;
    mutable std::mutex state_mutex;
    std::string sender_name;
    bool connected = false;
    std::atomic<std::uint64_t> concealed{0};
    std::atomic<std::uint64_t> last_activity_ns{0};
    std::atomic<bool> reset_audio{false};
};

MacReceiverRuntime::MacReceiverRuntime(
    MacReceiverConfig config,
    PairingHandler pairing_handler)
    : impl_(std::make_unique<Impl>(std::move(config), std::move(pairing_handler))) {}

MacReceiverRuntime::~MacReceiverRuntime() = default;

void MacReceiverRuntime::stop() {
    if (impl_) impl_->stop();
}

void MacReceiverRuntime::set_volume(float volume) {
    if (impl_) {
        impl_->audio.volume.store(std::clamp(volume, 0.0F, 1.0F),
                                  std::memory_order_relaxed);
    }
}

MacReceiverSnapshot MacReceiverRuntime::snapshot() const {
    return impl_ ? impl_->snapshot() : MacReceiverSnapshot{};
}
