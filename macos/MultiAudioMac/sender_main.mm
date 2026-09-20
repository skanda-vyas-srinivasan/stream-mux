#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/clock/monotonic_clock.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/transport/sender_engine.h"

#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import <IOKit/hidsystem/ev_keymap.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <memory>
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

class CoreAudioTapSender {
public:
    CoreAudioTapSender(const std::string& host, std::uint16_t port)
        : udp_(host, port),
          control_receiver_(std::make_unique<multipoint::network::UdpReceiver>(
              control_port_for(port))),
          sender_(multipoint::clock::monotonic_time_ns()),
          audio_ring_(kCaptureRingFrames, multipoint::protocol::kChannelCount) {
        create_tap();
        create_aggregate_device();
        create_io_proc();
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
                  << " ring_frames=" << stats.ring_frames << '\n';
    }

    [[nodiscard]] const AudioStreamBasicDescription& format() const {
        return tap_format_;
    }

private:
    void create_tap() {
        CATapDescription* description = [[CATapDescription alloc]
            initStereoGlobalTapButExcludeProcesses:@[]];
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
        if (tap_format_.mSampleRate != multipoint::protocol::kSampleRate) {
            throw std::runtime_error(
                "Core Audio tap sample rate is " +
                std::to_string(tap_format_.mSampleRate) +
                " Hz; SoundMux currently requires 48000 Hz");
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
        while (running_.load(std::memory_order_acquire)) {
            if (audio_ring_.available_to_read() <
                multipoint::protocol::kFramesPerPacket) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            audio_ring_.read(
                packet_samples.data(), multipoint::protocol::kFramesPerPacket);
            try {
                const auto datagrams = sender_.push_audio(
                    packet_samples, multipoint::clock::monotonic_time_ns());
                const auto stats = sender_.stats();
                audio_packets_.store(stats.audio_packets, std::memory_order_relaxed);
                parity_packets_.store(stats.parity_packets, std::memory_order_relaxed);
                for (const auto& datagram : datagrams) udp_.send(datagram);
            } catch (const std::exception& error) {
                const auto failures =
                    send_failures_.fetch_add(1, std::memory_order_relaxed) + 1;
                if (failures == 1 || failures % 100 == 0) {
                    std::cerr << "send error: " << error.what() << '\n';
                }
            }
        }
    }

    void control_loop() {
        std::array<std::byte, 64> datagram{};
        while (running_.load(std::memory_order_acquire)) {
            try {
                const auto size = control_receiver_->receive(datagram);
                if (size == 0) continue;
                const std::string_view command(
                    reinterpret_cast<const char*>(datagram.data()), size);
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
    std::array<float, kMaximumIOFrames * multipoint::protocol::kChannelCount>
        capture_scratch_{};
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
};

}  // namespace

@interface SoundMuxSenderAppDelegate : NSObject
    <NSApplicationDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@end

@implementation SoundMuxSenderAppDelegate {
    NSWindow* _window;
    NSPopUpButton* _receiverPopup;
    NSTextField* _discoveryLabel;
    NSStackView* _manualStack;
    NSTextField* _hostField;
    NSTextField* _portField;
    NSTextField* _statusLabel;
    NSTextField* _metricsLabel;
    NSButton* _startButton;
    NSTimer* _metricsTimer;
    NSNetServiceBrowser* _serviceBrowser;
    NSMutableArray<NSNetService*>* _services;
    NSString* _activeReceiverName;
    std::unique_ptr<CoreAudioTapSender> _sender;
    BOOL _starting;
    BOOL _preferManual;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 460, 450)
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
    if (!saved_host.length) saved_host = @"100.65.45.43";
    if (!saved_port.length) saved_port = @"48101";

    NSImageView* app_icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    app_icon.image = [NSImage imageWithSystemSymbolName:@"waveform.path"
                              accessibilityDescription:@"SoundMux"];
    app_icon.contentTintColor = NSColor.controlAccentColor;
    app_icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [app_icon.widthAnchor constraintEqualToConstant:44].active = YES;
    [app_icon.heightAnchor constraintEqualToConstant:44].active = YES;

    NSTextField* title = [NSTextField labelWithString:@"Send Mac audio to iPhone"];
    title.font = [NSFont systemFontOfSize:23 weight:NSFontWeightSemibold];
    NSTextField* subtitle = [NSTextField labelWithString:@"Pure system audio. No screen capture."];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.font = [NSFont systemFontOfSize:13];

    NSStackView* header = [NSStackView stackViewWithViews:@[app_icon, title, subtitle]];
    header.orientation = NSUserInterfaceLayoutOrientationVertical;
    header.alignment = NSLayoutAttributeCenterX;
    header.spacing = 6;

    NSTextField* receiver_label = [NSTextField labelWithString:@"iPhone"];
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

    _hostField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _hostField.stringValue = saved_host;
    _hostField.placeholderString = @"iPhone IP address";
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
        receiver_label, _receiverPopup, _discoveryLabel, _manualStack,
    ]];
    receiver_stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    receiver_stack.alignment = NSLayoutAttributeLeading;
    receiver_stack.spacing = 7;

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

