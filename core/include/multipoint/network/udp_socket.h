#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <array>

namespace multipoint::network {

struct UdpEndpoint {
    std::array<std::byte, 128> storage{};
    std::size_t size = 0;
};

[[nodiscard]] UdpEndpoint resolve_udp_endpoint(
    const std::string& host, std::uint16_t port);

class UdpSender {
public:
    UdpSender(const std::string& host, std::uint16_t port);
    ~UdpSender();
    UdpSender(const UdpSender&) = delete;
    UdpSender& operator=(const UdpSender&) = delete;

    void send(std::span<const std::byte> datagram);

private:
#ifdef _WIN32
    std::uintptr_t fd_ = static_cast<std::uintptr_t>(-1);
#else
    int fd_ = -1;
#endif
};

class UdpReceiver {
public:
    explicit UdpReceiver(std::uint16_t port);
    ~UdpReceiver();
    UdpReceiver(const UdpReceiver&) = delete;
    UdpReceiver& operator=(const UdpReceiver&) = delete;

    // Returns zero on timeout.
    std::size_t receive(std::span<std::byte> destination);
    std::size_t receive_from(
        std::span<std::byte> destination,
        UdpEndpoint& source);
    void send_to(
        std::span<const std::byte> datagram,
        const UdpEndpoint& destination,
        std::uint16_t port_override = 0);
    [[nodiscard]] std::uint16_t local_port() const;

private:
#ifdef _WIN32
    std::uintptr_t fd_ = static_cast<std::uintptr_t>(-1);
#else
    int fd_ = -1;
#endif
};

}  // namespace multipoint::network
