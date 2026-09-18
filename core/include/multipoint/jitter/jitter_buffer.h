#pragma once

#include "multipoint/protocol/audio_packet.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <unordered_map>

namespace multipoint::jitter {

struct JitterStats {
    std::uint64_t packets_received = 0;
    std::uint64_t packets_lost = 0;
    std::uint64_t packets_reordered = 0;
    std::uint64_t duplicate_packets = 0;
    std::uint64_t late_packets = 0;
    std::uint64_t overflow_drops = 0;
    std::uint64_t latency_drops = 0;
};

enum class PopStatus { not_ready, packet, missing };

struct PopResult {
    PopStatus status = PopStatus::not_ready;
    std::optional<protocol::AudioPacket> packet;
};

class JitterBuffer {
public:
    explicit JitterBuffer(std::size_t target_packets, std::size_t capacity_packets);

    bool insert(protocol::AudioPacket packet);
    // When declare_missing is false, an absent next packet is held for a
    // short receiver-controlled reorder grace period instead of advancing.
    [[nodiscard]] PopResult pop(bool declare_missing = true);
    [[nodiscard]] std::size_t depth() const { return packets_.size(); }
    [[nodiscard]] bool started() const { return started_; }
    [[nodiscard]] const JitterStats& stats() const { return stats_; }
    std::size_t discard_oldest_until(std::size_t target_depth);
    bool advance_to_oldest_available();
    void rebuffer();
    void reset();

private:
    std::size_t target_packets_;
    std::size_t capacity_packets_;
    std::unordered_map<std::uint32_t, protocol::AudioPacket> packets_;
    JitterStats stats_;
    bool initialized_ = false;
    bool started_ = false;
    std::uint32_t first_sequence_ = 0;
    std::uint32_t highest_sequence_ = 0;
    std::uint32_t next_sequence_ = 0;
};

}  // namespace multipoint::jitter
