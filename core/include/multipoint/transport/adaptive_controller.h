#pragma once

#include <cstdint>

namespace multipoint::transport {

enum class AdaptiveProfile { responsive, balanced, resilient };

struct NetworkInterval {
    std::uint64_t packets_received = 0;
    std::uint64_t packets_lost = 0;
    std::uint64_t audio_underruns = 0;
    double maximum_arrival_gap_ms = 0;
    double round_trip_ms = 0;
};

struct AdaptiveDecision {
    AdaptiveProfile profile = AdaptiveProfile::balanced;
    std::uint32_t target_latency_ms = 100;
    std::uint8_t parity_shards = 3;
    bool changed = false;
};

class AdaptiveController {
public:
    explicit AdaptiveController(
        AdaptiveProfile initial = AdaptiveProfile::balanced);
    [[nodiscard]] AdaptiveDecision observe(const NetworkInterval& interval);
    [[nodiscard]] AdaptiveDecision decision() const;

private:
    AdaptiveProfile profile_;
    std::uint32_t bad_intervals_ = 0;
    std::uint32_t good_intervals_ = 0;
    std::uint32_t cooldown_intervals_ = 0;
};

}  // namespace multipoint::transport
