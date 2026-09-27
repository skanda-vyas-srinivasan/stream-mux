#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/clock/monotonic_clock.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/session.h"
#include "multipoint/protocol/session_crypto.h"
#include "multipoint/transport/sender_engine.h"
#include "receiver_runtime.h"
#include "stereo_sample_rate_converter.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <IOKit/hidsystem/ev_keymap.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <memory>
#include <netdb.h>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

namespace {

constexpr std::size_t kCaptureRingFrames = 48'000;
constexpr std::size_t kMaximumIOFrames = 8'192;
volatile std::sig_atomic_t g_running = 1;

struct SenderSnapshot {
    std::uint64_t capture_callbacks = 0;
    std::uint64_t capture_frames = 0;
    std::uint64_t capture_drops = 0;
    std::uint64_t audio_packets = 0;
    std::uint64_t parity_packets = 0;
    std::uint64_t send_failures = 0;
    std::uint64_t control_commands = 0;
    std::uint64_t control_failures = 0;
    std::size_t ring_frames = 0;
    bool media_control_access = false;
    bool receiver_alive = false;
    std::uint64_t heartbeat_age_ms = 0;
};

void handle_signal(int) { g_running = 0; }

std::string fourcc(OSStatus status) {
    std::array<char, 5> text{};
    const auto value = static_cast<std::uint32_t>(status);
    text[0] = static_cast<char>((value >> 24) & 0xffU);
    text[1] = static_cast<char>((value >> 16) & 0xffU);
    text[2] = static_cast<char>((value >> 8) & 0xffU);
    text[3] = static_cast<char>(value & 0xffU);
    const bool printable = std::all_of(
        text.begin(), text.begin() + 4,
        [](char character) { return character >= 32 && character <= 126; });
    return printable ? std::string("'") + text.data() + "'"
                     : std::to_string(status);
}

void check_status(OSStatus status, const char* operation) {
    if (status != noErr) {
        throw std::runtime_error(
            std::string(operation) + " failed: " + fourcc(status));
    }
}

std::uint16_t control_port_for(std::uint16_t audio_port) {
    if (audio_port == 65'535) {
        throw std::invalid_argument(
            "the audio port must be 65534 or lower (the next port is used for controls)");
    }
    return static_cast<std::uint16_t>(audio_port + 1);
}

NSString* persistent_sender_value(NSString* key, BOOL token) {
    NSUserDefaults* defaults = [[NSUserDefaults alloc]
        initWithSuiteName:@"com.skandavyas.soundmux"];
    NSString* value = [defaults stringForKey:key];
    if (value.length) return value;
    value = token
        ? [NSString stringWithFormat:@"%@%@", NSUUID.UUID.UUIDString,
                                             NSUUID.UUID.UUIDString]
        : NSUUID.UUID.UUIDString;
    [defaults setObject:value forKey:key];
    return value;
}

multipoint::protocol::DeviceKeyPair persistent_device_key() {
    NSDictionary* query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.skandavyas.soundmux.device-key",
        (__bridge id)kSecAttrAccount: @"mac-sender",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = nullptr;
    const OSStatus status = SecItemCopyMatching(
        (__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess) {
        NSData* data = CFBridgingRelease(result);
        if (data.length != multipoint::protocol::kCryptoKeyBytes) {
            throw std::runtime_error("stored device key has the wrong size");
        }
        multipoint::protocol::CryptoKey secret{};
        std::memcpy(secret.data(), data.bytes, secret.size());
        return {
            .secret = secret,
            .public_key = multipoint::protocol::public_key_for(secret),
        };
    }
    if (status != errSecItemNotFound) {
        throw std::runtime_error("could not read device identity from Keychain");
    }

    auto pair = multipoint::protocol::generate_device_key_pair();
    NSData* secret = [NSData dataWithBytes:pair.secret.data()
                                    length:pair.secret.size()];
    NSDictionary* add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.skandavyas.soundmux.device-key",
        (__bridge id)kSecAttrAccount: @"mac-sender",
        (__bridge id)kSecAttrAccessible:
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        (__bridge id)kSecValueData: secret,
    };
    if (SecItemAdd((__bridge CFDictionaryRef)add, nullptr) != errSecSuccess) {
        throw std::runtime_error("could not save device identity in Keychain");
    }
    return pair;
}

std::optional<multipoint::protocol::CryptoKey> trusted_receiver_key(
    const std::string& receiver_id) {
    if (receiver_id.empty()) return std::nullopt;
    NSDictionary* keys = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"trustedReceiverPublicKeys"];
    NSString* identifier = [NSString stringWithUTF8String:receiver_id.c_str()];
    NSString* encoded = keys[identifier];
    if (![encoded isKindOfClass:NSString.class]) return std::nullopt;
    multipoint::protocol::CryptoKey key{};
    if (!multipoint::protocol::hex_decode(encoded.UTF8String, key)) {
        return std::nullopt;
    }
    return key;
}

void remember_receiver_key(
    const std::string& receiver_id,
    const multipoint::protocol::CryptoKey& key,
    const std::string& receiver_name) {
    if (receiver_id.empty()) return;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary* keys = [[defaults dictionaryForKey:@"trustedReceiverPublicKeys"]
        mutableCopy];
    if (!keys) keys = [NSMutableDictionary dictionary];
    NSMutableDictionary* names = [[defaults dictionaryForKey:@"trustedReceiverNames"]
        mutableCopy];
    if (!names) names = [NSMutableDictionary dictionary];
    NSString* identifier = [NSString stringWithUTF8String:receiver_id.c_str()];
    keys[identifier] = [NSString stringWithUTF8String:
        multipoint::protocol::hex_encode(key).c_str()];
    if (!receiver_name.empty()) {
        names[identifier] = [NSString stringWithUTF8String:receiver_name.c_str()];
    }
    [defaults setObject:keys forKey:@"trustedReceiverPublicKeys"];
    [defaults setObject:names forKey:@"trustedReceiverNames"];
}

void forget_receiver_key(NSString* receiver_id) {
    if (!receiver_id.length) return;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary* keys = [[defaults dictionaryForKey:@"trustedReceiverPublicKeys"]
        mutableCopy];
    NSMutableDictionary* names = [[defaults dictionaryForKey:@"trustedReceiverNames"]
        mutableCopy];
    [keys removeObjectForKey:receiver_id];
    [names removeObjectForKey:receiver_id];
    [defaults setObject:keys ? keys : @{} forKey:@"trustedReceiverPublicKeys"];
    [defaults setObject:names ? names : @{} forKey:@"trustedReceiverNames"];
}

BOOL is_trusted_receiver(NSString* receiver_id) {
    if (!receiver_id.length) return NO;
    NSDictionary* keys = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"trustedReceiverPublicKeys"];
    return [keys[receiver_id] isKindOfClass:NSString.class];
}

NSString* local_sender_name() {
    NSString* name = NSHost.currentHost.localizedName;
    return name.length ? name : @"Mac";
}

NSDictionary<NSString*, NSData*>* service_metadata(NSNetService* service) {
    NSData* data = service.TXTRecordData;
    return data.length ? [NSNetService dictionaryFromTXTRecordData:data] : @{};
}

