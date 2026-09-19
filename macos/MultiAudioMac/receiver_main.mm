#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/transport/receiver_engine.h"

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
        const auto reorder_packets = std::min<std::size_t>(
            8, std::max<std::size_t>(1, target_packets / 4));

        multipoint::network::UdpReceiver receiver(port);
        multipoint::transport::ReceiverEngine transport({
            .reorder_packets = reorder_packets,
            .capacity_packets = 512,
            .hard_resync_gap_packets = kHardResyncGapPackets,
            .maximum_fec_groups = 128,
        });
        AudioState audio;
        DefaultOutput output(audio);
        std::atomic<bool> receive_running{true};

        std::thread receive_thread([&] {
            std::array<std::byte, 2'048> datagram{};
            while (receive_running.load(std::memory_order_relaxed)) {
                try {
                    const auto size = receiver.receive(datagram);
                    if (size == 0) continue;
                    const auto arrival_ns = static_cast<std::uint64_t>(
                        std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now().time_since_epoch()).count());
                    const auto result = transport.ingest(
                        std::span<const std::byte>(datagram.data(), size), arrival_ns);
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
        const auto reorder_grace = std::chrono::milliseconds(30);
        std::uint64_t observed_resync_generation = 0;

        while (g_running) {
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
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "receiver error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
