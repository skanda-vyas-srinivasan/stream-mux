#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>

namespace multipoint::network {

class UdpSender {
public:
    UdpSender(const std::string& host, std::uint16_t port);
    ~UdpSender();
    UdpSender(const UdpSender&) = delete;
    UdpSender& operator=(const UdpSender&) = delete;

    void send(std::span<const std::byte> datagram);

private:
    int fd_ = -1;
};

class UdpReceiver {
public:
    explicit UdpReceiver(std::uint16_t port);
    ~UdpReceiver();
    UdpReceiver(const UdpReceiver&) = delete;
    UdpReceiver& operator=(const UdpReceiver&) = delete;

    // Returns zero on timeout.
    std::size_t receive(std::span<std::byte> destination);

private:
    int fd_ = -1;
};

}  // namespace multipoint::network