NSString* service_text(NSNetService* service, NSString* key) {
    NSData* data = service_metadata(service)[key];
    if (!data.length) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSString* service_identifier(NSNetService* service) {
    NSString* identifier = service_text(service, @"id");
    return identifier.length ? identifier : service.name;
}

NSString* service_display_name(NSNetService* service) {
    NSString* name = service_text(service, @"name");
    return name.length ? name : (service.name.length ? service.name : @"SoundMux receiver");
}

NSString* service_connect_host(NSNetService* service) {
    for (NSNumber* wanted_family in @[@(AF_INET), @(AF_INET6)]) {
        for (NSData* address_data in service.addresses) {
            if (address_data.length < sizeof(sockaddr)) continue;
            const auto* address = static_cast<const sockaddr*>(address_data.bytes);
            if (address->sa_family != wanted_family.intValue) continue;
            char host[NI_MAXHOST]{};
            if (getnameinfo(
                    address,
                    static_cast<socklen_t>(address_data.length),
                    host, sizeof(host), nullptr, 0, NI_NUMERICHOST) == 0) {
                return [NSString stringWithUTF8String:host];
            }
        }
    }
    return service.hostName;
}

NSString* service_platform(NSNetService* service) {
    NSString* platform = service_text(service, @"platform");
    return platform.length ? platform.lowercaseString : @"unknown";
}

NSString* service_platform_display(NSNetService* service) {
    NSString* platform = service_platform(service);
    if ([platform isEqualToString:@"ios"]) return @"iOS";
    if ([platform isEqualToString:@"macos"]) return @"macOS";
    if ([platform isEqualToString:@"windows"]) return @"Windows";
    return platform.capitalizedString;
}

NSString* remembered_last_seen_text() {
    NSDate* date = [NSUserDefaults.standardUserDefaults objectForKey:@"lastReceiverSeen"];
    if (![date isKindOfClass:NSDate.class]) return @"previously";
    NSRelativeDateTimeFormatter* formatter = [[NSRelativeDateTimeFormatter alloc] init];
    formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    return [formatter localizedStringForDate:date relativeToDate:NSDate.date];
}

bool request_media_control_access(bool prompt) {
    if (!prompt) return AXIsProcessTrusted();
    NSDictionary* options = @{
        (__bridge NSString*)kAXTrustedCheckOptionPrompt: @YES,
    };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

void post_media_key(int key_type) {
    @autoreleasepool {
        for (const int state : {0xA, 0xB}) {
            const NSInteger data = (key_type << 16) | (state << 8);
            NSEvent* event = [NSEvent
                otherEventWithType:NSEventTypeSystemDefined
                           location:NSZeroPoint
                      modifierFlags:0
                          timestamp:0
                       windowNumber:0
                            context:nil
                            subtype:NX_SUBTYPE_AUX_CONTROL_BUTTONS
                              data1:data
                              data2:-1];
            if (event.CGEvent) CGEventPost(kCGHIDEventTap, event.CGEvent);
        }
    }
}

template <typename Value>
Value get_audio_property(
    AudioObjectID object,
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    AudioObjectPropertyAddress address{
        .mSelector = selector,
        .mScope = scope,
        .mElement = kAudioObjectPropertyElementMain,
    };
    Value value{};
    UInt32 size = sizeof(value);
    check_status(
        AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value),
        "read Core Audio property");
    return value;
}

NSArray<NSDictionary*>* active_audio_applications() {
    AudioObjectPropertyAddress address{
        .mSelector = kAudioHardwarePropertyProcessObjectList,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr ||
        size == 0) {
        return @[];
    }
    std::vector<AudioObjectID> process_objects(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject, &address, 0, nullptr, &size,
            process_objects.data()) != noErr) {
        return @[];
    }

    NSMutableArray<NSDictionary*>* applications = [NSMutableArray array];
    NSMutableSet<NSString*>* seen_bundles = [NSMutableSet set];
    for (const auto object : process_objects) {
        pid_t pid = 0;
        UInt32 pid_size = sizeof(pid);
        AudioObjectPropertyAddress pid_address{
            .mSelector = kAudioProcessPropertyPID,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        if (AudioObjectGetPropertyData(
                object, &pid_address, 0, nullptr, &pid_size, &pid) != noErr ||
            pid == NSProcessInfo.processInfo.processIdentifier) {
            continue;
        }
        UInt32 is_running_output = 0;
        UInt32 running_size = sizeof(is_running_output);
        AudioObjectPropertyAddress running_address{
            .mSelector = kAudioProcessPropertyIsRunningOutput,
            .mScope = kAudioObjectPropertyScopeGlobal,
            .mElement = kAudioObjectPropertyElementMain,
        };
        if (AudioObjectGetPropertyData(
                object, &running_address, 0, nullptr, &running_size,
                &is_running_output) != noErr || !is_running_output) {
            continue;
        }
        NSRunningApplication* application = [NSRunningApplication
            runningApplicationWithProcessIdentifier:pid];
        NSString* bundle = application.bundleIdentifier;
        NSString* name = application.localizedName;
        if (!bundle.length || !name.length || [seen_bundles containsObject:bundle]) {
            continue;
        }
        [seen_bundles addObject:bundle];
        [applications addObject:@{
            @"name": name,
            @"bundle": bundle,
            @"object": @(object),
        }];
    }
    [applications sortUsingComparator:^NSComparisonResult(
        NSDictionary* left, NSDictionary* right) {
        return [left[@"name"] localizedCaseInsensitiveCompare:right[@"name"]];
    }];
    return applications;
}

class CoreAudioTapSender {
public:
    CoreAudioTapSender(
        const std::string& host,
        std::uint16_t port,
        std::string device_id,
        std::string device_name,
        std::string expected_receiver_id,
        std::vector<AudioObjectID> included_processes = {},
        std::function<void(const std::string&)> state_handler = {},
        std::function<bool(const std::string&, const std::string&)>
            pairing_confirmation = {},
        std::function<bool()> cancellation_handler = {})
        : udp_(host, port),
          control_receiver_(std::make_unique<multipoint::network::UdpReceiver>(
              control_port_for(port))),
          sender_(multipoint::clock::monotonic_time_ns()),
          audio_ring_(kCaptureRingFrames, multipoint::protocol::kChannelCount),
          device_id_(std::move(device_id)),
          device_name_(std::move(device_name)),
          expected_receiver_id_(std::move(expected_receiver_id)),
          included_processes_(std::move(included_processes)),
          device_key_(persistent_device_key()),
          state_handler_(std::move(state_handler)),
          pairing_confirmation_(std::move(pairing_confirmation)),
          cancellation_handler_(std::move(cancellation_handler)),
          control_port_(control_port_for(port)) {
        perform_handshake();
        try {
            create_tap();
            converter_ = std::make_unique<multipoint::macos::StereoSampleRateConverter>(
                tap_format_.mSampleRate, audio_ring_);
            create_aggregate_device();
            create_io_proc();
        } catch (...) {
            // Construction may fail after Core Audio resources exist, before
            // the destructor can run.
            stop();
            throw;
        }
    }

    ~CoreAudioTapSender() { stop(); }

    CoreAudioTapSender(const CoreAudioTapSender&) = delete;
    CoreAudioTapSender& operator=(const CoreAudioTapSender&) = delete;

    void start() {
        if (running_.exchange(true, std::memory_order_acq_rel)) return;
        send_thread_ = std::thread([this] { send_loop(); });
        control_thread_ = std::thread([this] { control_loop(); });
        const auto status = AudioDeviceStart(aggregate_device_, io_proc_);
        if (status != noErr) {
            running_.store(false, std::memory_order_release);
            send_thread_.join();
            control_thread_.join();
            check_status(status, "start Core Audio tap device");
        }
    }

    void stop() {
        const bool was_running = running_.exchange(false, std::memory_order_acq_rel);
        if (was_running && aggregate_device_ != kAudioObjectUnknown && io_proc_) {
            AudioDeviceStop(aggregate_device_, io_proc_);
        }
        if (send_thread_.joinable()) send_thread_.join();
        if (control_thread_.joinable()) control_thread_.join();
        converter_.reset();
        if (aggregate_device_ != kAudioObjectUnknown && io_proc_) {
            AudioDeviceDestroyIOProcID(aggregate_device_, io_proc_);
            io_proc_ = nullptr;
        }
        if (aggregate_device_ != kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregate_device_);
            aggregate_device_ = kAudioObjectUnknown;
        }
        if (tap_ != kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap_);
            tap_ = kAudioObjectUnknown;
        }
    }

    [[nodiscard]] SenderSnapshot snapshot() const {
        const auto now = multipoint::clock::monotonic_time_ns();
        const auto last_pong = last_pong_ns_.load(std::memory_order_relaxed);
        const auto age_ms = now >= last_pong ? (now - last_pong) / 1'000'000 : 0;
        return {
            .capture_callbacks = capture_callbacks_.load(std::memory_order_relaxed),
            .capture_frames = capture_frames_.load(std::memory_order_relaxed),
            .capture_drops = capture_drops_.load(std::memory_order_relaxed),
            .audio_packets = audio_packets_.load(std::memory_order_relaxed),
            .parity_packets = parity_packets_.load(std::memory_order_relaxed),
            .send_failures = send_failures_.load(std::memory_order_relaxed),
            .control_commands = control_commands_.load(std::memory_order_relaxed),
            .control_failures = control_failures_.load(std::memory_order_relaxed),
            .ring_frames = audio_ring_.available_to_read(),
            .media_control_access = request_media_control_access(false),
            .receiver_alive = last_pong != 0 && age_ms < 4'000,
            .heartbeat_age_ms = age_ms,
        };
    }

    void print_stats() const {
        const auto stats = snapshot();
        std::cout << "capture_callbacks=" << stats.capture_callbacks
                  << " capture_frames=" << stats.capture_frames
                  << " capture_drops=" << stats.capture_drops
                  << " audio_packets=" << stats.audio_packets
                  << " parity_packets=" << stats.parity_packets
                  << " send_failures=" << stats.send_failures
                  << " control_commands=" << stats.control_commands
                  << " control_failures=" << stats.control_failures
                  << " ring_frames=" << stats.ring_frames
                  << " receiver_alive=" << stats.receiver_alive
                  << " heartbeat_age_ms=" << stats.heartbeat_age_ms << '\n';
    }

    [[nodiscard]] const AudioStreamBasicDescription& format() const {
        return tap_format_;
    }

