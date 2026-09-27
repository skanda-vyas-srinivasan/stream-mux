#include "multipoint/transport/adaptive_controller.h"

namespace multipoint::transport {
namespace {

AdaptiveDecision describe(AdaptiveProfile profile, bool changed = false) {
    switch (profile) {
        case AdaptiveProfile::responsive:
            return {profile, 60, 2, changed};
        case AdaptiveProfile::balanced:
            return {profile, 100, 3, changed};
        case AdaptiveProfile::resilient:
            return {profile, 180, 5, changed};
    }
    return {};
}

AdaptiveProfile slower(AdaptiveProfile profile) {
    if (profile == AdaptiveProfile::responsive) return AdaptiveProfile::balanced;
    return AdaptiveProfile::resilient;
}

AdaptiveProfile faster(AdaptiveProfile profile) {
    if (profile == AdaptiveProfile::resilient) return AdaptiveProfile::balanced;
    return AdaptiveProfile::responsive;
}

}  // namespace

AdaptiveController::AdaptiveController(AdaptiveProfile initial)
    : profile_(initial) {}

AdaptiveDecision AdaptiveController::observe(const NetworkInterval& interval) {
    const auto attempted = interval.packets_received + interval.packets_lost;
    const double loss = attempted == 0 ? 0.0
        : static_cast<double>(interval.packets_lost) /
            static_cast<double>(attempted);
    const bool bad = interval.audio_underruns > 0 || loss >= 0.02 ||
        interval.maximum_arrival_gap_ms >= 80.0 || interval.round_trip_ms >= 250.0;
    const bool good = attempted >= 100 && interval.audio_underruns == 0 &&
        loss < 0.002 && interval.maximum_arrival_gap_ms < 20.0 &&
        interval.round_trip_ms < 100.0;

    if (cooldown_intervals_ > 0) --cooldown_intervals_;
    bad_intervals_ = bad ? bad_intervals_ + 1 : 0;
    good_intervals_ = good ? good_intervals_ + 1 : 0;

    if (cooldown_intervals_ == 0 && bad_intervals_ >= 2 &&
        profile_ != AdaptiveProfile::resilient) {
        profile_ = slower(profile_);
        bad_intervals_ = 0;
        good_intervals_ = 0;
        cooldown_intervals_ = 5;
        return describe(profile_, true);
    }
    if (cooldown_intervals_ == 0 && good_intervals_ >= 20 &&
        profile_ != AdaptiveProfile::responsive) {
        profile_ = faster(profile_);
        bad_intervals_ = 0;
        good_intervals_ = 0;
        cooldown_intervals_ = 10;
        return describe(profile_, true);
    }
    return describe(profile_);
}

AdaptiveDecision AdaptiveController::decision() const {
    return describe(profile_);
}

}  // namespace multipoint::transport