    NSTextField* permission_note = [NSTextField labelWithString:
        @"Phone media buttons require Accessibility permission on this Mac."];
    permission_note.textColor = NSColor.tertiaryLabelColor;
    permission_note.maximumNumberOfLines = 0;
    permission_note.font = [NSFont systemFontOfSize:11];

    NSStackView* content = [NSStackView stackViewWithViews:@[
        header, receiver_stack, _startButton, divider, status_stack, permission_note,
    ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 14;
    [content setCustomSpacing:24 afterView:header];
    [content setCustomSpacing:18 afterView:receiver_stack];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [_window.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor constant:32],
        [content.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor constant:-32],
        [content.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor constant:30],
        [header.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [receiver_stack.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_receiverPopup.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_discoveryLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_startButton.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [divider.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [status_stack.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [permission_note.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [_hostField.widthAnchor constraintEqualToConstant:270],
        [_portField.widthAnchor constraintEqualToConstant:96],
    ]];

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
}

- (void)updateReceiverMenu {
    NSNetService* previously_selected = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        previously_selected = _receiverPopup.selectedItem.representedObject;
    }

    [_receiverPopup removeAllItems];
    NSMenuItem* item_to_select = nil;
    for (NSNetService* service in _services) {
        if (!service.hostName.length || service.port <= 0) continue;
        [_receiverPopup addItemWithTitle:service.name.length ? service.name : @"SoundMux iPhone"];
        NSMenuItem* item = _receiverPopup.lastItem;
        item.image = [NSImage imageWithSystemSymbolName:@"iphone"
                              accessibilityDescription:@"iPhone"];
        item.representedObject = service;
        if (service == previously_selected) item_to_select = item;
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
        NSMenuItem* first = _receiverPopup.itemArray.firstObject;
        if ([first.representedObject isKindOfClass:NSNetService.class]) {
            [_receiverPopup selectItem:first];
        } else {
            [_receiverPopup selectItem:manual_item];
        }
    }
    [self updateReceiverSelectionUI];
}

- (void)receiverSelectionChanged:(id)sender {
    (void)sender;
    _preferManual = _receiverPopup.selectedItem.tag == 9'001;
    [self updateReceiverSelectionUI];
}

- (void)updateReceiverSelectionUI {
    NSNetService* service = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        service = _receiverPopup.selectedItem.representedObject;
    }
    _manualStack.hidden = service != nil;
    if (service) {
        _discoveryLabel.stringValue = [NSString stringWithFormat:
            @"Found automatically on your local network • %@:%ld",
            service.hostName, (long)service.port];
    } else if (_services.count == 0) {
        _discoveryLabel.stringValue =
            @"No nearby iPhone yet—open SoundMux there, or use the saved address below.";
    } else {
        _discoveryLabel.stringValue = @"Using a saved IP or Tailscale address.";
    }
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
    _discoveryLabel.stringValue = @"Found an iPhone—resolving its address…";
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
    [sender stop];
    [self updateReceiverMenu];
}

- (void)netService:(NSNetService*)sender
      didNotResolve:(NSDictionary<NSString*, NSNumber*>*)errorDict {
    (void)sender;
    (void)errorDict;
    _discoveryLabel.stringValue = @"An iPhone was found but its address could not be resolved.";
}

- (void)toggleSending:(id)sender {
    (void)sender;
    if (_sender || _starting) {
        _starting = NO;
        if (_sender) {
            _sender->stop();
            _sender.reset();
        }
        _hostField.enabled = YES;
        _portField.enabled = YES;
        _receiverPopup.enabled = YES;
        _startButton.title = @"Connect";
        _startButton.bezelColor = NSColor.systemBlueColor;
        _statusLabel.stringValue = @"Disconnected";
        _metricsLabel.stringValue = @"No active stream";
        return;
    }

    NSString* host = nil;
    NSInteger port_number = 0;
    NSString* receiver_name = nil;
    NSNetService* service = nil;
    if ([_receiverPopup.selectedItem.representedObject isKindOfClass:NSNetService.class]) {
        service = _receiverPopup.selectedItem.representedObject;
    }
    if (service) {
        host = service.hostName;
        port_number = service.port;
        receiver_name = service.name;
    } else {
        host = [_hostField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        port_number = _portField.integerValue;
        receiver_name = host;
    }
    if (!host.length || port_number < 1 || port_number > 65'534) {
        _statusLabel.stringValue = @"Enter a valid iPhone address and UDP port.";
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:host forKey:@"receiverHost"];
    [NSUserDefaults.standardUserDefaults
        setObject:[NSString stringWithFormat:@"%ld", (long)port_number]
                                             forKey:@"receiverPort"];
    request_media_control_access(true);
    _starting = YES;
    _hostField.enabled = NO;
    _portField.enabled = NO;
    _receiverPopup.enabled = NO;
    _startButton.title = @"Cancel";
    _startButton.bezelColor = NSColor.systemOrangeColor;
    _statusLabel.stringValue = @"Connecting…";
    _metricsLabel.stringValue = @"Starting pure Core Audio capture";

    const std::string destination(host.UTF8String);
    _activeReceiverName = receiver_name.length ? [receiver_name copy] : @"iPhone";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CoreAudioTapSender* new_sender = nullptr;
        std::string error_message;
        try {
            new_sender = new CoreAudioTapSender(
                destination, static_cast<std::uint16_t>(port_number));
            new_sender->start();
        } catch (const std::exception& error) {
            error_message = error.what();
            delete new_sender;
            new_sender = nullptr;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->_starting) {
                if (new_sender) {
                    new_sender->stop();
                    delete new_sender;
                }
                return;
            }
            self->_starting = NO;
            if (!new_sender) {
                self->_hostField.enabled = YES;
                self->_portField.enabled = YES;
                self->_receiverPopup.enabled = YES;
                self->_startButton.title = @"Connect";
                self->_startButton.bezelColor = NSColor.systemBlueColor;
                self->_statusLabel.stringValue = [NSString
                    stringWithFormat:@"Could not start: %s", error_message.c_str()];
                self->_metricsLabel.stringValue = @"Check that the iPhone receiver is available.";
                return;
            }
            self->_sender.reset(new_sender);
            self->_startButton.title = @"Disconnect";
            self->_startButton.bezelColor = NSColor.systemRedColor;
            self->_statusLabel.stringValue = [NSString stringWithFormat:
                @"Connected to %@", self->_activeReceiverName];
        });
    });
}

- (void)refreshMetrics:(NSTimer*)timer {
    (void)timer;
    if (!_sender) return;
    const auto stats = _sender->snapshot();
    _metricsLabel.stringValue = [NSString stringWithFormat:
        @"Audio packets  %llu    •    FEC packets  %llu\nRemote commands  %llu%@    •    Drops / failures  %llu / %llu",
        stats.audio_packets,
        stats.parity_packets,
        stats.control_commands,
        stats.media_control_access ? @"" : @" (Accessibility needed)",
        stats.capture_drops,
        stats.send_failures + stats.control_failures];
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

            CoreAudioTapSender sender(host, static_cast<std::uint16_t>(port_number));
            sender.start();
            std::signal(SIGINT, handle_signal);
            std::signal(SIGTERM, handle_signal);
            const auto& format = sender.format();
            std::cout << "Streaming pure Core Audio system output to " << host << ':'
                      << port_number << "\nFormat: " << format.mSampleRate << " Hz, "
                      << format.mChannelsPerFrame
                      << " channels, float32 (Ctrl-C to stop)\n";

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