private:
    void perform_handshake() {
        using multipoint::protocol::SessionMessage;
        using multipoint::protocol::SessionMessageType;
        multipoint::protocol::CryptoNonce client_nonce{};
        if (!multipoint::protocol::secure_random(client_nonce)) {
            throw std::runtime_error("could not generate a secure session nonce");
        }
        const bool request_pairing =
            !trusted_receiver_key(expected_receiver_id_).has_value();
        const auto hello = multipoint::protocol::serialize_session({
            .type = SessionMessageType::hello,
            .fields = {
                {"device_id", device_id_},
                {"name", device_name_},
                {"platform", "macos"},
                {"public_key", multipoint::protocol::hex_encode(device_key_.public_key)},
                {"client_nonce", multipoint::protocol::hex_encode(client_nonce)},
                {"reply_port", std::to_string(control_port_)},
                {"protocol", std::to_string(multipoint::protocol::kProtocolVersion)},
                {"session", "3"},
                {"pair_requested", request_pairing ? "1" : "0"},
            },
        });
        if (state_handler_) state_handler_("Contacting receiver…");
        std::array<std::byte, multipoint::protocol::kMaximumSessionDatagramBytes> reply{};
        auto deadline = std::chrono::steady_clock::now() +
            std::chrono::seconds(6);
        auto next_hello = std::chrono::steady_clock::time_point::min();
        bool receiver_responded = false;
        bool pairing_confirmed = false;
        std::optional<multipoint::protocol::CryptoKey> pairing_key;
        std::optional<multipoint::protocol::CryptoNonce> pairing_nonce;
        while (std::chrono::steady_clock::now() < deadline) {
            if (cancellation_handler_ && cancellation_handler_()) {
                throw std::runtime_error("connection cancelled");
            }
            const auto now = std::chrono::steady_clock::now();
            if (now >= next_hello) {
                udp_.send(hello);
                next_hello = now + std::chrono::seconds(1);
            }
            const auto size = control_receiver_->receive(reply);
            if (size == 0) continue;
            const auto decoded = multipoint::protocol::deserialize_session(
                std::span<const std::byte>(reply.data(), size));
            if (!decoded.valid) continue;
            if (decoded.message.type == SessionMessageType::pair_required) {
                if (!receiver_responded) {
                    receiver_responded = true;
                    deadline = std::chrono::steady_clock::now() +
                        std::chrono::seconds(90);
                }
                const auto& fields = decoded.message.fields;
                const auto receiver_id = fields.find("receiver_id");
                const auto receiver_public = fields.find("public_key");
                const auto server_nonce = fields.find("server_nonce");
                if (receiver_id == fields.end() || receiver_public == fields.end() ||
                    server_nonce == fields.end()) continue;
                if (!expected_receiver_id_.empty() &&
                    receiver_id->second != expected_receiver_id_) {
                    throw std::runtime_error("receiver identity did not match discovery");
                }
                multipoint::protocol::CryptoKey public_key{};
                multipoint::protocol::CryptoNonce nonce{};
                if (!multipoint::protocol::hex_decode(receiver_public->second, public_key) ||
                    !multipoint::protocol::hex_decode(server_nonce->second, nonce)) {
                    continue;
                }
                if (const auto trusted = trusted_receiver_key(receiver_id->second)) {
                    if (*trusted != public_key) {
                        throw std::runtime_error(
                            "receiver security key changed; forget it before pairing again");
                    }
                }
                const auto code = multipoint::protocol::pairing_code(
                    device_key_.public_key, public_key);
                const auto wire_code = fields.find("code");
                if (wire_code != fields.end() && wire_code->second != code) {
                    throw std::runtime_error("receiver pairing code was not authentic");
                }
                if (!pairing_confirmed) {
                    if (state_handler_) {
                        state_handler_("Compare code " + code + " on both devices");
                    }
                    if (!pairing_confirmation_ ||
                        !pairing_confirmation_(code, fields.contains("receiver_name")
                            ? fields.at("receiver_name") : "receiver")) {
                        throw std::runtime_error("pairing cancelled");
                    }
                    pairing_confirmed = true;
                }
                pairing_key = public_key;
                pairing_nonce = nonce;
                continue;
            }
            if (decoded.message.type == SessionMessageType::rejected) {
                const auto reason = decoded.message.fields.find("reason");
                throw std::runtime_error(
                    reason == decoded.message.fields.end()
                        ? "receiver rejected the connection"
                        : reason->second);
            }
            if (decoded.message.type == SessionMessageType::welcome) {
                const auto& fields = decoded.message.fields;
                const auto receiver_id = fields.find("receiver_id");
                const auto receiver_public = fields.find("public_key");
                const auto server_nonce = fields.find("server_nonce");
                const auto proof = fields.find("proof");
                if (receiver_id == fields.end() || receiver_public == fields.end() ||
                    server_nonce == fields.end() || proof == fields.end()) continue;
                if (!expected_receiver_id_.empty() &&
                    receiver_id->second != expected_receiver_id_) {
                    throw std::runtime_error("receiver identity did not match discovery");
                }
                multipoint::protocol::CryptoKey public_key{};
                multipoint::protocol::CryptoNonce nonce{};
                multipoint::protocol::CryptoProof received_proof{};
                if (!multipoint::protocol::hex_decode(receiver_public->second, public_key) ||
                    !multipoint::protocol::hex_decode(server_nonce->second, nonce) ||
                    !multipoint::protocol::hex_decode(proof->second, received_proof)) {
                    continue;
                }
                const auto trusted = trusted_receiver_key(receiver_id->second);
                if (trusted && *trusted != public_key) {
                    throw std::runtime_error("receiver security key changed");
                }
                if (!trusted && (!pairing_confirmed || !pairing_key || !pairing_nonce ||
                    *pairing_key != public_key || *pairing_nonce != nonce)) {
                    throw std::runtime_error("receiver was not securely paired");
                }
                const auto secrets = multipoint::protocol::derive_session_secrets(
                    device_key_.secret, public_key, device_key_.public_key, public_key,
                    client_nonce, nonce);
                if (!multipoint::protocol::proof_matches(
                        secrets.welcome_proof, received_proof)) {
                    throw std::runtime_error("receiver authentication failed");
                }
                outbound_cipher_ = std::make_unique<multipoint::protocol::SessionCipher>(
                    secrets.sender_to_receiver_key, secrets.sender_nonce_prefix);
                inbound_cipher_ = std::make_unique<multipoint::protocol::SessionCipher>(
                    secrets.receiver_to_sender_key, secrets.receiver_nonce_prefix);
                expected_receiver_id_ = receiver_id->second;
                const auto name = fields.find("receiver_name");
                if (name != fields.end() && !name->second.empty()) {
                    receiver_name_ = name->second;
                }
                remember_receiver_key(
                    receiver_id->second, public_key,
                    receiver_name_.empty() ? "SoundMux receiver" : receiver_name_);
                last_pong_ns_.store(
                    multipoint::clock::monotonic_time_ns(),
                    std::memory_order_relaxed);
                if (state_handler_) state_handler_("Receiver approved");
                return;
            }
        }
        throw std::runtime_error(receiver_responded
            ? "pairing timed out"
            : "device did not respond; open SoundMux on the receiver");
    }

    void send_heartbeat() {
        if (!outbound_cipher_) throw std::runtime_error("secure session unavailable");
        const auto counter = heartbeat_counter_.fetch_add(1, std::memory_order_relaxed);
        const auto plaintext = multipoint::protocol::serialize_session({
            .type = multipoint::protocol::SessionMessageType::ping,
            .fields = {
                {"device_id", device_id_},
                {"counter", std::to_string(counter)},
                {"reply_port", std::to_string(control_port_)},
            },
        });
        udp_.send(outbound_cipher_->encrypt(plaintext));
    }

    void create_tap() {
        NSMutableArray<NSNumber*>* process_objects = [NSMutableArray array];
        for (const auto object : included_processes_) {
            [process_objects addObject:@(object)];
        }
        CATapDescription* description = included_processes_.empty()
            ? [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]]
            : [[CATapDescription alloc] initStereoMixdownOfProcesses:process_objects];
        description.name = @"SoundMux system audio";
        [description setPrivate:YES];
        description.muteBehavior = CATapUnmuted;
        check_status(
            AudioHardwareCreateProcessTap(description, &tap_),
            "create Core Audio process tap");

        tap_format_ = get_audio_property<AudioStreamBasicDescription>(
            tap_, kAudioTapPropertyFormat);
        const bool is_float =
            (tap_format_.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        const bool packed =
            (tap_format_.mFormatFlags & kAudioFormatFlagIsPacked) != 0;
        if (tap_format_.mFormatID != kAudioFormatLinearPCM ||
            !is_float || !packed || tap_format_.mBitsPerChannel != 32 ||
            tap_format_.mChannelsPerFrame != multipoint::protocol::kChannelCount) {
            throw std::runtime_error(
                "Core Audio tap did not provide packed float32 stereo");
        }
    }

    void create_aggregate_device() {
        auto tap_uid = get_audio_property<CFStringRef>(tap_, kAudioTapPropertyUID);
        NSString* device_uid = NSUUID.UUID.UUIDString;
        NSDictionary* tap_entry = @{
            @(kAudioSubTapUIDKey): (__bridge NSString*)tap_uid,
            @(kAudioSubTapDriftCompensationKey): @YES,
        };
        NSDictionary* aggregate_description = @{
            @(kAudioAggregateDeviceNameKey): @"SoundMux audio capture",
            @(kAudioAggregateDeviceUIDKey): device_uid,
            @(kAudioAggregateDeviceTapListKey): @[tap_entry],
            @(kAudioAggregateDeviceTapAutoStartKey): @YES,
            @(kAudioAggregateDeviceIsPrivateKey): @YES,
        };
        const auto status = AudioHardwareCreateAggregateDevice(
            (__bridge CFDictionaryRef)aggregate_description,
            &aggregate_device_);
        CFRelease(tap_uid);
        check_status(status, "create Core Audio aggregate tap device");
    }

    void create_io_proc() {
        const bool non_interleaved =
            (tap_format_.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        CoreAudioTapSender* sender = this;
        check_status(
            AudioDeviceCreateIOProcIDWithBlock(
                &io_proc_, aggregate_device_, nullptr,
                ^(const AudioTimeStamp*,
                  const AudioBufferList* input,
                  const AudioTimeStamp*,
                  AudioBufferList*,
                  const AudioTimeStamp*) {
                    sender->capture(input, non_interleaved);
                }),
            "create Core Audio tap IOProc");
    }

    void capture(const AudioBufferList* input, bool non_interleaved) {
        if (!input || input->mNumberBuffers == 0) return;
        constexpr auto bytes_per_sample = sizeof(float);
        const std::size_t frames = non_interleaved
            ? input->mBuffers[0].mDataByteSize / bytes_per_sample
            : input->mBuffers[0].mDataByteSize /
                (bytes_per_sample * multipoint::protocol::kChannelCount);
        if (frames == 0 || frames > kMaximumIOFrames) {
            capture_drops_.fetch_add(frames, std::memory_order_relaxed);
            return;
        }

        const float* samples = nullptr;
        if (!non_interleaved && input->mNumberBuffers == 1 &&
            input->mBuffers[0].mData) {
            samples = static_cast<const float*>(input->mBuffers[0].mData);
        } else if (non_interleaved &&
                   input->mNumberBuffers >= multipoint::protocol::kChannelCount &&
                   input->mBuffers[0].mData && input->mBuffers[1].mData) {
            const auto* left = static_cast<const float*>(input->mBuffers[0].mData);
            const auto* right = static_cast<const float*>(input->mBuffers[1].mData);
            for (std::size_t frame = 0; frame < frames; ++frame) {
                capture_scratch_[frame * 2] = left[frame];
                capture_scratch_[frame * 2 + 1] = right[frame];
            }
            samples = capture_scratch_.data();
        } else {
            capture_drops_.fetch_add(frames, std::memory_order_relaxed);
            return;
        }

        const auto written = audio_ring_.write(samples, frames);
        capture_callbacks_.fetch_add(1, std::memory_order_relaxed);
        capture_frames_.fetch_add(written, std::memory_order_relaxed);
        capture_drops_.fetch_add(frames - written, std::memory_order_relaxed);
    }

    void send_loop() {
        std::array<float, multipoint::protocol::kSamplesPerPacket> packet_samples{};
        auto next_heartbeat = std::chrono::steady_clock::now();
        while (running_.load(std::memory_order_acquire)) {
            const auto now = std::chrono::steady_clock::now();
            if (now >= next_heartbeat) {
                try {
                    send_heartbeat();
                } catch (const std::exception& error) {
                    send_failures_.fetch_add(1, std::memory_order_relaxed);
                    std::cerr << "heartbeat send error: " << error.what() << '\n';
                }
                next_heartbeat = now + std::chrono::seconds(1);
            }
            try {
                const auto frames = converter_->read(packet_samples);
                if (frames == 0) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                const auto datagrams = sender_.push_audio(
                    std::span<const float>(packet_samples.data(),
                        frames * multipoint::protocol::kChannelCount),
                    multipoint::clock::monotonic_time_ns());
                const auto stats = sender_.stats();
                audio_packets_.store(stats.audio_packets, std::memory_order_relaxed);
                parity_packets_.store(stats.parity_packets, std::memory_order_relaxed);
                if (!outbound_cipher_) {
                    throw std::runtime_error("secure session unavailable");
                }
                for (const auto& datagram : datagrams) {
                    udp_.send(outbound_cipher_->encrypt(datagram));
                }
            } catch (const std::exception& error) {
                const auto failures =
                    send_failures_.fetch_add(1, std::memory_order_relaxed) + 1;
                if (failures == 1 || failures % 100 == 0) {
                    std::cerr << "sender pipeline error: " << error.what() << '\n';
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    }

    void control_loop() {
        std::array<std::byte,
            multipoint::protocol::kMaximumSessionDatagramBytes +
                multipoint::protocol::kEncryptedOverheadBytes> datagram{};
        while (running_.load(std::memory_order_acquire)) {
            try {
                const auto size = control_receiver_->receive(datagram);
                if (size == 0) continue;
                if (!inbound_cipher_) continue;
                auto opened = inbound_cipher_->decrypt(
                    std::span<const std::byte>(datagram.data(), size));
                if (!opened.valid) continue;
                const auto session = multipoint::protocol::deserialize_session(
                    opened.plaintext);
                if (session.valid &&
                    session.message.type ==
                        multipoint::protocol::SessionMessageType::pong) {
                    last_pong_ns_.store(
                        multipoint::clock::monotonic_time_ns(),
                        std::memory_order_relaxed);
                    continue;
                }
                const std::string_view command(
                    reinterpret_cast<const char*>(opened.plaintext.data()),
                    opened.plaintext.size());
                int key_type = -1;
                if (command == "SOUNDMUX/1 PLAY_PAUSE") {
                    key_type = NX_KEYTYPE_PLAY;
                } else if (command == "SOUNDMUX/1 NEXT") {
                    key_type = NX_KEYTYPE_NEXT;
                } else if (command == "SOUNDMUX/1 PREVIOUS") {
                    key_type = NX_KEYTYPE_PREVIOUS;
                } else {
                    continue;
                }

                control_commands_.fetch_add(1, std::memory_order_relaxed);
                if (!request_media_control_access(false)) {
                    control_failures_.fetch_add(1, std::memory_order_relaxed);
                    continue;
                }
                post_media_key(key_type);
            } catch (const std::exception& error) {
                const auto failures =
                    control_failures_.fetch_add(1, std::memory_order_relaxed) + 1;
                if (failures == 1 || failures % 100 == 0) {
                    std::cerr << "control error: " << error.what() << '\n';
                }
            }
        }
    }

    multipoint::network::UdpSender udp_;
    std::unique_ptr<multipoint::network::UdpReceiver> control_receiver_;
    multipoint::transport::SenderEngine sender_;
    multipoint::audio::SpscAudioRing audio_ring_;
    std::unique_ptr<multipoint::macos::StereoSampleRateConverter> converter_;
    std::array<float, kMaximumIOFrames * multipoint::protocol::kChannelCount>
        capture_scratch_{};
    std::string device_id_;
    std::string device_name_;
    std::string expected_receiver_id_;
    std::vector<AudioObjectID> included_processes_;
    std::string receiver_name_;
    multipoint::protocol::DeviceKeyPair device_key_;
    std::unique_ptr<multipoint::protocol::SessionCipher> outbound_cipher_;
    std::unique_ptr<multipoint::protocol::SessionCipher> inbound_cipher_;
    std::function<void(const std::string&)> state_handler_;
    std::function<bool(const std::string&, const std::string&)>
        pairing_confirmation_;
    std::function<bool()> cancellation_handler_;
    std::uint16_t control_port_ = 0;
    AudioObjectID tap_ = kAudioObjectUnknown;
    AudioObjectID aggregate_device_ = kAudioObjectUnknown;
    AudioDeviceIOProcID io_proc_ = nullptr;
    AudioStreamBasicDescription tap_format_{};
    std::atomic<bool> running_{false};
    std::thread send_thread_;
    std::thread control_thread_;
    std::atomic<std::uint64_t> capture_callbacks_{0};
    std::atomic<std::uint64_t> capture_frames_{0};
    std::atomic<std::uint64_t> capture_drops_{0};
    std::atomic<std::uint64_t> audio_packets_{0};
    std::atomic<std::uint64_t> parity_packets_{0};
    std::atomic<std::uint64_t> send_failures_{0};
    std::atomic<std::uint64_t> control_commands_{0};
    std::atomic<std::uint64_t> control_failures_{0};
    std::atomic<std::uint64_t> last_pong_ns_{0};
    std::atomic<std::uint64_t> heartbeat_counter_{0};
};

}  // namespace

@interface SoundMuxSenderAppDelegate : NSObject
    <NSApplicationDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation SoundMuxSenderAppDelegate {
    NSWindow* _window;
    NSSegmentedControl* _modeControl;
    NSStackView* _sendView;
    NSStackView* _receiveView;
    NSPopUpButton* _receiverPopup;
    NSTextField* _discoveryLabel;
    NSImageView* _selectedDeviceIcon;
    NSTextField* _selectedDeviceNameLabel;
    NSTextField* _selectedDeviceSecurityLabel;
    NSButton* _forgetReceiverButton;
    NSStackView* _manualStack;
    NSTextField* _hostField;
    NSTextField* _portField;
    NSTextField* _statusLabel;
    NSTextField* _metricsLabel;
    NSTextField* _mediaControlLabel;
    NSButton* _mediaControlButton;
    NSButton* _startButton;
    NSButton* _autoReconnectButton;
    NSPopUpButton* _sourcePopup;
    NSTextField* _healthLabel;
    NSTextField* _receiveNameField;
    NSTextField* _receivePortField;
    NSPopUpButton* _receiveLatencyPopup;
    NSSlider* _receiveVolumeSlider;
    NSTextField* _receiveVolumeLabel;
    NSButton* _receiveAutoStartButton;
    NSButton* _receiveButton;
    NSTextField* _receiveStatusLabel;
    NSTextField* _receiveMetricsLabel;
    NSTextField* _trustedSendersLabel;
    NSButton* _forgetSendersButton;
    NSTimer* _metricsTimer;
    NSNetServiceBrowser* _serviceBrowser;
    NSMutableArray<NSNetService*>* _services;
    NSString* _activeReceiverName;
    std::unique_ptr<CoreAudioTapSender> _sender;
    std::unique_ptr<MacReceiverRuntime> _receiver;
    BOOL _starting;
    BOOL _preferManual;
    BOOL _manualDisconnect;
    BOOL _reconnectScheduled;
    std::shared_ptr<std::atomic<bool>> _startCancellation;
    std::uint64_t _lastCaptureDrops;
    std::uint64_t _lastSendFailures;
}

- (void)refreshAudioSources:(id)sender {
    (void)sender;
    NSString* preferred_bundle = nil;
    if ([_sourcePopup.selectedItem.representedObject isKindOfClass:NSDictionary.class]) {
        preferred_bundle = _sourcePopup.selectedItem.representedObject[@"bundle"];
    }
    if (!preferred_bundle.length) {
        preferred_bundle = [NSUserDefaults.standardUserDefaults
            stringForKey:@"selectedAudioSourceBundle"];
    }
    [_sourcePopup removeAllItems];
    [_sourcePopup addItemWithTitle:@"All System Audio"];
    _sourcePopup.lastItem.image = [NSImage imageWithSystemSymbolName:@"speaker.wave.2"
                                            accessibilityDescription:@"All audio"];
    NSInteger preferred_index = 0;
    for (NSDictionary* application in active_audio_applications()) {
        [_sourcePopup addItemWithTitle:application[@"name"]];
        NSMenuItem* item = _sourcePopup.lastItem;
        item.representedObject = application;
        NSArray<NSRunningApplication*>* running = [NSRunningApplication
            runningApplicationsWithBundleIdentifier:application[@"bundle"]];
        NSString* application_path = running.firstObject.bundleURL.path;
        if (application_path.length) {
            item.image = [NSWorkspace.sharedWorkspace iconForFile:application_path];
        }
        if ([application[@"bundle"] isEqualToString:preferred_bundle]) {
            preferred_index = _sourcePopup.numberOfItems - 1;
        }
    }
    [_sourcePopup selectItemAtIndex:preferred_index];
}

- (void)audioSourceChanged:(id)sender {
    (void)sender;
    NSDictionary* source = [_sourcePopup.selectedItem.representedObject
        isKindOfClass:NSDictionary.class]
        ? _sourcePopup.selectedItem.representedObject : nil;
    if (source[@"bundle"]) {
        [NSUserDefaults.standardUserDefaults setObject:source[@"bundle"]
                                                forKey:@"selectedAudioSourceBundle"];
    } else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:
            @"selectedAudioSourceBundle"];
    }
    if (_sender && !_starting) {
        [self toggleSending:nil];
        _statusLabel.stringValue = @"Switching audio source…";
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleSending:nil]; });
    }
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 730)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _window.title = @"SoundMux";
    _window.titleVisibility = NSWindowTitleHidden;
    _window.titlebarAppearsTransparent = YES;
    _window.movableByWindowBackground = YES;
    _window.backgroundColor = NSColor.windowBackgroundColor;
    [_window center];

    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* saved_host = [defaults stringForKey:@"receiverHost"];
    NSString* saved_port = [defaults stringForKey:@"receiverPort"];
    if (!saved_host.length) saved_host = @"";
    if (!saved_port.length) saved_port = @"48101";

    NSImageView* app_icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    app_icon.image = [NSImage imageWithSystemSymbolName:@"waveform.path"
                              accessibilityDescription:@"SoundMux"];
    app_icon.contentTintColor = NSColor.controlAccentColor;
    app_icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [app_icon.widthAnchor constraintEqualToConstant:44].active = YES;
    [app_icon.heightAnchor constraintEqualToConstant:44].active = YES;

    NSTextField* title = [NSTextField labelWithString:@"SoundMux"];
    title.font = [NSFont systemFontOfSize:23 weight:NSFontWeightSemibold];
    NSTextField* subtitle = [NSTextField labelWithString:
        @"Your audio, on the device you choose"];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.font = [NSFont systemFontOfSize:13];

    NSStackView* header = [NSStackView stackViewWithViews:@[app_icon, title, subtitle]];
    header.orientation = NSUserInterfaceLayoutOrientationVertical;
    header.alignment = NSLayoutAttributeCenterX;
    header.spacing = 6;

    _modeControl = [NSSegmentedControl
        segmentedControlWithLabels:@[@"Send Audio", @"Receive Audio"]
                   trackingMode:NSSegmentSwitchTrackingSelectOne
                         target:self
                         action:@selector(modeChanged:)];
    _modeControl.controlSize = NSControlSizeLarge;
    _modeControl.segmentStyle = NSSegmentStyleRounded;
    _modeControl.selectedSegment = [defaults integerForKey:@"macAppMode"] == 1 ? 1 : 0;
    [_modeControl setImage:[NSImage imageWithSystemSymbolName:@"arrow.up.forward"
                                      accessibilityDescription:@"Send"] forSegment:0];
    [_modeControl setImage:[NSImage imageWithSystemSymbolName:@"arrow.down.to.line"
                                      accessibilityDescription:@"Receive"] forSegment:1];

    NSTextField* receiver_label = [NSTextField labelWithString:@"Send to"];
    receiver_label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    receiver_label.textColor = NSColor.secondaryLabelColor;

    _receiverPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _receiverPopup.controlSize = NSControlSizeLarge;
    _receiverPopup.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    _receiverPopup.target = self;
    _receiverPopup.action = @selector(receiverSelectionChanged:);

    _discoveryLabel = [NSTextField labelWithString:@"Searching for SoundMux receivers…"];
    _discoveryLabel.textColor = NSColor.secondaryLabelColor;
    _discoveryLabel.font = [NSFont systemFontOfSize:12];
    _discoveryLabel.maximumNumberOfLines = 2;
    _discoveryLabel.lineBreakMode = NSLineBreakByWordWrapping;

    _selectedDeviceIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _selectedDeviceIcon.image = [NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right"
                                          accessibilityDescription:@"Device"];
    _selectedDeviceIcon.contentTintColor = NSColor.controlAccentColor;
    [_selectedDeviceIcon.widthAnchor constraintEqualToConstant:30].active = YES;
    [_selectedDeviceIcon.heightAnchor constraintEqualToConstant:30].active = YES;
    _selectedDeviceNameLabel = [NSTextField labelWithString:@"Looking for devices…"];
    _selectedDeviceNameLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    _selectedDeviceSecurityLabel = [NSTextField labelWithString:
        @"Nearby devices appear automatically"];
    _selectedDeviceSecurityLabel.font = [NSFont systemFontOfSize:11];
    _selectedDeviceSecurityLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView* selected_device_text = [NSStackView stackViewWithViews:@[
        _selectedDeviceNameLabel, _selectedDeviceSecurityLabel,
    ]];
    selected_device_text.orientation = NSUserInterfaceLayoutOrientationVertical;
    selected_device_text.alignment = NSLayoutAttributeLeading;
    selected_device_text.spacing = 2;
    [selected_device_text setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    _forgetReceiverButton = [NSButton buttonWithTitle:@"Forget"
                                                target:self
                                                action:@selector(forgetSelectedReceiver:)];
    _forgetReceiverButton.bezelStyle = NSBezelStyleInline;
    _forgetReceiverButton.hidden = YES;
    NSStackView* selected_device_row = [NSStackView stackViewWithViews:@[
        _selectedDeviceIcon, selected_device_text, _forgetReceiverButton,
    ]];
    selected_device_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    selected_device_row.alignment = NSLayoutAttributeCenterY;
    selected_device_row.spacing = 10;
    NSBox* selected_device_box = [[NSBox alloc] initWithFrame:NSZeroRect];
    selected_device_box.boxType = NSBoxCustom;
    selected_device_box.cornerRadius = 10;
    selected_device_box.borderWidth = 1;
    selected_device_box.borderColor = NSColor.separatorColor;
    selected_device_box.fillColor = NSColor.controlBackgroundColor;
    selected_device_box.contentViewMargins = NSMakeSize(12, 9);
    selected_device_row.translatesAutoresizingMaskIntoConstraints = NO;
    [selected_device_box.contentView addSubview:selected_device_row];
    [NSLayoutConstraint activateConstraints:@[
        [selected_device_row.leadingAnchor
            constraintEqualToAnchor:selected_device_box.contentView.leadingAnchor constant:12],
        [selected_device_row.trailingAnchor
            constraintEqualToAnchor:selected_device_box.contentView.trailingAnchor constant:-12],
        [selected_device_row.centerYAnchor
            constraintEqualToAnchor:selected_device_box.contentView.centerYAnchor],
        [selected_device_box.heightAnchor constraintEqualToConstant:64],
    ]];

    _autoReconnectButton = [NSButton checkboxWithTitle:
        @"Automatically route audio here when available"
                                                 target:self
                                                 action:@selector(autoReconnectChanged:)];
    _autoReconnectButton.font = [NSFont systemFontOfSize:12];
    NSNumber* saved_auto_reconnect = [defaults objectForKey:@"autoReconnect"];
    _autoReconnectButton.state = !saved_auto_reconnect || saved_auto_reconnect.boolValue
        ? NSControlStateValueOn
        : NSControlStateValueOff;

    _hostField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _hostField.stringValue = saved_host;
    _hostField.placeholderString = @"Receiver IP address";
    _portField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _portField.stringValue = saved_port;
    _portField.placeholderString = @"48101";

    NSTextField* host_label = [NSTextField labelWithString:@"Address"];
    host_label.font = [NSFont systemFontOfSize:11];
    host_label.textColor = NSColor.secondaryLabelColor;
    NSTextField* port_label = [NSTextField labelWithString:@"Port"];
    port_label.font = [NSFont systemFontOfSize:11];
    port_label.textColor = NSColor.secondaryLabelColor;
    NSStackView* host_column = [NSStackView stackViewWithViews:@[host_label, _hostField]];
    host_column.orientation = NSUserInterfaceLayoutOrientationVertical;
    host_column.alignment = NSLayoutAttributeLeading;
    host_column.spacing = 4;
    NSStackView* port_column = [NSStackView stackViewWithViews:@[port_label, _portField]];
    port_column.orientation = NSUserInterfaceLayoutOrientationVertical;
    port_column.alignment = NSLayoutAttributeLeading;
    port_column.spacing = 4;
    _manualStack = [NSStackView stackViewWithViews:@[host_column, port_column]];
    _manualStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _manualStack.alignment = NSLayoutAttributeBottom;
    _manualStack.spacing = 10;

    NSStackView* receiver_stack = [NSStackView stackViewWithViews:@[
        receiver_label, _receiverPopup, _discoveryLabel, selected_device_box, _manualStack,
        _autoReconnectButton,
    ]];
    receiver_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    receiver_stack.alignment = NSLayoutAttributeLeading;
    receiver_stack.spacing = 10;

    NSTextField* source_label = [NSTextField labelWithString:@"Audio source"];
    source_label.font = [NSFont systemFontOfSize:11];
    source_label.textColor = NSColor.secondaryLabelColor;
    _sourcePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _sourcePopup.controlSize = NSControlSizeRegular;
    _sourcePopup.font = [NSFont systemFontOfSize:13];
    _sourcePopup.target = self;
    _sourcePopup.action = @selector(audioSourceChanged:);
    NSButton* refresh_sources = [NSButton buttonWithImage:
        [NSImage imageWithSystemSymbolName:@"arrow.clockwise"
                  accessibilityDescription:@"Refresh audio applications"]
                                                     target:self
                                                     action:@selector(refreshAudioSources:)];
    refresh_sources.bezelStyle = NSBezelStyleInline;
    NSStackView* source_row = [NSStackView stackViewWithViews:@[
        _sourcePopup, refresh_sources,
    ]];
    source_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    source_row.alignment = NSLayoutAttributeCenterY;
    source_row.spacing = 8;
    NSStackView* source_stack = [NSStackView stackViewWithViews:@[
        source_label, source_row,
    ]];
    source_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    source_stack.alignment = NSLayoutAttributeLeading;
    source_stack.spacing = 4;
    [self refreshAudioSources:nil];

    _startButton = [NSButton buttonWithTitle:@"Connect"
                                      target:self
                                      action:@selector(toggleSending:)];
    _startButton.bezelStyle = NSBezelStyleRounded;
    _startButton.controlSize = NSControlSizeLarge;
    _startButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _startButton.keyEquivalent = @"\r";
    [_startButton.heightAnchor constraintEqualToConstant:38].active = YES;

    _statusLabel = [NSTextField labelWithString:@"Ready to connect"];
    _statusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _healthLabel = [NSTextField labelWithString:@"Health  —"];
    _healthLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _healthLabel.textColor = NSColor.secondaryLabelColor;
    _metricsLabel = [NSTextField labelWithString:@"No active stream"];
    _metricsLabel.textColor = NSColor.secondaryLabelColor;
    _metricsLabel.font = [NSFont monospacedDigitSystemFontOfSize:11
                                                        weight:NSFontWeightRegular];
    _metricsLabel.maximumNumberOfLines = 0;

    NSBox* divider = [[NSBox alloc] initWithFrame:NSZeroRect];
    divider.boxType = NSBoxSeparator;

    NSStackView* status_stack = [NSStackView stackViewWithViews:@[_statusLabel, _metricsLabel]];
    status_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    status_stack.alignment = NSLayoutAttributeLeading;
    status_stack.spacing = 5;

    _mediaControlLabel = [NSTextField labelWithString:
        request_media_control_access(false)
            ? @"Phone play/pause and skip controls are enabled."
            : @"Phone playback controls are optional."];
    _mediaControlLabel.textColor = NSColor.tertiaryLabelColor;
    _mediaControlLabel.maximumNumberOfLines = 0;
    _mediaControlLabel.font = [NSFont systemFontOfSize:11];
    _mediaControlButton = [NSButton buttonWithTitle:
        request_media_control_access(false) ? @"Enabled" : @"Enable Controls…"
                                                target:self
                                                action:@selector(enableMediaControls:)];
    _mediaControlButton.bezelStyle = NSBezelStyleInline;
    _mediaControlButton.enabled = !request_media_control_access(false);
    NSStackView* permission_row = [NSStackView stackViewWithViews:@[
        _mediaControlLabel, _mediaControlButton,
    ]];
    permission_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    permission_row.alignment = NSLayoutAttributeCenterY;
    permission_row.spacing = 8;
    [_mediaControlLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];

    _sendView = [NSStackView stackViewWithViews:@[
        receiver_stack, source_stack, _startButton, divider, _healthLabel,
        status_stack, permission_row,
    ]];
    _sendView.orientation = NSUserInterfaceLayoutOrientationVertical;
    _sendView.alignment = NSLayoutAttributeLeading;
    _sendView.spacing = 16;
    [_sendView setCustomSpacing:22 afterView:receiver_stack];

    NSString* saved_receive_name = [defaults stringForKey:@"macReceiverName"];
    if (!saved_receive_name.length) saved_receive_name = local_sender_name();
    NSInteger saved_receive_port = [defaults integerForKey:@"macReceiverPort"];
    if (saved_receive_port < 1 || saved_receive_port > 65'534) saved_receive_port = 48100;
    NSInteger saved_latency = [defaults integerForKey:@"macReceiverLatency"];
    if (saved_latency == 0) saved_latency = 60;
    NSNumber* saved_volume = [defaults objectForKey:@"macReceiverVolume"];
    const double volume = saved_volume ? saved_volume.doubleValue : 1.0;

    NSTextField* availability_title = [NSTextField labelWithString:@"Make this Mac a receiver"];
    availability_title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    NSTextField* availability_detail = [NSTextField labelWithString:
        @"Other SoundMux devices nearby will find it automatically."];
    availability_detail.textColor = NSColor.secondaryLabelColor;
    availability_detail.font = [NSFont systemFontOfSize:12];

    _receiveNameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _receiveNameField.stringValue = saved_receive_name;
    _receiveNameField.placeholderString = @"This Mac's name";
    NSTextField* name_label = [NSTextField labelWithString:@"Visible name"];
    name_label.font = [NSFont systemFontOfSize:11];
    name_label.textColor = NSColor.secondaryLabelColor;
    NSStackView* name_column = [NSStackView stackViewWithViews:@[name_label, _receiveNameField]];
    name_column.orientation = NSUserInterfaceLayoutOrientationVertical;
    name_column.alignment = NSLayoutAttributeLeading;
    name_column.spacing = 4;

    _receivePortField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _receivePortField.stringValue = [NSString stringWithFormat:@"%ld", (long)saved_receive_port];
    NSTextField* receive_port_label = [NSTextField labelWithString:@"Port"];
    receive_port_label.font = [NSFont systemFontOfSize:11];
    receive_port_label.textColor = NSColor.secondaryLabelColor;
    NSStackView* receive_port_column = [NSStackView stackViewWithViews:@[
        receive_port_label, _receivePortField,
    ]];
    receive_port_column.orientation = NSUserInterfaceLayoutOrientationVertical;
    receive_port_column.alignment = NSLayoutAttributeLeading;
    receive_port_column.spacing = 4;
    NSStackView* identity_row = [NSStackView stackViewWithViews:@[
        name_column, receive_port_column,
    ]];
    identity_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    identity_row.alignment = NSLayoutAttributeBottom;
    identity_row.spacing = 10;

    _receiveLatencyPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_receiveLatencyPopup addItemsWithTitles:@[
        @"40 ms · Responsive", @"60 ms · Balanced",
        @"100 ms · Stable", @"160 ms · Very stable",
    ]];
    NSArray<NSNumber*>* latency_values = @[@40, @60, @100, @160];
    NSInteger latency_index = [latency_values indexOfObject:@(saved_latency)];
    [_receiveLatencyPopup selectItemAtIndex:
        latency_index == NSNotFound ? 1 : latency_index];
    NSTextField* latency_label = [NSTextField labelWithString:@"Playback buffer"];
    latency_label.font = [NSFont systemFontOfSize:11];
    latency_label.textColor = NSColor.secondaryLabelColor;
    NSStackView* latency_stack = [NSStackView stackViewWithViews:@[
        latency_label, _receiveLatencyPopup,
    ]];
    latency_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    latency_stack.alignment = NSLayoutAttributeLeading;
    latency_stack.spacing = 4;

    NSTextField* output_label = [NSTextField labelWithString:@"Playback output"];
    output_label.font = [NSFont systemFontOfSize:11];
    output_label.textColor = NSColor.secondaryLabelColor;
    NSTextField* output_value = [NSTextField labelWithString:@"System default output"];
    output_value.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    NSButton* sound_settings = [NSButton buttonWithTitle:@"Sound Settings…"
                                                   target:self
                                                   action:@selector(openSoundSettings:)];
    sound_settings.bezelStyle = NSBezelStyleInline;
    NSStackView* output_row = [NSStackView stackViewWithViews:@[output_value, sound_settings]];
    output_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    output_row.alignment = NSLayoutAttributeCenterY;
    output_row.spacing = 8;
    [output_value setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView* output_stack = [NSStackView stackViewWithViews:@[output_label, output_row]];
    output_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    output_stack.alignment = NSLayoutAttributeLeading;
    output_stack.spacing = 4;

    NSTextField* volume_title = [NSTextField labelWithString:@"Volume"];
    volume_title.font = [NSFont systemFontOfSize:11];
    volume_title.textColor = NSColor.secondaryLabelColor;
    _receiveVolumeSlider = [NSSlider sliderWithValue:volume
                                           minValue:0.0
                                           maxValue:1.0
                                             target:self
                                             action:@selector(receiveVolumeChanged:)];
    _receiveVolumeSlider.continuous = YES;
    _receiveVolumeLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%.0f%%", volume * 100.0]];
    _receiveVolumeLabel.font = [NSFont monospacedDigitSystemFontOfSize:12
                                                               weight:NSFontWeightMedium];
    NSStackView* volume_row = [NSStackView stackViewWithViews:@[
        _receiveVolumeSlider, _receiveVolumeLabel,
    ]];
    volume_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    volume_row.alignment = NSLayoutAttributeCenterY;
    volume_row.spacing = 10;
    NSStackView* volume_stack = [NSStackView stackViewWithViews:@[volume_title, volume_row]];
    volume_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    volume_stack.alignment = NSLayoutAttributeLeading;
    volume_stack.spacing = 4;

    _receiveAutoStartButton = [NSButton checkboxWithTitle:
        @"Make this Mac available when SoundMux opens"
                                                     target:self
                                                     action:@selector(receiveAutoStartChanged:)];
    _receiveAutoStartButton.font = [NSFont systemFontOfSize:12];
    _receiveAutoStartButton.state = [defaults boolForKey:@"macReceiverAutoStart"]
        ? NSControlStateValueOn : NSControlStateValueOff;

    _receiveButton = [NSButton buttonWithTitle:@"Make This Mac Available"
                                         target:self
                                         action:@selector(toggleReceiving:)];
    _receiveButton.bezelStyle = NSBezelStyleRounded;
    _receiveButton.controlSize = NSControlSizeLarge;
    _receiveButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _receiveButton.bezelColor = NSColor.systemBlueColor;
    [_receiveButton.heightAnchor constraintEqualToConstant:38].active = YES;

    _receiveStatusLabel = [NSTextField labelWithString:@"Not available to other devices"];
    _receiveStatusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _receiveMetricsLabel = [NSTextField labelWithString:
        @"Start receiving, then choose this Mac from another SoundMux device."];
    _receiveMetricsLabel.textColor = NSColor.secondaryLabelColor;
    _receiveMetricsLabel.font = [NSFont systemFontOfSize:11];
    _receiveMetricsLabel.maximumNumberOfLines = 0;
    _trustedSendersLabel = [NSTextField labelWithString:@"No paired senders"];
    _trustedSendersLabel.textColor = NSColor.tertiaryLabelColor;
    _trustedSendersLabel.font = [NSFont systemFontOfSize:11];
    _forgetSendersButton = [NSButton buttonWithTitle:@"Forget Paired Devices…"
                                               target:self
                                               action:@selector(forgetPairedSenders:)];
    _forgetSendersButton.bezelStyle = NSBezelStyleInline;
    NSStackView* trusted_row = [NSStackView stackViewWithViews:@[
        _trustedSendersLabel, _forgetSendersButton,
    ]];
    trusted_row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    trusted_row.alignment = NSLayoutAttributeCenterY;
    trusted_row.spacing = 8;
    [_trustedSendersLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView* receive_status_stack = [NSStackView stackViewWithViews:@[
        _receiveStatusLabel, _receiveMetricsLabel, trusted_row,
    ]];
    receive_status_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    receive_status_stack.alignment = NSLayoutAttributeLeading;
    receive_status_stack.spacing = 5;

    NSBox* receive_divider = [[NSBox alloc] initWithFrame:NSZeroRect];
    receive_divider.boxType = NSBoxSeparator;
    _receiveView = [NSStackView stackViewWithViews:@[
        availability_title, availability_detail, identity_row, latency_stack,
        output_stack, volume_stack, _receiveAutoStartButton, _receiveButton,
        receive_divider, receive_status_stack,
    ]];
    _receiveView.orientation = NSUserInterfaceLayoutOrientationVertical;
    _receiveView.alignment = NSLayoutAttributeLeading;
    _receiveView.spacing = 10;
    [_receiveView setCustomSpacing:16 afterView:availability_detail];
    [_receiveView setCustomSpacing:16 afterView:_receiveAutoStartButton];

    NSStackView* content = [NSStackView stackViewWithViews:@[
        header, _modeControl, _sendView, _receiveView,
    ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 14;
    [content setCustomSpacing:20 afterView:header];
    [content setCustomSpacing:18 afterView:_modeControl];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [_window.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor constant:32],
        [content.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor constant:-32],
        [content.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor constant:30],
        [header.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_modeControl.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_sendView.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_receiveView.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [receiver_stack.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [source_stack.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [source_row.widthAnchor constraintEqualToAnchor:source_stack.widthAnchor],
        [_sourcePopup.widthAnchor constraintGreaterThanOrEqualToConstant:390],
        [_receiverPopup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_discoveryLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [selected_device_box.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_startButton.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [divider.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [status_stack.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [permission_row.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_hostField.widthAnchor constraintEqualToConstant:270],
        [_portField.widthAnchor constraintEqualToConstant:96],
        [_receiveNameField.widthAnchor constraintEqualToConstant:330],
        [_receivePortField.widthAnchor constraintEqualToConstant:96],
        [identity_row.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [_receiveLatencyPopup.widthAnchor constraintEqualToConstant:210],
        [output_stack.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [output_row.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [volume_stack.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [volume_row.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [_receiveVolumeSlider.widthAnchor constraintGreaterThanOrEqualToConstant:320],
        [_receiveButton.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [receive_divider.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [receive_status_stack.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
        [trusted_row.widthAnchor constraintEqualToAnchor:_receiveView.widthAnchor],
    ]];

    [self modeChanged:nil];
    [self updateTrustedSendersUI];

    _services = [NSMutableArray array];
    [self updateReceiverMenu];
    _serviceBrowser = [[NSNetServiceBrowser alloc] init];
    _serviceBrowser.delegate = self;
    _serviceBrowser.includesPeerToPeer = YES;
    [_serviceBrowser searchForServicesOfType:@"_soundmux._udp."
                                    inDomain:@"local."];

    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    _metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1
                                                    target:self
                                                  selector:@selector(refreshMetrics:)
                                                  userInfo:nil
                                                   repeats:YES];
    if (_receiveAutoStartButton.state == NSControlStateValueOn) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleReceiving:nil]; });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    [_metricsTimer invalidate];
    [_serviceBrowser stop];
    for (NSNetService* service in _services) [service stop];
    if (_sender) {
        _sender->stop();
        _sender.reset();
    }
    if (_receiver) {
        _receiver->stop();
        _receiver.reset();
    }
}

- (void)modeChanged:(id)sender {
    (void)sender;
    const BOOL receiving = _modeControl.selectedSegment == 1;
    _sendView.hidden = receiving;
    _receiveView.hidden = !receiving;
    [NSUserDefaults.standardUserDefaults setInteger:_modeControl.selectedSegment
                                             forKey:@"macAppMode"];
}

- (void)updateTrustedSendersUI {
    NSDictionary* names = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"macReceiverTrustedNames"];
    const NSUInteger count = names.count;
    if (count == 0) {
        _trustedSendersLabel.stringValue = @"No paired senders";
    } else if (count == 1) {
        NSString* name = names.allValues.firstObject;
        _trustedSendersLabel.stringValue = [NSString stringWithFormat:
            @"Paired with %@", name.length ? name : @"1 device"];
    } else {
        _trustedSendersLabel.stringValue = [NSString stringWithFormat:
            @"Paired with %lu devices", (unsigned long)count];
    }
    _forgetSendersButton.enabled = count > 0;
}

- (void)toggleReceiving:(id)sender {
    (void)sender;
    if (_receiver) {
        _receiver->stop();
        _receiver.reset();
        _receiveNameField.enabled = YES;
        _receivePortField.enabled = YES;
        _receiveLatencyPopup.enabled = YES;
        _receiveButton.title = @"Make This Mac Available";
        _receiveButton.bezelColor = NSColor.systemBlueColor;
        _receiveStatusLabel.stringValue = @"Not available to other devices";
        _receiveMetricsLabel.stringValue =
            @"Start receiving, then choose this Mac from another SoundMux device.";
        return;
    }

    NSString* name = [_receiveNameField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    const NSInteger port = _receivePortField.integerValue;
    if (!name.length || port < 1 || port > 65'534) {
        _receiveStatusLabel.stringValue = @"Enter a name and a valid UDP port.";
        return;
    }
    const NSInteger latency_values[] = {40, 60, 100, 160};
    NSInteger latency_index = _receiveLatencyPopup.indexOfSelectedItem;
    if (latency_index < 0 || latency_index > 3) latency_index = 1;
    const NSInteger latency = latency_values[latency_index];
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:name forKey:@"macReceiverName"];
    [defaults setInteger:port forKey:@"macReceiverPort"];
    [defaults setInteger:latency forKey:@"macReceiverLatency"];

    _receiveStatusLabel.stringValue = @"Starting receiver…";
    try {
        auto pairing = [](const std::string& sender_name, const std::string& code) {
            __block BOOL approved = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSAlert* alert = [[NSAlert alloc] init];
                NSString* sender = [NSString stringWithUTF8String:sender_name.c_str()];
                alert.messageText = [NSString stringWithFormat:
                    @"Pair with %@", sender.length ? sender : @"this device"];
                alert.informativeText =
                    @"Compare this code with the one shown on the sending device.";
                alert.alertStyle = NSAlertStyleInformational;
                alert.icon = [NSImage imageWithSystemSymbolName:@"checkmark.shield.fill"
                                       accessibilityDescription:@"Secure pairing"];
                NSTextField* code_label = [NSTextField labelWithString:
                    [NSString stringWithUTF8String:code.c_str()]];
                code_label.font = [NSFont monospacedDigitSystemFontOfSize:32
                                                                  weight:NSFontWeightBold];
                code_label.alignment = NSTextAlignmentCenter;
                NSTextField* safety = [NSTextField labelWithString:
                    @"Only approved devices can send audio to this Mac."];
                safety.font = [NSFont systemFontOfSize:11];
                safety.textColor = NSColor.secondaryLabelColor;
                safety.alignment = NSTextAlignmentCenter;
                NSStackView* pairing_view = [NSStackView stackViewWithViews:@[
                    code_label, safety,
                ]];
                pairing_view.orientation = NSUserInterfaceLayoutOrientationVertical;
                pairing_view.alignment = NSLayoutAttributeCenterX;
                pairing_view.spacing = 8;
                pairing_view.frame = NSMakeRect(0, 0, 320, 62);
                alert.accessoryView = pairing_view;
                [alert addButtonWithTitle:@"Pair Device"];
                [alert addButtonWithTitle:@"Not Now"];
                approved = [alert runModal] == NSAlertFirstButtonReturn;
            });
            return approved;
        };
        _receiver = std::make_unique<MacReceiverRuntime>(MacReceiverConfig{
            .port = static_cast<std::uint16_t>(port),
            .latency_ms = static_cast<std::uint32_t>(latency),
            .device_id = persistent_sender_value(@"soundMuxDeviceID", NO).UTF8String,
            .device_name = name.UTF8String,
        }, std::move(pairing));
        _receiver->set_volume(static_cast<float>(_receiveVolumeSlider.doubleValue));
    } catch (const std::exception& error) {
        _receiveStatusLabel.stringValue = [NSString stringWithFormat:
            @"Could not start: %s", error.what()];
        return;
    }
    _receiveNameField.enabled = NO;
    _receivePortField.enabled = NO;
    _receiveLatencyPopup.enabled = NO;
    _receiveButton.title = @"Stop Receiving";
    _receiveButton.bezelColor = NSColor.systemRedColor;
    _receiveStatusLabel.stringValue = @"Available nearby";
    _receiveMetricsLabel.stringValue = [NSString stringWithFormat:
        @"Listening securely on UDP %ld · waiting for audio", (long)port];
}

- (void)receiveVolumeChanged:(id)sender {
    (void)sender;
    const double volume = _receiveVolumeSlider.doubleValue;
    _receiveVolumeLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", volume * 100.0];
    [NSUserDefaults.standardUserDefaults setDouble:volume forKey:@"macReceiverVolume"];
    if (_receiver) _receiver->set_volume(static_cast<float>(volume));
}

- (void)receiveAutoStartChanged:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults
        setBool:_receiveAutoStartButton.state == NSControlStateValueOn
         forKey:@"macReceiverAutoStart"];
}

- (void)forgetPairedSenders:(id)sender {
    (void)sender;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Forget all paired senders?";
    alert.informativeText =
        @"They will need your approval and a matching code the next time they connect.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Forget Devices"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:@"macReceiverTrustedKeys"];
    [defaults removeObjectForKey:@"macReceiverTrustedNames"];
    [self updateTrustedSendersUI];
}

- (void)openSoundSettings:(id)sender {
    (void)sender;
    NSURL* settings = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.Sound-Settings.extension"];
    [[NSWorkspace sharedWorkspace] openURL:settings];
}

- (void)enableMediaControls:(id)sender {
    (void)sender;
    request_media_control_access(true);
    _mediaControlLabel.stringValue =
        @"Approve SoundMux in System Settings, then return here.";
}

- (void)updateReceiverMenu {
    NSNetService* previously_selected = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        previously_selected = _receiverPopup.selectedItem.representedObject;
    }
    NSDictionary* previous_saved = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSDictionary.class]) {
        previous_saved = _receiverPopup.selectedItem.representedObject;
    }
    NSString* previous_id = previously_selected ? service_identifier(previously_selected)
                                                 : previous_saved[@"id"];
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* remembered_id = [defaults stringForKey:@"lastReceiverID"];

    [_receiverPopup removeAllItems];
    NSMenuItem* item_to_select = nil;
    BOOL added_nearby_header = NO;
    BOOL found_remembered = NO;
    for (NSNetService* service in _services) {
        if (!service.hostName.length || service.port <= 0) continue;
        NSString* protocol_version = service_text(service, @"protocol");
        NSString* session_version = service_text(service, @"session");
        NSString* capabilities = service_text(service, @"capabilities");
        if (![protocol_version isEqualToString:@"3"] ||
            ![session_version isEqualToString:@"3"] ||
            ![capabilities containsString:@"audio"]) {
            continue;
        }
        if ([service_identifier(service) isEqualToString:
                persistent_sender_value(@"soundMuxDeviceID", NO)]) {
            continue;
        }
        if (!added_nearby_header) {
            NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:@"Nearby Devices"
                                                           action:nil
                                                    keyEquivalent:@""];
            header.enabled = NO;
            [_receiverPopup.menu addItem:header];
            added_nearby_header = YES;
        }
        [_receiverPopup addItemWithTitle:service_display_name(service)];
        NSMenuItem* item = _receiverPopup.lastItem;
        NSString* platform = service_platform(service);
        NSString* symbol = [platform isEqualToString:@"ios"]
            ? @"iphone"
            : ([platform isEqualToString:@"windows"] ? @"pc" : @"desktopcomputer");
        item.image = [NSImage imageWithSystemSymbolName:symbol
                              accessibilityDescription:platform];
        item.representedObject = service;
        NSString* candidate_id = service_identifier(service);
        if (remembered_id.length && [candidate_id isEqualToString:remembered_id]) {
            found_remembered = YES;
            item.state = NSControlStateValueOn;
        }
        if ((previous_id.length && [candidate_id isEqualToString:previous_id]) ||
            (!previous_id.length && remembered_id.length &&
             [candidate_id isEqualToString:remembered_id])) {
            item_to_select = item;
        }
    }

    NSString* saved_host = [defaults stringForKey:@"receiverHost"];
    NSString* saved_port = [defaults stringForKey:@"receiverPort"];
    NSString* saved_name = [defaults stringForKey:@"lastReceiverName"];
    NSString* saved_platform = [defaults stringForKey:@"lastReceiverPlatform"];
    if (remembered_id.length && saved_host.length && saved_name.length &&
        !found_remembered) {
        if (_receiverPopup.numberOfItems > 0) {
            [_receiverPopup.menu addItem:NSMenuItem.separatorItem];
        }
        NSMenuItem* header = [[NSMenuItem alloc] initWithTitle:@"Remembered Device"
                                                       action:nil
                                                keyEquivalent:@""];
        header.enabled = NO;
        [_receiverPopup.menu addItem:header];
        [_receiverPopup addItemWithTitle:[NSString stringWithFormat:@"%@ — Saved", saved_name]];
        NSMenuItem* saved_item = _receiverPopup.lastItem;
        saved_item.tag = 9'002;
        saved_item.image = [NSImage imageWithSystemSymbolName:
            [saved_platform isEqualToString:@"ios"] ? @"iphone" : @"desktopcomputer"
                                     accessibilityDescription:@"Saved device"];
        saved_item.representedObject = @{
            @"id": remembered_id,
            @"name": saved_name,
            @"host": saved_host,
            @"port": saved_port.length ? saved_port : @"48101",
            @"platform": saved_platform.length ? saved_platform : @"unknown",
        };
        if (!previous_id.length || [previous_id isEqualToString:remembered_id]) {
            item_to_select = saved_item;
        }
    }

    if (_receiverPopup.numberOfItems > 0) {
        [_receiverPopup.menu addItem:NSMenuItem.separatorItem];
    }
    [_receiverPopup addItemWithTitle:@"Manual address…"];
    NSMenuItem* manual_item = _receiverPopup.lastItem;
    manual_item.tag = 9'001;
    manual_item.image = [NSImage imageWithSystemSymbolName:@"network"
                                     accessibilityDescription:@"Network address"];

    if (_preferManual) {
        [_receiverPopup selectItem:manual_item];
    } else if (item_to_select) {
        [_receiverPopup selectItem:item_to_select];
    } else {
        NSMenuItem* first_selectable = nil;
        for (NSMenuItem* item in _receiverPopup.itemArray) {
            if ([item.representedObject isKindOfClass:NSNetService.class] ||
                item.tag == 9'002) {
                first_selectable = item;
                break;
            }
        }
        [_receiverPopup selectItem:first_selectable ? first_selectable : manual_item];
    }
    [self updateReceiverSelectionUI];
}

- (void)autoReconnectChanged:(id)sender {
    (void)sender;
    const BOOL enabled = _autoReconnectButton.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"autoReconnect"];
    if (enabled) {
        _manualDisconnect = NO;
        [self scheduleAutoReconnectIfPossible];
    }
}

- (void)scheduleAutoReconnectIfPossible {
    if (_sender || _starting || _reconnectScheduled || _manualDisconnect ||
        _autoReconnectButton.state != NSControlStateValueOn) {
        return;
    }
    NSNetService* service = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        service = _receiverPopup.selectedItem.representedObject;
    }
    NSString* remembered_id = [NSUserDefaults.standardUserDefaults
        stringForKey:@"lastReceiverID"];
    if (!service || !remembered_id.length ||
        ![service_identifier(service) isEqualToString:remembered_id]) {
        return;
    }
    _reconnectScheduled = YES;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
            self->_reconnectScheduled = NO;
            if (!self->_sender && !self->_starting && !self->_manualDisconnect) {
                [self toggleSending:nil];
            }
        });
}

