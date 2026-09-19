#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace multipoint::transport {

using Datagram = std::vector<std::byte>;

struct SenderStats {
    std::uint64_t audio_packets = 0;
    std::uint64_t parity_packets = 0;
    std::uint64_t stream_epochs = 0;
};

// Portable audio framing and protection. Platform capture adapters submit
// normalized 48 kHz stereo float samples; platform network adapters transmit
// the returned datagrams.
class SenderEngine {
public:
    explicit SenderEngine(std::uint64_t stream_id);

    [[nodiscard]] std::vector<Datagram> push_audio(
        std::span<const float> interleaved_samples,
        std::uint64_t sender_timestamp_ns);

    // Abandons partial audio/FEC state and starts a new transport epoch. A
    // receiver treats the next packet as a hard playout discontinuity.
    void reset_stream(std::uint64_t stream_id);

    [[nodiscard]] std::uint64_t stream_id() const { return stream_id_; }
    [[nodiscard]] const SenderStats& stats() const { return stats_; }

private:
    [[nodiscard]] std::vector<Datagram> make_parity() const;

    std::vector<float> pending_samples_;
    std::size_t pending_offset_ = 0;
    std::vector<Datagram> fec_group_;
    std::vector<Datagram> delayed_parity_;
    std::uint64_t stream_id_ = 0;
    std::uint32_t sequence_ = 0;
    std::uint64_t sample_index_ = 0;
    SenderStats stats_;
};

}  // namespace multipoint::transport
