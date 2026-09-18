#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/jitter/jitter_buffer.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/fec.h"

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
#include <map>
#include <mutex>
#include <optional>
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

struct FecGroup {
    std::optional<multipoint::protocol::AudioPacketHeader> base_header;
    std::array<std::optional<std::vector<std::byte>>,
               multipoint::protocol::kFecDataShards> data;
    std::array<std::optional<std::vector<std::byte>>,
               multipoint::protocol::kFecParityShards> parity;
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
        multipoint::jitter::JitterBuffer jitter(reorder_packets, 512);
        AudioState audio;
        DefaultOutput output(audio);
        std::mutex jitter_mutex;
        std::atomic<bool> receive_running{true};
        std::atomic<std::uint64_t> malformed_packets{0};
        std::atomic<std::uint64_t> fec_recovered{0};
        std::atomic<std::uint64_t> max_arrival_gap_ns{0};
        std::atomic<std::uint64_t> arrival_gap_events{0};

        std::thread receive_thread([&] {
            std::array<std::byte, 2'048> datagram{};
            std::optional<std::chrono::steady_clock::time_point> last_arrival;
            std::optional<std::uint64_t> current_stream;
            std::map<std::uint32_t, FecGroup> fec_groups;
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
                    const auto arrival = std::chrono::steady_clock::now();
                    if (last_arrival) {
                        const auto gap = static_cast<std::uint64_t>(
                            std::chrono::duration_cast<std::chrono::nanoseconds>(
                                arrival - *last_arrival).count());
                        auto previous = max_arrival_gap_ns.load(std::memory_order_relaxed);
                        while (gap > previous &&
                               !max_arrival_gap_ns.compare_exchange_weak(
                                   previous, gap, std::memory_order_relaxed)) {}
                        if (gap >= 10'000'000) {
                            arrival_gap_events.fetch_add(1, std::memory_order_relaxed);
                        }
                    }
                    last_arrival = arrival;

                    auto packet = std::move(*decoded.packet);
                    if (!current_stream || *current_stream != packet.header.stream_id) {
                        std::lock_guard lock(jitter_mutex);
                        jitter.reset();
                        fec_groups.clear();
                        current_stream = packet.header.stream_id;
                    }

                    const bool is_audio = packet.header.packet_type ==
                        multipoint::protocol::kAudioPacketType;
                    const auto shard = packet.header.fec_shard_index;
                    if ((is_audio && shard >= multipoint::protocol::kFecDataShards) ||
                        (!is_audio &&
                         (shard < multipoint::protocol::kFecDataShards ||
                          shard >= multipoint::protocol::kFecDataShards +
                              multipoint::protocol::kFecParityShards))) {
                        malformed_packets.fetch_add(1, std::memory_order_relaxed);
                        continue;
                    }

                    const auto group_base = is_audio
                        ? packet.header.sequence - shard
                        : packet.header.sequence;
                    auto& group = fec_groups[group_base];
                    if (!group.base_header) {
                        auto header = packet.header;
                        header.packet_type = multipoint::protocol::kAudioPacketType;
                        header.sequence = group_base;
                        if (is_audio) {
                            header.sample_index -= static_cast<std::uint64_t>(shard) *
                                multipoint::protocol::kFramesPerPacket;
                        }
                        header.fec_shard_index = 0;
                        group.base_header = header;
                    }

                    if (is_audio) {
                        if (!group.data[shard]) {
                            group.data[shard] = packet.encoded_payload;
                        }
                        std::lock_guard lock(jitter_mutex);
                        jitter.insert(std::move(packet));
                    } else {
                        const auto parity_index = static_cast<std::size_t>(
                            shard - multipoint::protocol::kFecDataShards);
                        if (!group.parity[parity_index]) {
                            group.parity[parity_index] = std::move(packet.encoded_payload);
                        }
                    }

                    const auto recovered_shards =
                        multipoint::protocol::recover_fec_data(
                            group.data, group.parity);
                    if (recovered_shards) {
                      for (auto recovered_shard : *recovered_shards) {
                        const auto missing_index = recovered_shard.data_index;
                        auto recovered_header = *group.base_header;
                        recovered_header.sequence = group_base +
                            static_cast<std::uint32_t>(missing_index);
                        recovered_header.sample_index += missing_index *
                            multipoint::protocol::kFramesPerPacket;
                        recovered_header.fec_shard_index = static_cast<std::uint8_t>(
                            missing_index);
                        auto recovered = multipoint::protocol::decode_audio_payload(
                            recovered_header, recovered_shard.payload);
                        if (!recovered) continue;
                        group.data[missing_index] =
                            std::move(recovered_shard.payload);
                        {
                            std::lock_guard lock(jitter_mutex);
                            if (jitter.insert(std::move(*recovered))) {
                                fec_recovered.fetch_add(1, std::memory_order_relaxed);
                            }
                        }
                      }
                    }

                    while (fec_groups.size() > 128) {
                        fec_groups.erase(fec_groups.begin());
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
                // Keep a generous emergency ceiling. Normal clock drift must
                // be corrected gradually; bulk-dropping at twice the target
                // produced an audible discontinuity during short Wi-Fi stalls.
                if (jitter.depth() > target_packets * 4) {
                    jitter.discard_oldest_until(target_packets * 2);
                }
                result = jitter.pop(false);
                if (result.status == multipoint::jitter::PopStatus::not_ready &&
                    jitter.started()) {
                    if (gap_grace_exhausted) {
                        result = jitter.pop(true);
                    } else {
                        const auto now = std::chrono::steady_clock::now();
                        if (!missing_since) missing_since = now;
                        if (now - *missing_since >= reorder_grace) {
                            gap_grace_exhausted = true;
                            result = jitter.pop(true);
                        }
                    }
                } else if (result.packet) {
                    missing_since.reset();
                    gap_grace_exhausted = false;
                }
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
                    missing_since.reset();
                    gap_grace_exhausted = false;
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
                          << " concealed=" << concealed_packets
                          << " fec_recovered=" << fec_recovered.load()
                          << " max_arrival_gap_ms=" << std::fixed
                          << std::setprecision(1)
                          << static_cast<double>(max_arrival_gap_ns.load()) / 1'000'000.0
                          << " arrival_gap_events=" << arrival_gap_events.load()
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