- (void)receiverSelectionChanged:(id)sender {
    (void)sender;
    _preferManual = _receiverPopup.selectedItem.tag == 9'001;
    [self updateReceiverSelectionUI];
    const BOOL has_resolved_target =
        [_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class] ||
        [_receiverPopup.selectedItem.representedObject isKindOfClass:NSDictionary.class];
    if (_sender && !_starting && has_resolved_target) {
        [self toggleSending:nil];
        _statusLabel.stringValue = @"Handing off audio…";
        dispatch_async(dispatch_get_main_queue(), ^{ [self toggleSending:nil]; });
    }
}

- (NSString*)selectedReceiverIdentifier {
    id represented = _receiverPopup.selectedItem.representedObject;
    if ([represented isKindOfClass:NSNetService.class]) {
        return service_identifier((NSNetService*)represented);
    }
    if ([represented isKindOfClass:NSDictionary.class]) {
        return ((NSDictionary*)represented)[@"id"];
    }
    return nil;
}

- (void)updateReceiverSelectionUI {
    NSNetService* service = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        service = _receiverPopup.selectedItem.representedObject;
    }
    NSDictionary* saved = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSDictionary.class]) {
        saved = _receiverPopup.selectedItem.representedObject;
    }
    _manualStack.hidden = service != nil || saved != nil;
    NSString* identifier = [self selectedReceiverIdentifier];
    const BOOL trusted = is_trusted_receiver(identifier);
    if (service) {
        NSString* platform = service_platform(service);
        NSString* symbol = [platform isEqualToString:@"ios"] ? @"iphone"
            : ([platform isEqualToString:@"windows"] ? @"pc" : @"desktopcomputer");
        _selectedDeviceIcon.image = [NSImage imageWithSystemSymbolName:symbol
                                              accessibilityDescription:platform];
        _selectedDeviceNameLabel.stringValue = service_display_name(service);
        _selectedDeviceSecurityLabel.stringValue = trusted
            ? @"Nearby · Paired · Encrypted"
            : @"Nearby · Approval required on first connection";
        _discoveryLabel.stringValue = [NSString stringWithFormat:
            @"%@ • %@:%ld",
            service_platform_display(service),
            service_connect_host(service), (long)service.port];
    } else if (saved) {
        NSString* platform = saved[@"platform"];
        _selectedDeviceIcon.image = [NSImage imageWithSystemSymbolName:
            [platform isEqualToString:@"ios"] ? @"iphone" : @"desktopcomputer"
                                              accessibilityDescription:platform];
        NSString* saved_name = saved[@"name"];
        _selectedDeviceNameLabel.stringValue = saved_name.length ? saved_name : @"Saved device";
        _selectedDeviceSecurityLabel.stringValue = trusted
            ? [NSString stringWithFormat:@"Remembered · Paired · Seen %@",
                remembered_last_seen_text()]
            : @"Remembered address · Pairing required";
        _discoveryLabel.stringValue = [NSString stringWithFormat:
            @"Not visible nearby • saved address %@:%@", saved[@"host"], saved[@"port"]];
    } else if (_services.count == 0) {
        _selectedDeviceIcon.image = [NSImage imageWithSystemSymbolName:@"network"
                                              accessibilityDescription:@"Manual address"];
        _selectedDeviceNameLabel.stringValue = @"Manual connection";
        _selectedDeviceSecurityLabel.stringValue = @"Identity will be verified before streaming";
        _discoveryLabel.stringValue =
            @"No nearby receiver yet—open SoundMux there, or use a manual address.";
    } else {
        _selectedDeviceIcon.image = [NSImage imageWithSystemSymbolName:@"network"
                                              accessibilityDescription:@"Manual address"];
        _selectedDeviceNameLabel.stringValue = @"Manual connection";
        _selectedDeviceSecurityLabel.stringValue = @"Identity will be verified before streaming";
        _discoveryLabel.stringValue = @"Using a direct network address.";
    }
    _forgetReceiverButton.hidden = !trusted;
    _forgetReceiverButton.enabled = !_sender && !_starting;
}

