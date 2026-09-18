#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/jitter/jitter_buffer.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"

#include <AudioToolbox/AudioToolbox.h>

#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

namespace {

constexpr std::size_t kRingCapacityFrames = 48'000;
constexpr std::size_t kMaxRenderFrames = 8'192;
volatile std::sig_atomic_t g_running = 1;

void handle_signal(int) { g_running = 0; }

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
        const auto packet_ms = 1000.0 * multipoint::protocol::kFramesPerPacket /
            multipoint::protocol::kSampleRate;
        const auto target_packets = std::max<std::size_t>(
            1, static_cast<std::size_t>(target_latency_ms / packet_ms));

        multipoint::network::UdpReceiver receiver(port);
        multipoint::jitter::JitterBuffer jitter(target_packets, 512);
        AudioState audio;
        DefaultOutput output(audio);
        std::mutex jitter_mutex;
        std::atomic<bool> receive_running{true};
        std::atomic<std::uint64_t> malformed_packets{0};

        std::thread receive_thread([&] {
            std::array<std::byte, 2'048> datagram{};
            while (receive_running.load(std::memory_order_relaxed)) {
                try {
                    const auto size = receiver.receive(datagram);
                    if (size == 0) continue;
                    auto decoded = multipoint::protocol::deserialize(
                        std::span<const std::byte>(datagram.data(), size));
                    if (!decoded.packet) {
                        malformed_packets.fetch_add(1, std::memory_order_relaxed);
                        continue;
                    }
                    std::lock_guard lock(jitter_mutex);
                    jitter.insert(std::move(*decoded.packet));
                } catch (const std::exception& error) {
                    std::cerr << "network receive error: " << error.what() << '\n';
                }
            }
        });

        std::signal(SIGINT, handle_signal);
        std::signal(SIGTERM, handle_signal);
        std::cout << "multipoint receiver listening on UDP port " << port << '\n'
                  << "Format: 48 kHz stereo float32, 120 frames/packet\n"
                  << "Target jitter buffer: " << target_packets << " packets ("
                  << target_packets * packet_ms << " ms)\n"
                  << "Using the current macOS default output. Ctrl-C to stop.\n";

        std::vector<float> silence(multipoint::protocol::kSamplesPerPacket, 0.0F);
        const auto ring_target_frames = std::max<std::size_t>(
            multipoint::protocol::kFramesPerPacket,
            (target_packets / 2) * multipoint::protocol::kFramesPerPacket);
        auto next_stats = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        bool playout_started = false;
        std::size_t consecutive_missing = 0;

        while (g_running) {
            // CoreAudio is the playout clock. Keep a small amount of decoded
            // audio ahead of its render callback instead of independently
            // popping the jitter buffer from a sleep-based wall clock. The
            // latter can run in destructive catch-up bursts after a stall.
            if (playout_started &&
                audio.ring.available_to_read() >= ring_target_frames) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            } else {
            multipoint::jitter::PopResult result;
            {
                std::lock_guard lock(jitter_mutex);
                // A relay can deliver a large burst after an outage. Audio
                // older than twice the target delay is no longer useful;
                // shedding it prevents a permanent latency/overflow spiral.
                if (jitter.depth() > target_packets * 2) {
                    jitter.discard_oldest_until(target_packets);
                }
                result = jitter.pop();
            }
            if (result.status == multipoint::jitter::PopStatus::not_ready) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            if (result.packet) {
                consecutive_missing = 0;
                audio.ring.write(
                    result.packet->interleaved_samples.data(),
                    multipoint::protocol::kFramesPerPacket);
            } else {
                ++consecutive_missing;
                audio.ring.write(silence.data(), multipoint::protocol::kFramesPerPacket);
            }

            if (!playout_started &&
                audio.ring.available_to_read() >= ring_target_frames) {
                    playout_started = true;
                    audio.playout_active.store(true, std::memory_order_release);
                    next_stats = std::chrono::steady_clock::now() +
                        std::chrono::seconds(1);
            }

            if (consecutive_missing >= target_packets) {
                bool empty = false;
                bool advanced = false;
                {
                    std::lock_guard lock(jitter_mutex);
                    empty = jitter.depth() == 0;
                    if (empty) {
                        jitter.rebuffer();
                    } else {
                        advanced = jitter.advance_to_oldest_available();
                    }
                }
                if (empty) {
                    audio.playout_active.store(false, std::memory_order_release);
                    audio.ring.discard();
                    playout_started = false;
                    consecutive_missing = 0;
                    continue;
                }
                if (advanced) consecutive_missing = 0;
            }
            }
            const auto stats_now = std::chrono::steady_clock::now();
            if (stats_now >= next_stats) {
                std::lock_guard lock(jitter_mutex);
                const auto& stats = jitter.stats();
                std::cout << "received=" << stats.packets_received
                          << " lost=" << stats.packets_lost
                          << " reordered=" << stats.packets_reordered
                          << " late=" << stats.late_packets
                          << " duplicate=" << stats.duplicate_packets
                          << " overflow=" << stats.overflow_drops
                          << " latency_drop=" << stats.latency_drops
                          << " depth=" << jitter.depth()
                          << " ring_frames=" << audio.ring.available_to_read()
                          << " underruns=" << audio.ring.underruns()
                          << " malformed=" << malformed_packets.load() << '\n';
                next_stats = stats_now + std::chrono::seconds(1);
            }
        }

        receive_running.store(false, std::memory_order_relaxed);
        receive_thread.join();
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "receiver error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
