#include "multipoint/network/connection_plan.h"

#include <set>
#include <tuple>

namespace multipoint::network {

std::vector<ConnectionCandidate> make_connection_plan(
    const DeviceConnectionState& device) {
    std::vector<ConnectionCandidate> output;
    std::set<std::tuple<std::string, std::uint16_t>> seen;
    const auto append = [&](const std::vector<ConnectionCandidate>& candidates) {
        for (const auto& candidate : candidates) {
            if (candidate.host.empty() || candidate.port == 0) continue;
            if (seen.emplace(candidate.host, candidate.port).second) {
                output.push_back(candidate);
            }
        }
    };
    append(device.local);
    append(device.remembered);
    append(device.rendezvous);
    append(device.relays);
    return output;
}

}  // namespace multipoint::network