- (void)forgetSelectedReceiver:(id)sender {
    (void)sender;
    NSString* identifier = [self selectedReceiverIdentifier];
    if (!identifier.length || !is_trusted_receiver(identifier)) return;
    NSString* name = _selectedDeviceNameLabel.stringValue;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Forget %@?", name];
    alert.informativeText =
        @"The next connection will require you to compare and approve a new six-digit code on both devices.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Forget Device"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    forget_receiver_key(identifier);
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:@"lastReceiverID"] isEqualToString:identifier]) {
        [defaults removeObjectForKey:@"lastReceiverID"];
        [defaults removeObjectForKey:@"lastReceiverName"];
        [defaults removeObjectForKey:@"lastReceiverPlatform"];
        [defaults removeObjectForKey:@"lastReceiverSeen"];
        [defaults removeObjectForKey:@"receiverHost"];
    }
    [self updateReceiverMenu];
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)browser
            didFindService:(NSNetService*)service
                moreComing:(BOOL)moreComing {
    (void)browser;
    (void)moreComing;
    if ([_services containsObject:service]) return;
    service.delegate = self;
    service.includesPeerToPeer = YES;
    [_services addObject:service];
    [service resolveWithTimeout:5];
    _discoveryLabel.stringValue = @"Found a receiver—resolving its address…";
}

