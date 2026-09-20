#include "multipoint/network/udp_socket.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

namespace multipoint::network {
namespace {

std::runtime_error socket_error(const std::string& operation) {
    return std::runtime_error(operation + ": " + std::strerror(errno));
}

void configure_sender_socket(int fd) {
    const int send_buffer_bytes = 1 << 20;
    setsockopt(
        fd, SOL_SOCKET, SO_SNDBUF,
        &send_buffer_bytes, sizeof(send_buffer_bytes));
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

}  // namespace

UdpSender::UdpSender(const std::string& host, std::uint16_t port) {
    // On Apple IPv6-only hotspot networks, getaddrinfo can synthesize a NAT64
    // address even when `host` is an IPv4 literal. That bypasses routes owned
    // by IPv4 VPNs such as Tailscale. Preserve numeric IPv4 destinations so
    // the kernel can select the intended VPN interface.
    sockaddr_in numeric_ipv4{};
    if (inet_pton(AF_INET, host.c_str(), &numeric_ipv4.sin_addr) == 1) {
        numeric_ipv4.sin_family = AF_INET;
        numeric_ipv4.sin_port = htons(port);
        fd_ = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd_ < 0) throw socket_error("create UDP socket");
        configure_sender_socket(fd_);
        if (connect(
                fd_, reinterpret_cast<const sockaddr*>(&numeric_ipv4),
                sizeof(numeric_ipv4)) == 0) {
            return;
        }
        const auto error = socket_error("connect UDP socket");
        close(fd_);
        fd_ = -1;
        throw error;
    }

    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    addrinfo* result = nullptr;
    const auto service = std::to_string(port);
    const int error = getaddrinfo(host.c_str(), service.c_str(), &hints, &result);
    if (error != 0) throw std::runtime_error(gai_strerror(error));

    for (auto* address = result; address != nullptr; address = address->ai_next) {
        fd_ = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd_ < 0) continue;
        configure_sender_socket(fd_);
        if (connect(fd_, address->ai_addr, address->ai_addrlen) == 0) break;
        close(fd_);
        fd_ = -1;
    }
    freeaddrinfo(result);
    if (fd_ < 0) throw socket_error("connect UDP socket");
}

UdpSender::~UdpSender() {
    if (fd_ >= 0) close(fd_);
}

void UdpSender::send(std::span<const std::byte> datagram) {
    const auto sent = ::send(fd_, datagram.data(), datagram.size(), 0);
    if (sent < 0 || static_cast<std::size_t>(sent) != datagram.size()) {
        throw socket_error("send UDP datagram");
    }
}

UdpReceiver::UdpReceiver(std::uint16_t port) {
    fd_ = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd_ < 0) throw socket_error("create UDP socket");

    int disabled = 0;
    setsockopt(fd_, IPPROTO_IPV6, IPV6_V6ONLY, &disabled, sizeof(disabled));
    const int receive_buffer_bytes = 1 << 20;
    setsockopt(
        fd_, SOL_SOCKET, SO_RCVBUF,
        &receive_buffer_bytes, sizeof(receive_buffer_bytes));
    timeval timeout{.tv_sec = 0, .tv_usec = 100'000};
    setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    sockaddr_in6 address{};
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = htons(port);
    if (bind(fd_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0) {
        const auto error = socket_error("bind UDP socket");
        close(fd_);
        fd_ = -1;
        throw error;
    }
}

UdpReceiver::~UdpReceiver() {
    if (fd_ >= 0) close(fd_);
}

std::size_t UdpReceiver::receive(std::span<std::byte> destination) {
    const auto received = recv(fd_, destination.data(), destination.size(), 0);
    if (received >= 0) return static_cast<std::size_t>(received);
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return 0;
    throw socket_error("receive UDP datagram");
}

}  // namespace multipoint::network
