#include "multipoint/jitter/jitter_buffer.h"

#include "multipoint/util/sequence.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace multipoint::jitter {

JitterBuffer::JitterBuffer(std::size_t target_packets, std::size_t capacity_packets)
    : target_packets_(target_packets), capacity_packets_(capacity_packets) {
    if (target_packets == 0 || capacity_packets < target_packets) {
        throw std::invalid_argument("invalid jitter buffer size");
    }
}

bool JitterBuffer::insert(protocol::AudioPacket packet) {
    const auto sequence = packet.header.sequence;
    if (started_ && util::sequence_before(sequence, next_sequence_)) {
        ++stats_.late_packets;
        return false;
    }
    if (packets_.contains(sequence)) {
        ++stats_.duplicate_packets;
        return false;
    }
    if (packets_.size() >= capacity_packets_) {
        ++stats_.overflow_drops;
        return false;
    }

    if (!initialized_) {
        initialized_ = true;
        first_sequence_ = sequence;
        highest_sequence_ = sequence;
    } else {
        if (!started_ && util::sequence_before(sequence, first_sequence_)) {
            first_sequence_ = sequence;
        }
        if (util::sequence_before(sequence, highest_sequence_)) {
            ++stats_.packets_reordered;
        } else if (util::sequence_after(sequence, highest_sequence_)) {
            highest_sequence_ = sequence;
        }
    }

    packets_.emplace(sequence, std::move(packet));
    ++stats_.packets_received;
    return true;
}

PopResult JitterBuffer::pop() {
    if (!started_) {
        if (!initialized_ || packets_.size() < target_packets_) {
            return {.status = PopStatus::not_ready, .packet = std::nullopt};
        }
        next_sequence_ = first_sequence_;
        started_ = true;
    }

    const auto sequence = next_sequence_++;
    const auto found = packets_.find(sequence);
    if (found == packets_.end()) {
        ++stats_.packets_lost;
        return {.status = PopStatus::missing, .packet = std::nullopt};
    }

    auto packet = std::move(found->second);
    packets_.erase(found);
    return {.status = PopStatus::packet, .packet = std::move(packet)};
}

std::size_t JitterBuffer::discard_oldest_until(std::size_t target_depth) {
    if (!started_) return 0;

    std::size_t discarded = 0;
    while (packets_.size() > target_depth) {
        auto oldest = packets_.end();
        auto oldest_distance = std::numeric_limits<std::uint32_t>::max();
        for (auto candidate = packets_.begin(); candidate != packets_.end(); ++candidate) {
            const auto distance = candidate->first - next_sequence_;
            if (oldest == packets_.end() || distance < oldest_distance) {
                oldest = candidate;
                oldest_distance = distance;
            }
        }
        if (oldest == packets_.end()) break;
        next_sequence_ = oldest->first + 1;
        packets_.erase(oldest);
        ++discarded;
    }
    stats_.latency_drops += discarded;
    return discarded;
}

bool JitterBuffer::advance_to_oldest_available() {
    if (!started_ || packets_.empty()) return false;

    auto oldest = packets_.begin();
    auto oldest_distance = oldest->first - next_sequence_;
    for (auto candidate = std::next(packets_.begin()); candidate != packets_.end(); ++candidate) {
        const auto distance = candidate->first - next_sequence_;
        if (distance < oldest_distance) {
            oldest = candidate;
            oldest_distance = distance;
        }
    }
    next_sequence_ = oldest->first;
    return true;
}

void JitterBuffer::reset() {
    packets_.clear();
    stats_ = {};
    rebuffer();
}

void JitterBuffer::rebuffer() {
    packets_.clear();
    initialized_ = false;
    started_ = false;
    first_sequence_ = 0;
    highest_sequence_ = 0;
    next_sequence_ = 0;
}

}  // namespace multipoint::jitter