- (void)netServiceBrowser:(NSNetServiceBrowser*)browser
          didRemoveService:(NSNetService*)service
                moreComing:(BOOL)moreComing {
    (void)browser;
    (void)moreComing;
    [service stop];
    [_services removeObject:service];
    [self updateReceiverMenu];
}

- (void)netServiceDidResolveAddress:(NSNetService*)sender {
    NSString* remembered_id = [NSUserDefaults.standardUserDefaults
        stringForKey:@"lastReceiverID"];
    if (remembered_id.length &&
        [service_identifier(sender) isEqualToString:remembered_id]) {
        [NSUserDefaults.standardUserDefaults setObject:NSDate.date
                                                forKey:@"lastReceiverSeen"];
    }
    [sender stop];
    [self updateReceiverMenu];
    [self scheduleAutoReconnectIfPossible];
}

- (void)netService:(NSNetService*)sender
      didNotResolve:(NSDictionary<NSString*, NSNumber*>*)errorDict {
    (void)sender;
    (void)errorDict;
    _discoveryLabel.stringValue = @"A receiver was found but its address could not be resolved.";
}

- (void)toggleSending:(id)sender {
    if (_sender || _starting) {
        if (sender) _manualDisconnect = YES;
        if (_startCancellation) {
            _startCancellation->store(true, std::memory_order_relaxed);
        }
        _starting = NO;
        if (_sender) {
            _sender->stop();
            _sender.reset();
        }
        _hostField.enabled = YES;
        _portField.enabled = YES;
        _receiverPopup.enabled = YES;
        _sourcePopup.enabled = YES;
        _startButton.title = @"Connect";
        _startButton.bezelColor = NSColor.systemBlueColor;
        _statusLabel.stringValue = @"Disconnected";
        _healthLabel.stringValue = @"Health  —";
        _healthLabel.textColor = NSColor.secondaryLabelColor;
        _metricsLabel.stringValue = @"No active stream";
        [self updateReceiverSelectionUI];
        return;
    }
    _manualDisconnect = NO;

    NSString* host = nil;
    NSInteger port_number = 0;
    NSString* receiver_name = nil;
    NSNetService* service = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        service = _receiverPopup.selectedItem.representedObject;
    }
    NSDictionary* saved = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSDictionary.class]) {
        saved = _receiverPopup.selectedItem.representedObject;
    }
    if (service) {
        host = service_connect_host(service);
        port_number = service.port;
        receiver_name = service_display_name(service);
    } else if (saved) {
        host = saved[@"host"];
        port_number = [saved[@"port"] integerValue];
        receiver_name = saved[@"name"];
    } else {
        host = [_hostField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        port_number = _portField.integerValue;
        receiver_name = host;
    }
    if (!host.length || port_number < 1 || port_number > 65'534) {
        _statusLabel.stringValue = @"Enter a valid receiver address and UDP port.";
        return;
    }
    NSString* previously_saved_host = [NSUserDefaults.standardUserDefaults
        stringForKey:@"receiverHost"];
    [NSUserDefaults.standardUserDefaults setObject:host forKey:@"receiverHost"];
    [NSUserDefaults.standardUserDefaults
        setObject:[NSString stringWithFormat:@"%ld", (long)port_number]
                                             forKey:@"receiverPort"];
    if (service) {
        [NSUserDefaults.standardUserDefaults
            setObject:service_identifier(service)
               forKey:@"lastReceiverID"];
        [NSUserDefaults.standardUserDefaults setObject:service_platform(service)
                                                forKey:@"lastReceiverPlatform"];
        [NSUserDefaults.standardUserDefaults setObject:NSDate.date
                                                forKey:@"lastReceiverSeen"];
    } else if (saved[@"id"]) {
        [NSUserDefaults.standardUserDefaults setObject:saved[@"id"]
                                                forKey:@"lastReceiverID"];
    }
    if (receiver_name.length) {
        [NSUserDefaults.standardUserDefaults setObject:receiver_name
                                                forKey:@"lastReceiverName"];
    }
    _starting = YES;
    _startCancellation = std::make_shared<std::atomic<bool>>(false);
    const auto cancellation = _startCancellation;
    _hostField.enabled = NO;
    _portField.enabled = NO;
    _receiverPopup.enabled = NO;
    _sourcePopup.enabled = NO;
    _forgetReceiverButton.enabled = NO;
    _startButton.title = @"Cancel";
    _startButton.bezelColor = NSColor.systemOrangeColor;
    _statusLabel.stringValue = @"Connecting…";
    _metricsLabel.stringValue = @"Verifying the receiver session";

    const std::string destination(host.UTF8String);
    NSString* expected_identifier = service ? service_identifier(service) : saved[@"id"];
    if (!expected_identifier.length) {
        NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
        if (previously_saved_host.length && [previously_saved_host isEqualToString:host]) {
            expected_identifier = [defaults stringForKey:@"lastReceiverID"];
        }
    }
    const std::string expected_receiver_id = expected_identifier.length
        ? std::string(expected_identifier.UTF8String) : std::string();
    std::vector<AudioObjectID> included_processes;
    NSDictionary* selected_source = [_sourcePopup.selectedItem.representedObject
        isKindOfClass:NSDictionary.class]
        ? _sourcePopup.selectedItem.representedObject : nil;
    if (selected_source[@"object"]) {
        included_processes.push_back(
            static_cast<AudioObjectID>([selected_source[@"object"] unsignedIntValue]));
    }
    _activeReceiverName = receiver_name.length ? [receiver_name copy] : @"receiver";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CoreAudioTapSender* new_sender = nullptr;
        std::string error_message;
        try {
            new_sender = new CoreAudioTapSender(
                destination,
                static_cast<std::uint16_t>(port_number),
                persistent_sender_value(@"soundMuxDeviceID", NO).UTF8String,
                local_sender_name().UTF8String,
                expected_receiver_id,
                included_processes,
                [self](const std::string& status) {
                    NSString* text = [NSString stringWithUTF8String:status.c_str()];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self->_starting) self->_statusLabel.stringValue = text;
                    });
                },
                [self](const std::string& code, const std::string& receiver) {
                    __block BOOL approved = NO;
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        if (!self->_starting) return;
                        NSAlert* alert = [[NSAlert alloc] init];
                        NSString* receiver_name = [NSString
                            stringWithUTF8String:receiver.c_str()];
                        alert.messageText = [NSString stringWithFormat:
                            @"Pair with %@", receiver_name];
                        alert.informativeText =
                            @"Compare this code with the one shown on the other device.";
                        alert.icon = [NSImage imageWithSystemSymbolName:@"checkmark.shield.fill"
                                               accessibilityDescription:@"Secure pairing"];
                        NSTextField* code_label = [NSTextField labelWithString:
                            [NSString stringWithUTF8String:code.c_str()]];
                        code_label.font = [NSFont monospacedDigitSystemFontOfSize:32
                                                                          weight:NSFontWeightBold];
                        code_label.alignment = NSTextAlignmentCenter;
                        NSTextField* safety = [NSTextField labelWithString:
                            @"SoundMux will remember this device after approval."];
                        safety.font = [NSFont systemFontOfSize:11];
                        safety.textColor = NSColor.secondaryLabelColor;
                        safety.alignment = NSTextAlignmentCenter;
                        NSStackView* pairing_view = [NSStackView stackViewWithViews:@[
                            code_label, safety,
                        ]];
                        pairing_view.orientation = NSUserInterfaceLayoutOrientationVertical;
                        pairing_view.alignment = NSLayoutAttributeCenterX;
                        pairing_view.spacing = 8;
                        pairing_view.frame = NSMakeRect(0, 0, 320, 62);
                        alert.accessoryView = pairing_view;
                        [alert addButtonWithTitle:@"Pair Device"];
                        [alert addButtonWithTitle:@"Not Now"];
                        approved = [alert runModal] == NSAlertFirstButtonReturn;
                    });
                    return approved;
                },
                [cancellation] {
                    return cancellation->load(std::memory_order_relaxed);
                });
            new_sender->start();
        } catch (const std::exception& error) {
            error_message = error.what();
            delete new_sender;
            new_sender = nullptr;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_starting) {
                self->_startCancellation.reset();
                if (new_sender) {
                    new_sender->stop();
                    delete new_sender;
                }
                return;
            }
            self->_starting = NO;
            self->_startCancellation.reset();
            if (!new_sender) {
                self->_hostField.enabled = YES;
                self->_portField.enabled = YES;
                self->_receiverPopup.enabled = YES;
                self->_sourcePopup.enabled = YES;
                self->_startButton.title = @"Connect";
                self->_startButton.bezelColor = NSColor.systemBlueColor;
                self->_statusLabel.stringValue = [NSString
                    stringWithFormat:@"Could not start: %s", error_message.c_str()];
                self->_metricsLabel.stringValue = @"Check that the iPhone receiver is available.";
                [self updateReceiverSelectionUI];
                return;
            }
            self->_sender.reset(new_sender);
            self->_receiverPopup.enabled = YES;
            self->_sourcePopup.enabled = YES;
            self->_startButton.title = @"Disconnect";
            self->_startButton.bezelColor = NSColor.systemRedColor;
            self->_statusLabel.stringValue = [NSString stringWithFormat:
                @"Connected to %@", self->_activeReceiverName];
            self->_healthLabel.stringValue = @"Health  Connecting";
            self->_healthLabel.textColor = NSColor.systemOrangeColor;
            self->_lastCaptureDrops = 0;
            self->_lastSendFailures = 0;
            [self updateReceiverSelectionUI];
        });
    });
}

