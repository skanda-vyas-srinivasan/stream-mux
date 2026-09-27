#include "multipoint/network/relay_envelope.h"
#include "multipoint/network/udp_socket.h"

#include <array>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>

namespace {

std::atomic<bool> running{true};

void stop(int) {
    running.store(false, std::memory_order_release);
}

struct RouteState {
    std::optional<multipoint::network::UdpEndpoint> receiver;
    std::optional<multipoint::network::UdpEndpoint> sender;
    std::chrono::steady_clock::time_point receiver_seen{};
    std::chrono::steady_clock::time_point sender_seen{};
};

bool route_is_zero(const multipoint::network::RelayRoute& route) {
    for (const auto byte : route) {
        if (byte != std::byte{}) return false;
    }
    return true;
}

std::uint16_t parse_port(const char* text) {
    std::size_t used = 0;
    const auto value = std::stoul(text, &used);
    if (text[used] != '\0' || value < 1 || value > 65'535) {
        throw std::invalid_argument("invalid relay UDP port");
    }
    return static_cast<std::uint16_t>(value);
}

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc > 2) {
            std::cerr << "Usage: soundmux_relay [udp-port]\n";
            return EXIT_FAILURE;
        }
        const auto port = argc == 2
            ? parse_port(argv[1]) : std::uint16_t{48'200};
        multipoint::network::UdpReceiver socket(port);
        std::map<multipoint::network::RelayRoute, RouteState> routes;
        std::array<std::byte,
            multipoint::network::kRelayHeaderBytes +
            multipoint::network::kRelayMaximumPayloadBytes> datagram{};
        std::uint64_t forwarded = 0;
        std::uint64_t rejected = 0;
        std::signal(SIGINT, stop);
        std::signal(SIGTERM, stop);
        std::cout << "SoundMux relay listening on UDP " << port << '\n';

        while (running.load(std::memory_order_acquire)) {
            multipoint::network::UdpEndpoint source;
            const auto size = socket.receive_from(datagram, source);
            const auto now = std::chrono::steady_clock::now();
            if (size != 0) {
                const auto decoded = multipoint::network::deserialize_relay(
                    std::span<const std::byte>(datagram.data(), size));
                if (!decoded.valid || route_is_zero(decoded.envelope.route)) {
                    ++rejected;
                } else {
                    auto& route = routes[decoded.envelope.route];
                    using Type = multipoint::network::RelayMessageType;
                    switch (decoded.envelope.type) {
                        case Type::register_receiver:
                        case Type::keepalive_receiver:
                            route.receiver = source;
                            route.receiver_seen = now;
                            break;
                        case Type::open_sender:
                        case Type::keepalive_sender:
                            route.sender = source;
                            route.sender_seen = now;
                            break;
                        case Type::data_to_receiver:
                            route.sender = source;
                            route.sender_seen = now;
                            if (route.receiver) {
                                socket.send_to(
                                    std::span<const std::byte>(datagram.data(), size),
                                    *route.receiver);
                                ++forwarded;
                            }
                            break;
                        case Type::data_to_sender:
                            route.receiver = source;
                            route.receiver_seen = now;
                            if (route.sender) {
                                socket.send_to(
                                    std::span<const std::byte>(datagram.data(), size),
                                    *route.sender);
                                ++forwarded;
                            }
                            break;
                    }
                }
            }
            constexpr auto expiry = std::chrono::seconds(30);
            for (auto iterator = routes.begin(); iterator != routes.end();) {
                const bool receiver_expired = !iterator->second.receiver ||
                    now - iterator->second.receiver_seen > expiry;
                const bool sender_expired = !iterator->second.sender ||
                    now - iterator->second.sender_seen > expiry;
                if (receiver_expired && sender_expired) {
                    iterator = routes.erase(iterator);
                } else {
                    ++iterator;
                }
            }
        }
        std::cout << "Relay stopped: routes=" << routes.size()
                  << " forwarded=" << forwarded
                  << " rejected=" << rejected << '\n';
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "relay error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
