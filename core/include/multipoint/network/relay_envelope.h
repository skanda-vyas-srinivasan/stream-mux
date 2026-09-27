#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace multipoint::network {

inline constexpr std::size_t kRelayRouteBytes = 16;
inline constexpr std::size_t kRelayHeaderBytes = 24;
inline constexpr std::size_t kRelayMaximumPayloadBytes = 1'400;
using RelayRoute = std::array<std::byte, kRelayRouteBytes>;

enum class RelayMessageType : std::uint8_t {
    register_receiver = 1,
    open_sender = 2,
    data_to_receiver = 3,
    data_to_sender = 4,
    keepalive_receiver = 5,
    keepalive_sender = 6,
};

struct RelayEnvelope {
    RelayMessageType type = RelayMessageType::register_receiver;
    RelayRoute route{};
    std::vector<std::byte> payload;
};

struct RelayDecodeResult {
    bool recognized = false;
    bool valid = false;
    RelayEnvelope envelope;
    std::string error;
};

[[nodiscard]] std::vector<std::byte> serialize_relay(
    const RelayEnvelope& envelope);
[[nodiscard]] RelayDecodeResult deserialize_relay(
    std::span<const std::byte> datagram);
[[nodiscard]] std::string relay_route_text(const RelayRoute& route);
[[nodiscard]] bool parse_relay_route(std::string_view text, RelayRoute& route);

}  // namespace multipoint::network