- (void)refreshMetrics:(NSTimer*)timer {
    (void)timer;
    const BOOL controls_enabled = request_media_control_access(false);
    _mediaControlLabel.stringValue = controls_enabled
        ? @"Phone play/pause and skip controls are enabled."
        : @"Phone playback controls are optional.";
    _mediaControlButton.title = controls_enabled ? @"Enabled" : @"Enable Controls…";
    _mediaControlButton.enabled = !controls_enabled;
    [self updateTrustedSendersUI];
    if (_receiver) {
        const auto received = _receiver->snapshot();
        if (received.connected) {
            NSString* sender_name = received.sender_name.empty()
                ? @"a paired device"
                : [NSString stringWithUTF8String:received.sender_name.c_str()];
            _receiveStatusLabel.stringValue = received.playing
                ? [NSString stringWithFormat:@"Playing audio from %@", sender_name]
                : [NSString stringWithFormat:@"Connected to %@", sender_name];
            _receiveMetricsLabel.stringValue = [NSString stringWithFormat:
                @"Packets  %llu   •   Recovered  %llu   •   Lost  %llu\nBuffer  %.0f ms   •   Concealed  %llu   •   Underruns  %llu",
                received.packets_received,
                received.fec_recovered,
                received.packets_lost,
                received.buffered_frames * 1000.0 /
                    multipoint::protocol::kSampleRate,
                received.concealed_packets,
                received.audio_underruns];
        } else {
            _receiveStatusLabel.stringValue = @"Available nearby";
            _receiveMetricsLabel.stringValue = [NSString stringWithFormat:
                @"Listening securely on UDP %@ · waiting for audio",
                _receivePortField.stringValue];
        }
    }
    if (!_sender) return;
    const auto stats = _sender->snapshot();
    if (!stats.receiver_alive && stats.heartbeat_age_ms >= 4'000) {
        _statusLabel.stringValue = @"Receiver went offline";
        _metricsLabel.stringValue = @"Waiting for it to return…";
        _sender->stop();
        _sender.reset();
        _hostField.enabled = YES;
        _portField.enabled = YES;
        _receiverPopup.enabled = YES;
        _sourcePopup.enabled = YES;
        _startButton.title = @"Connect";
        _startButton.bezelColor = NSColor.systemBlueColor;
        _healthLabel.stringValue = @"Health  Offline";
        _healthLabel.textColor = NSColor.systemRedColor;
        [self scheduleAutoReconnectIfPossible];
        return;
    }
    const auto failures = stats.send_failures + stats.control_failures;
    const bool new_failure = failures > _lastSendFailures;
    const bool new_capture_drop = stats.capture_drops > _lastCaptureDrops;
    if (new_failure || new_capture_drop || stats.heartbeat_age_ms >= 2'500) {
        _healthLabel.stringValue = @"Health  Recovering";
        _healthLabel.textColor = NSColor.systemRedColor;
    } else if (stats.heartbeat_age_ms >= 1'250) {
        _healthLabel.stringValue = @"Health  Unstable";
        _healthLabel.textColor = NSColor.systemOrangeColor;
    } else {
        _healthLabel.stringValue = @"Health  Excellent";
        _healthLabel.textColor = NSColor.systemGreenColor;
    }
    _lastCaptureDrops = stats.capture_drops;
    _lastSendFailures = failures;
    _metricsLabel.stringValue = [NSString stringWithFormat:
        @"Audio packets  %llu    •    FEC packets  %llu\nRemote commands  %llu%@    •    Drops / failures  %llu / %llu    •    Last response %llu ms ago",
        stats.audio_packets,
        stats.parity_packets,
        stats.control_commands,
        stats.media_control_access ? @"" : @" (Accessibility needed)",
        stats.capture_drops,
        stats.send_failures + stats.control_failures,
        stats.heartbeat_age_ms];
}

