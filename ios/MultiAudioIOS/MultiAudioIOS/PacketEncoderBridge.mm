#include "PacketEncoderBridge.h"

#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/transport/receiver_engine.h"
#include "multipoint/transport/sender_engine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <new>
#include <optional>

namespace {

class IOSReceiverEngine {
public:
    IOSReceiverEngine(std::size_t reorder_packets, std::size_t prebuffer_frames)
        : transport_({
              .reorder_packets = std::max<std::size_t>(1, reorder_packets),
              .capacity_packets = 512,
              .hard_resync_gap_packets = 20,
              .maximum_fec_groups = 128,
          }),
          ring_(48'000, multipoint::protocol::kChannelCount),
          prebuffer_frames_(std::max<std::size_t>(
              multipoint::protocol::kFramesPerPacket, prebuffer_frames)) {}

    multipoint::transport::IngestResult ingest(
        std::span<const std::byte> datagram,
        std::uint64_t arrival_time_ns) {
        auto result = transport_.ingest(datagram, arrival_time_ns);
        if (result.hard_resync) {
            ring_.discard();
            playout_active_.store(false, std::memory_order_release);
            std::lock_guard lock(pump_mutex_);
            missing_since_.reset();
        }
        return result;
    }

    void pump() {
        std::lock_guard lock(pump_mutex_);
        constexpr auto kMissingGrace = std::chrono::milliseconds(30);
        constexpr std::size_t kTargetFrames = 7'200;

        while (ring_.available_to_read() < kTargetFrames &&
               ring_.available_to_write() >= multipoint::protocol::kFramesPerPacket) {
            auto result = transport_.pop(false);
            if (result.status == multipoint::jitter::PopStatus::not_ready) {
                const auto snapshot = transport_.snapshot();
                if (!snapshot.started) break;
                if (snapshot.depth == 0) {
                    // A source pause (for example, muting the Mac) must not
                    // advance the expected sequence forever. Let already
                    // buffered audio drain, then rebuffer at whatever sequence
                    // arrives next.
                    missing_since_.reset();
                    if (ring_.available_to_read() == 0) {
                        transport_.rebuffer();
                        playout_active_.store(false, std::memory_order_release);
                    }
                    break;
                }
                const auto now = std::chrono::steady_clock::now();
                if (!missing_since_) missing_since_ = now;
                if (now - *missing_since_ < kMissingGrace) break;
                result = transport_.pop(true);
            }

            if (result.status == multipoint::jitter::PopStatus::not_ready) break;
            if (result.packet) {
                missing_since_.reset();
                ring_.write(
                    result.packet->interleaved_samples.data(),
                    multipoint::protocol::kFramesPerPacket);
            } else {
                ring_.write(silence_.data(), multipoint::protocol::kFramesPerPacket);
                concealed_packets_.fetch_add(1, std::memory_order_relaxed);
            }
        }

        if (!playout_active_.load(std::memory_order_acquire) &&
            ring_.available_to_read() >= prebuffer_frames_) {
            playout_active_.store(true, std::memory_order_release);
        }
    }

    void rebuffer() {
        std::lock_guard lock(pump_mutex_);
        ring_.discard();
        transport_.rebuffer();
        missing_since_.reset();
        playout_active_.store(false, std::memory_order_release);
    }

    std::size_t read(float* samples, std::size_t frame_count) {
        if (!playout_active_.load(std::memory_order_acquire)) {
            std::fill(
                samples,
                samples + frame_count * multipoint::protocol::kChannelCount,
                0.0F);
            return 0;
        }
        return ring_.read(samples, frame_count);
    }

    MPReceiverStats snapshot() const {
        const auto transport = transport_.snapshot();
        return {
            .raw_datagrams = transport.raw_datagrams,
            .valid_datagrams = transport.valid_datagrams,
            .malformed_packets = transport.malformed_packets,
            .stale_stream_packets = transport.stale_stream_packets,
            .packets_received = transport.jitter.packets_received,
            .packets_lost = transport.jitter.packets_lost,
            .fec_recovered = transport.fec_recovered,
            .hard_resyncs = transport.hard_resyncs,
            .concealed_packets = concealed_packets_.load(std::memory_order_relaxed),
            .audio_underruns = ring_.underruns(),
            .jitter_depth = transport.depth,
            .buffered_frames = ring_.available_to_read(),
            .playout_active = playout_active_.load(std::memory_order_acquire),
        };
    }

private:
    multipoint::transport::ReceiverEngine transport_;
    multipoint::audio::SpscAudioRing ring_;
    const std::size_t prebuffer_frames_;
    std::array<float, multipoint::protocol::kSamplesPerPacket> silence_{};
    std::atomic<bool> playout_active_{false};
    std::atomic<std::uint64_t> concealed_packets_{0};
    std::mutex pump_mutex_;
    std::optional<std::chrono::steady_clock::time_point> missing_since_;
};

}  // namespace

MPSenderEngineRef MPSenderEngineCreate(uint64_t stream_id) {
    try {
        return new multipoint::transport::SenderEngine(stream_id);
    } catch (...) {
        return nullptr;
    }
}

bool MPSenderEngineReset(MPSenderEngineRef sender, uint64_t stream_id) {
    if (!sender) return false;
    try {
        static_cast<multipoint::transport::SenderEngine*>(sender)->reset_stream(
            stream_id);
        return true;
    } catch (...) {
        return false;
    }
}

bool MPSenderEnginePush(
    MPSenderEngineRef sender,
    const float* interleaved_samples,
    size_t sample_count,
    uint64_t sender_timestamp_ns,
    uint8_t* output,
    size_t output_capacity,
    size_t* datagram_count) {
    if (!sender || !interleaved_samples || !output || !datagram_count) return false;
    try {
        auto datagrams = static_cast<multipoint::transport::SenderEngine*>(sender)
            ->push_audio(
                std::span<const float>(interleaved_samples, sample_count),
                sender_timestamp_ns);
        const auto required = datagrams.size() * MPAudioDatagramSize;
        if (required > output_capacity) return false;
        auto* cursor = output;
        for (const auto& datagram : datagrams) {
            if (datagram.size() != MPAudioDatagramSize) return false;
            std::memcpy(cursor, datagram.data(), datagram.size());
            cursor += datagram.size();
        }
        *datagram_count = datagrams.size();
        return true;
    } catch (...) {
        return false;
    }
}

void MPSenderEngineDestroy(MPSenderEngineRef sender) {
    delete static_cast<multipoint::transport::SenderEngine*>(sender);
}

MPReceiverEngineRef MPReceiverEngineCreate(
    size_t reorder_packets,
    size_t prebuffer_frames) {
    try {
        return new IOSReceiverEngine(reorder_packets, prebuffer_frames);
    } catch (...) {
        return nullptr;
    }
}

bool MPReceiverEngineIngest(
    MPReceiverEngineRef receiver,
    const uint8_t* bytes,
    size_t size,
    uint64_t arrival_time_ns,
    bool* hard_resync) {
    if (!receiver || !bytes || size == 0) return false;
    try {
        auto result = static_cast<IOSReceiverEngine*>(receiver)->ingest(
            std::span<const std::byte>(
                reinterpret_cast<const std::byte*>(bytes), size),
            arrival_time_ns);
        if (hard_resync) *hard_resync = result.hard_resync;
        return result.accepted;
    } catch (...) {
        return false;
    }
}

void MPReceiverEnginePump(MPReceiverEngineRef receiver) {
    if (!receiver) return;
    try {
        static_cast<IOSReceiverEngine*>(receiver)->pump();
    } catch (...) {
    }
}

void MPReceiverEngineRebuffer(MPReceiverEngineRef receiver) {
    if (!receiver) return;
    static_cast<IOSReceiverEngine*>(receiver)->rebuffer();
}

size_t MPReceiverEngineRead(
    MPReceiverEngineRef receiver,
    float* interleaved_samples,
    size_t frame_count) {
    if (!receiver || !interleaved_samples || frame_count == 0) return 0;
    return static_cast<IOSReceiverEngine*>(receiver)->read(
        interleaved_samples, frame_count);
}

MPReceiverStats MPReceiverEngineSnapshot(MPReceiverEngineRef receiver) {
    if (!receiver) return {};
    try {
        return static_cast<IOSReceiverEngine*>(receiver)->snapshot();
    } catch (...) {
        return {};
    }
}

void MPReceiverEngineDestroy(MPReceiverEngineRef receiver) {
    delete static_cast<IOSReceiverEngine*>(receiver);
}

MPUdpSenderRef MPUdpSenderCreate(const char* host, uint16_t port) {
    if (!host) return nullptr;
    try {
        return new multipoint::network::UdpSender(host, port);
    } catch (...) {
        return nullptr;
    }
}

bool MPUdpSenderSend(MPUdpSenderRef sender, const uint8_t* bytes, size_t size) {
    if (!sender || !bytes || size == 0) return false;
    try {
        auto* udp = static_cast<multipoint::network::UdpSender*>(sender);
        udp->send(std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(bytes), size));
        return true;
    } catch (...) {
        return false;
    }
}

void MPUdpSenderDestroy(MPUdpSenderRef sender) {
    delete static_cast<multipoint::network::UdpSender*>(sender);
}
