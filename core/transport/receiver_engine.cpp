#include "multipoint/transport/receiver_engine.h"

#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/fec.h"
#include "multipoint/util/sequence.h"

#include <algorithm>
#include <array>
#include <deque>
#include <memory>
#include <utility>

namespace multipoint::transport {
namespace {

struct FecGroup {
    std::optional<protocol::AudioPacketHeader> base_header;
    std::array<std::optional<std::vector<std::byte>>, protocol::kFecDataShards> data;
    std::array<std::optional<std::vector<std::byte>>, protocol::kFecParityShards> parity;
};

constexpr std::size_t kMaximumRetiredStreams = 8;
constexpr std::uint64_t kArrivalGapEventNS = 10'000'000;

}  // namespace

struct ReceiverEngine::Impl {
    explicit Impl(const ReceiverConfig& config)
        : jitter(config.reorder_packets, config.capacity_packets) {}

    jitter::JitterBuffer jitter;
    std::optional<std::uint64_t> current_stream;
    std::deque<std::uint64_t> retired_streams;
    std::optional<std::uint32_t> last_audio_sequence;
    std::optional<std::uint64_t> last_arrival_ns;
    std::map<std::uint32_t, FecGroup> fec_groups;
    ReceiverStats stats;
};

ReceiverEngine::ReceiverEngine(ReceiverConfig config)
    : config_(config), impl_(std::make_unique<Impl>(config)) {}

ReceiverEngine::~ReceiverEngine() = default;

void ReceiverEngine::retire_current_stream() {
    if (!impl_->current_stream) return;
    impl_->retired_streams.push_back(*impl_->current_stream);
    while (impl_->retired_streams.size() > kMaximumRetiredStreams) {
        impl_->retired_streams.pop_front();
    }
}

bool ReceiverEngine::is_retired_stream(std::uint64_t stream_id) const {
    return std::find(
        impl_->retired_streams.begin(),
        impl_->retired_streams.end(),
        stream_id) != impl_->retired_streams.end();
}

void ReceiverEngine::request_hard_resync() {
    impl_->jitter.rebuffer();
    impl_->fec_groups.clear();
    ++impl_->stats.hard_resyncs;
    ++impl_->stats.resync_generation;
}

IngestResult ReceiverEngine::ingest(
    std::span<const std::byte> datagram,
    std::uint64_t arrival_time_ns) {
    std::lock_guard lock(mutex_);
    ++impl_->stats.raw_datagrams;
    impl_->stats.raw_bytes += datagram.size();

    auto decoded = protocol::deserialize(datagram);
    if (!decoded.packet) {
        ++impl_->stats.malformed_packets;
        return {.error = std::move(decoded.error)};
    }

    auto packet = std::move(*decoded.packet);
    const bool is_audio =
        packet.header.packet_type == protocol::kAudioPacketType;
    const auto shard = packet.header.fec_shard_index;
    if ((is_audio && shard >= protocol::kFecDataShards) ||
        (!is_audio && shard < protocol::kFecDataShards)) {
        ++impl_->stats.malformed_packets;
        return {.error = "invalid FEC shard index"};
    }
    if (is_retired_stream(packet.header.stream_id)) {
        ++impl_->stats.stale_stream_packets;
        return {};
    }

    bool hard_resync = false;
    if (!impl_->current_stream ||
        *impl_->current_stream != packet.header.stream_id) {
        const bool replacing_stream = impl_->current_stream.has_value();
        if (replacing_stream) retire_current_stream();
        impl_->jitter.reset();
        impl_->fec_groups.clear();
        impl_->current_stream = packet.header.stream_id;
        impl_->last_audio_sequence.reset();
        if (replacing_stream) {
            ++impl_->stats.hard_resyncs;
            ++impl_->stats.resync_generation;
            hard_resync = true;
        }
    }

    if (impl_->last_arrival_ns) {
        const auto gap = arrival_time_ns - *impl_->last_arrival_ns;
        impl_->stats.max_arrival_gap_ns = std::max(
            impl_->stats.max_arrival_gap_ns, gap);
        if (gap >= kArrivalGapEventNS) ++impl_->stats.arrival_gap_events;
    }
    impl_->last_arrival_ns = arrival_time_ns;
    ++impl_->stats.valid_datagrams;
    const bool first_valid = impl_->stats.valid_datagrams == 1;

    if (is_audio) {
        const auto sequence = packet.header.sequence;
        if (impl_->last_audio_sequence &&
            util::sequence_after(sequence, *impl_->last_audio_sequence)) {
            const auto forward_gap = sequence - *impl_->last_audio_sequence;
            if (forward_gap > config_.hard_resync_gap_packets) {
                request_hard_resync();
                hard_resync = true;
            }
            impl_->last_audio_sequence = sequence;
        } else if (!impl_->last_audio_sequence) {
            impl_->last_audio_sequence = sequence;
        }
    }

    const auto group_base = is_audio
        ? packet.header.sequence - shard
        : packet.header.sequence;
    auto& group = impl_->fec_groups[group_base];
    if (!group.base_header) {
        auto header = packet.header;
        header.packet_type = protocol::kAudioPacketType;
        header.sequence = group_base;
        if (is_audio) {
            header.sample_index -= static_cast<std::uint64_t>(shard) *
                protocol::kFramesPerPacket;
        }
        header.fec_shard_index = 0;
        group.base_header = header;
    }

    bool accepted = false;
    if (is_audio) {
        if (!group.data[shard]) group.data[shard] = packet.encoded_payload;
        accepted = impl_->jitter.insert(std::move(packet));
    } else {
        const auto parity_index = static_cast<std::size_t>(
            shard - protocol::kFecDataShards);
        if (!group.parity[parity_index]) {
            group.parity[parity_index] = std::move(packet.encoded_payload);
        }
        accepted = true;
    }

    const auto recovered = protocol::recover_fec_data(group.data, group.parity);
    if (recovered) {
        for (auto recovered_shard : *recovered) {
            const auto missing_index = recovered_shard.data_index;
            auto header = *group.base_header;
            header.sequence = group_base + static_cast<std::uint32_t>(missing_index);
            header.sample_index += static_cast<std::uint64_t>(missing_index) *
                protocol::kFramesPerPacket;
            header.fec_shard_index = static_cast<std::uint8_t>(missing_index);
            auto recovered_packet = protocol::decode_audio_payload(
                header, recovered_shard.payload);
            if (!recovered_packet) continue;
            group.data[missing_index] = std::move(recovered_shard.payload);
            if (impl_->jitter.insert(std::move(*recovered_packet))) {
                ++impl_->stats.fec_recovered;
            }
        }
    }

    while (impl_->fec_groups.size() > config_.maximum_fec_groups) {
        impl_->fec_groups.erase(impl_->fec_groups.begin());
    }
    return {
        .accepted = accepted,
        .first_valid_datagram = first_valid,
        .hard_resync = hard_resync,
    };
}

jitter::PopResult ReceiverEngine::pop(bool declare_missing) {
    std::lock_guard lock(mutex_);
    return impl_->jitter.pop(declare_missing);
}

std::size_t ReceiverEngine::discard_oldest_until(std::size_t target_depth) {
    std::lock_guard lock(mutex_);
    return impl_->jitter.discard_oldest_until(target_depth);
}

bool ReceiverEngine::advance_to_oldest_available() {
    std::lock_guard lock(mutex_);
    return impl_->jitter.advance_to_oldest_available();
}

void ReceiverEngine::rebuffer() {
    std::lock_guard lock(mutex_);
    impl_->jitter.rebuffer();
}

void ReceiverEngine::reset() {
    std::lock_guard lock(mutex_);
    impl_ = std::make_unique<Impl>(config_);
}

ReceiverStats ReceiverEngine::snapshot() const {
    std::lock_guard lock(mutex_);
    auto snapshot = impl_->stats;
    snapshot.depth = impl_->jitter.depth();
    snapshot.started = impl_->jitter.started();
    snapshot.jitter = impl_->jitter.stats();
    return snapshot;
}

}  // namespace multipoint::transport