@end

int run_gui() {
    @autoreleasepool {
        NSApplication* application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        SoundMuxSenderAppDelegate* delegate = [[SoundMuxSenderAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
        return EXIT_SUCCESS;
    }
}

int main(int argc, char** argv) {
    @autoreleasepool {
        try {
            if (argc == 1) return run_gui();
            if (argc > 3) {
                std::cerr << "Usage: multipoint_mac_sender <iphone-host> [port]\n";
                return EXIT_FAILURE;
            }
            const std::string host = argv[1];
            const int port_number = argc > 2 ? std::stoi(argv[2]) : 48101;
            if (port_number < 1 || port_number > 65'534) {
                throw std::invalid_argument("UDP port is out of range");
            }

            CoreAudioTapSender sender(
                host,
                static_cast<std::uint16_t>(port_number),
                persistent_sender_value(@"soundMuxDeviceID", NO).UTF8String,
                local_sender_name().UTF8String,
                "",
                {},
                [](const std::string& status) { std::cout << status << '\n'; },
                [](const std::string& code, const std::string& receiver) {
                    std::cout << "Verify " << receiver << " shows code " << code
                              << ". Type yes to continue: " << std::flush;
                    std::string answer;
                    std::getline(std::cin, answer);
                    return answer == "yes" || answer == "y";
                });
            sender.start();
            std::signal(SIGINT, handle_signal);
            std::signal(SIGTERM, handle_signal);
            const auto& format = sender.format();
            std::cout << "Streaming pure Core Audio system output to " << host << ':'
                      << port_number << "\nFormat: " << format.mSampleRate << " Hz, "
                      << format.mChannelsPerFrame
                      << " channels, float32 -> 48000 Hz stereo PCM16 wire"
                      << " (Ctrl-C to stop)\n";

            auto next_stats = std::chrono::steady_clock::now() + std::chrono::seconds(1);
            while (g_running) {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                const auto now = std::chrono::steady_clock::now();
                if (now >= next_stats) {
                    sender.print_stats();
                    next_stats = now + std::chrono::seconds(1);
                }
            }
            sender.stop();
            return EXIT_SUCCESS;
        } catch (const std::exception& error) {
            std::cerr << "Mac sender error: " << error.what() << '\n';
            return EXIT_FAILURE;
        }
    }
}
