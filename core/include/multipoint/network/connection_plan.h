#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace multipoint::network {

// The audio engine consumes a connected datagram path and deliberately does
// not care whether it came from Bonjour, a rendezvous lookup, or a relay.
enum class ConnectionRoute {
    local_discovery,
    remembered_address,
    rendezvous_direct,
    relay,
};

struct ConnectionCandidate {
    ConnectionRoute route = ConnectionRoute::local_discovery;
    std::string host;
    std::uint16_t port = 0;
};

struct DeviceConnectionState {
    std::string device_id;
    std::string display_name;
    std::string platform;
    std::string pinned_public_key;
    std::vector<ConnectionCandidate> local;
    std::vector<ConnectionCandidate> remembered;
    std::vector<ConnectionCandidate> rendezvous;
    std::vector<ConnectionCandidate> relays;
};

// Produces a deterministic fastest/cheapest-first route order and removes
// duplicate host/port pairs. Relay remains the final fallback.
[[nodiscard]] std::vector<ConnectionCandidate> make_connection_plan(
    const DeviceConnectionState& device);

}  // namespace multipoint::network
