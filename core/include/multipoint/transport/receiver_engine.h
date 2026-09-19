#pragma once

#include "multipoint/jitter/jitter_buffer.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace multipoint::transport {

struct ReceiverConfig {
    std::size_t reorder_packets = 5;
    std::size_t capacity_packets = 512;
    std::uint32_t hard_resync_gap_packets = 20;
    std::size_t maximum_fec_groups = 128;
};

struct ReceiverStats {
    std::uint64_t raw_datagrams = 0;
    std::uint64_t raw_bytes = 0;
    std::uint64_t valid_datagrams = 0;
    std::uint64_t malformed_packets = 0;
    std::uint64_t stale_stream_packets = 0;
    std::uint64_t fec_recovered = 0;
    std::uint64_t hard_resyncs = 0;
    std::uint64_t max_arrival_gap_ns = 0;
    std::uint64_t arrival_gap_events = 0;
    std::uint64_t resync_generation = 0;
    std::size_t depth = 0;
    bool started = false;
    jitter::JitterStats jitter;
};

struct IngestResult {
    bool accepted = false;
    bool first_valid_datagram = false;
    bool hard_resync = false;
    std::string error;
};

// Thread-safe portable receive pipeline. A network adapter submits datagrams;
// a platform playout worker pops decoded audio packets.
class ReceiverEngine {
public:
    explicit ReceiverEngine(ReceiverConfig config);
    ~ReceiverEngine();

    [[nodiscard]] IngestResult ingest(
        std::span<const std::byte> datagram,
        std::uint64_t arrival_time_ns);

    [[nodiscard]] jitter::PopResult pop(bool declare_missing = true);
    [[nodiscard]] std::size_t discard_oldest_until(std::size_t target_depth);
    [[nodiscard]] bool advance_to_oldest_available();
    void rebuffer();
    void reset();

    [[nodiscard]] ReceiverStats snapshot() const;

private:
    struct Impl;

    void retire_current_stream();
    bool is_retired_stream(std::uint64_t stream_id) const;
    void request_hard_resync();

    ReceiverConfig config_;
    mutable std::mutex mutex_;
    std::unique_ptr<Impl> impl_;
};

}  // namespace multipoint::transport
