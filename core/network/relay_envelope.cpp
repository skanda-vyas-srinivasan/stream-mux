#include "multipoint/network/relay_envelope.h"

#include "multipoint/protocol/session_crypto.h"

#include <algorithm>
#include <array>
#include <stdexcept>
#include <utility>

namespace multipoint::network {
namespace {

constexpr std::array<std::byte, 4> kMagic = {
    std::byte{'S'}, std::byte{'M'}, std::byte{'R'}, std::byte{'1'},
};

bool valid_type(RelayMessageType type) {
    const auto value = static_cast<std::uint8_t>(type);
    return value >= static_cast<std::uint8_t>(RelayMessageType::register_receiver) &&
        value <= static_cast<std::uint8_t>(RelayMessageType::keepalive_sender);
}

bool control_type(RelayMessageType type) {
    return type == RelayMessageType::register_receiver ||
        type == RelayMessageType::open_sender ||
        type == RelayMessageType::keepalive_receiver ||
        type == RelayMessageType::keepalive_sender;
}

}  // namespace

std::vector<std::byte> serialize_relay(const RelayEnvelope& envelope) {
    if (!valid_type(envelope.type)) {
        throw std::invalid_argument("invalid relay message type");
    }
    if (envelope.payload.size() > kRelayMaximumPayloadBytes) {
        throw std::invalid_argument("relay payload is too large");
    }
    if (control_type(envelope.type) && !envelope.payload.empty()) {
        throw std::invalid_argument("relay control message has a payload");
    }
    std::vector<std::byte> output(kRelayHeaderBytes + envelope.payload.size());
    std::copy(kMagic.begin(), kMagic.end(), output.begin());
    output[4] = static_cast<std::byte>(static_cast<std::uint8_t>(envelope.type));
    std::copy(envelope.route.begin(), envelope.route.end(), output.begin() + 8);
    std::copy(envelope.payload.begin(), envelope.payload.end(),
              output.begin() + static_cast<std::ptrdiff_t>(kRelayHeaderBytes));
    return output;
}

RelayDecodeResult deserialize_relay(std::span<const std::byte> datagram) {
    if (datagram.size() < kMagic.size() ||
        !std::equal(kMagic.begin(), kMagic.end(), datagram.begin())) {
        return {};
    }
    if (datagram.size() < kRelayHeaderBytes) {
        return {.recognized = true, .error = "relay header is truncated"};
    }
    const auto type = static_cast<RelayMessageType>(
        std::to_integer<std::uint8_t>(datagram[4]));
    if (!valid_type(type)) {
        return {.recognized = true, .error = "unknown relay message type"};
    }
    if (datagram[5] != std::byte{} || datagram[6] != std::byte{} ||
        datagram[7] != std::byte{}) {
        return {.recognized = true, .error = "relay reserved bytes are nonzero"};
    }
    const auto payload_size = datagram.size() - kRelayHeaderBytes;
    if (payload_size > kRelayMaximumPayloadBytes ||
        (control_type(type) && payload_size != 0)) {
        return {.recognized = true, .error = "invalid relay payload size"};
    }
    RelayEnvelope envelope{.type = type};
    std::copy_n(datagram.begin() + 8, envelope.route.size(),
                envelope.route.begin());
    envelope.payload.assign(
        datagram.begin() + static_cast<std::ptrdiff_t>(kRelayHeaderBytes),
        datagram.end());
    return {
        .recognized = true,
        .valid = true,
        .envelope = std::move(envelope),
    };
}

std::string relay_route_text(const RelayRoute& route) {
    return protocol::hex_encode(route);
}

bool parse_relay_route(std::string_view text, RelayRoute& route) {
    return protocol::hex_decode(text, route);
}

}  // namespace multipoint::network
