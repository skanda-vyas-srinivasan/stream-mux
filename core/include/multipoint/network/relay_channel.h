#pragma once

#include "multipoint/network/relay_envelope.h"
#include "multipoint/network/udp_socket.h"

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>

namespace multipoint::network {

enum class RelayRole { sender, receiver };

// A single bound UDP socket is used for registration, payloads, and replies so
// consumer NAT mappings remain valid in both directions.
class RelayChannel {
public:
    RelayChannel(
        const std::string& relay_host,
        std::uint16_t relay_port,
        std::uint16_t local_port,
        RelayRoute route,
        RelayRole role);

    void announce();
    void keepalive();
    void send(std::span<const std::byte> payload);
    // Returns zero on timeout or when an unrelated/invalid relay datagram was
    // ignored. Plaintext is the existing SoundMux session/encrypted datagram.
    std::size_t receive(std::span<std::byte> plaintext);

private:
    void send_envelope(RelayMessageType type, std::span<const std::byte> payload = {});

    UdpReceiver socket_;
    UdpEndpoint relay_;
    RelayRoute route_;
    RelayRole role_;
};

}  // namespace multipoint::network
