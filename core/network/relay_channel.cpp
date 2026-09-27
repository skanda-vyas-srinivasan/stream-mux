#include "multipoint/network/relay_channel.h"

#include <algorithm>
#include <array>
#include <stdexcept>
#include <utility>

namespace multipoint::network {

RelayChannel::RelayChannel(
    const std::string& relay_host,
    std::uint16_t relay_port,
    std::uint16_t local_port,
    RelayRoute route,
    RelayRole role)
    : socket_(local_port),
      relay_(resolve_udp_endpoint(relay_host, relay_port)),
      route_(route),
      role_(role) {
    const bool all_zero = std::all_of(
        route_.begin(), route_.end(), [](std::byte byte) {
            return byte == std::byte{};
        });
    if (all_zero) throw std::invalid_argument("relay route is empty");
}

void RelayChannel::announce() {
    send_envelope(
        role_ == RelayRole::sender
            ? RelayMessageType::open_sender
            : RelayMessageType::register_receiver);
}

void RelayChannel::keepalive() {
    send_envelope(
        role_ == RelayRole::sender
            ? RelayMessageType::keepalive_sender
            : RelayMessageType::keepalive_receiver);
}

void RelayChannel::send(std::span<const std::byte> payload) {
    send_envelope(
        role_ == RelayRole::sender
            ? RelayMessageType::data_to_receiver
            : RelayMessageType::data_to_sender,
        payload);
}

std::size_t RelayChannel::receive(std::span<std::byte> plaintext) {
    std::array<std::byte, kRelayHeaderBytes + kRelayMaximumPayloadBytes> datagram{};
    UdpEndpoint source;
    const auto size = socket_.receive_from(datagram, source);
    if (size == 0) return 0;
    const auto decoded = deserialize_relay(
        std::span<const std::byte>(datagram.data(), size));
    const auto expected = role_ == RelayRole::sender
        ? RelayMessageType::data_to_sender
        : RelayMessageType::data_to_receiver;
    if (!decoded.valid || decoded.envelope.route != route_ ||
        decoded.envelope.type != expected ||
        decoded.envelope.payload.size() > plaintext.size()) {
        return 0;
    }
    std::copy(
        decoded.envelope.payload.begin(), decoded.envelope.payload.end(),
        plaintext.begin());
    return decoded.envelope.payload.size();
}

void RelayChannel::send_envelope(
    RelayMessageType type,
    std::span<const std::byte> payload) {
    RelayEnvelope envelope{
        .type = type,
        .route = route_,
        .payload = {payload.begin(), payload.end()},
    };
    socket_.send_to(serialize_relay(envelope), relay_);
}

}  // namespace multipoint::network
