#include "multipoint/network/udp_socket.h"

#ifndef _WIN32
#error "udp_socket_windows.cpp is only for Windows"
#endif

#include <winsock2.h>
#include <ws2tcpip.h>

#include <cstring>
#include <stdexcept>

namespace multipoint::network {
namespace {

constexpr std::uintptr_t kInvalidSocket = static_cast<std::uintptr_t>(INVALID_SOCKET);

struct WinsockRuntime {
    WinsockRuntime() {
        WSADATA data{};
        if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
            throw std::runtime_error("initialize Winsock");
        }
    }
    ~WinsockRuntime() { WSACleanup(); }
};

WinsockRuntime& winsock() {
    static WinsockRuntime runtime;
    return runtime;
}

std::runtime_error socket_error(const std::string& operation) {
    return std::runtime_error(
        operation + ": Winsock error " + std::to_string(WSAGetLastError()));
}

SOCKET native(std::uintptr_t value) {
    return static_cast<SOCKET>(value);
}

void configure_sender_socket(SOCKET socket_value) {
    const int send_buffer_bytes = 1 << 20;
    setsockopt(
        socket_value, SOL_SOCKET, SO_SNDBUF,
        reinterpret_cast<const char*>(&send_buffer_bytes),
        sizeof(send_buffer_bytes));
    u_long nonblocking = 1;
    ioctlsocket(socket_value, FIONBIO, &nonblocking);
}

}  // namespace

UdpEndpoint resolve_udp_endpoint(const std::string& host, std::uint16_t port) {
    (void)winsock();
    addrinfo hints{};
    hints.ai_family = AF_INET6;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    hints.ai_flags = AI_V4MAPPED | AI_ALL;
    addrinfo* result = nullptr;
    const auto service = std::to_string(port);
    const int lookup = getaddrinfo(host.c_str(), service.c_str(), &hints, &result);
    if (lookup != 0) {
        throw std::runtime_error("resolve UDP endpoint: " + std::to_string(lookup));
    }
    UdpEndpoint endpoint;
    for (auto* address = result; address != nullptr; address = address->ai_next) {
        if (address->ai_addrlen > endpoint.storage.size()) continue;
        std::memcpy(endpoint.storage.data(), address->ai_addr, address->ai_addrlen);
        endpoint.size = static_cast<std::size_t>(address->ai_addrlen);
        break;
    }
    freeaddrinfo(result);
    if (endpoint.size == 0) throw std::runtime_error("resolve UDP endpoint");
    return endpoint;
}

UdpSender::UdpSender(const std::string& host, std::uint16_t port) {
    (void)winsock();
    sockaddr_in numeric_ipv4{};
    if (InetPtonA(AF_INET, host.c_str(), &numeric_ipv4.sin_addr) == 1) {
        numeric_ipv4.sin_family = AF_INET;
        numeric_ipv4.sin_port = htons(port);
        const SOCKET socket_value = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (socket_value == INVALID_SOCKET) throw socket_error("create UDP socket");
        fd_ = static_cast<std::uintptr_t>(socket_value);
        configure_sender_socket(socket_value);
        if (connect(
                socket_value,
                reinterpret_cast<const sockaddr*>(&numeric_ipv4),
                sizeof(numeric_ipv4)) == 0) {
            return;
        }
        const auto error = socket_error("connect UDP socket");
        closesocket(socket_value);
        fd_ = kInvalidSocket;
        throw error;
    }

    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;
    addrinfo* result = nullptr;
    const auto service = std::to_string(port);
    const int lookup = getaddrinfo(host.c_str(), service.c_str(), &hints, &result);
    if (lookup != 0) {
        throw std::runtime_error(
            "resolve UDP destination: " + std::to_string(lookup));
    }
    for (auto* address = result; address != nullptr; address = address->ai_next) {
        const SOCKET socket_value = socket(
            address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socket_value == INVALID_SOCKET) continue;
        configure_sender_socket(socket_value);
        if (connect(
                socket_value, address->ai_addr,
                static_cast<int>(address->ai_addrlen)) == 0) {
            fd_ = static_cast<std::uintptr_t>(socket_value);
            break;
        }
        closesocket(socket_value);
    }
    freeaddrinfo(result);
    if (fd_ == kInvalidSocket) throw socket_error("connect UDP socket");
}

UdpSender::~UdpSender() {
    if (fd_ != kInvalidSocket) closesocket(native(fd_));
}

void UdpSender::send(std::span<const std::byte> datagram) {
    const int sent = ::send(
        native(fd_), reinterpret_cast<const char*>(datagram.data()),
        static_cast<int>(datagram.size()), 0);
    if (sent < 0 || static_cast<std::size_t>(sent) != datagram.size()) {
        throw socket_error("send UDP datagram");
    }
}

UdpReceiver::UdpReceiver(std::uint16_t port) {
    (void)winsock();
    const SOCKET socket_value = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_value == INVALID_SOCKET) throw socket_error("create UDP socket");
    fd_ = static_cast<std::uintptr_t>(socket_value);

    DWORD disabled = 0;
    setsockopt(
        socket_value, IPPROTO_IPV6, IPV6_V6ONLY,
        reinterpret_cast<const char*>(&disabled), sizeof(disabled));
    const int receive_buffer_bytes = 1 << 20;
    setsockopt(
        socket_value, SOL_SOCKET, SO_RCVBUF,
        reinterpret_cast<const char*>(&receive_buffer_bytes),
        sizeof(receive_buffer_bytes));
    const DWORD timeout_ms = 100;
    setsockopt(
        socket_value, SOL_SOCKET, SO_RCVTIMEO,
        reinterpret_cast<const char*>(&timeout_ms), sizeof(timeout_ms));

    sockaddr_in6 address{};
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = htons(port);
    if (bind(
            socket_value, reinterpret_cast<const sockaddr*>(&address),
            sizeof(address)) != 0) {
        const auto error = socket_error("bind UDP socket");
        closesocket(socket_value);
        fd_ = kInvalidSocket;
        throw error;
    }
}

UdpReceiver::~UdpReceiver() {
    if (fd_ != kInvalidSocket) closesocket(native(fd_));
}

std::size_t UdpReceiver::receive(std::span<std::byte> destination) {
    UdpEndpoint source;
    return receive_from(destination, source);
}

std::size_t UdpReceiver::receive_from(
    std::span<std::byte> destination,
    UdpEndpoint& source) {
    static_assert(sizeof(sockaddr_storage) <= sizeof(source.storage));
    sockaddr_storage address{};
    int address_size = sizeof(address);
    const int received = recvfrom(
        native(fd_), reinterpret_cast<char*>(destination.data()),
        static_cast<int>(destination.size()), 0,
        reinterpret_cast<sockaddr*>(&address), &address_size);
    if (received >= 0) {
        std::memcpy(source.storage.data(), &address, static_cast<std::size_t>(address_size));
        source.size = static_cast<std::size_t>(address_size);
        return static_cast<std::size_t>(received);
    }
    const int error = WSAGetLastError();
    if (error == WSAETIMEDOUT || error == WSAEWOULDBLOCK || error == WSAEINTR) {
        return 0;
    }
    throw socket_error("receive UDP datagram");
}

void UdpReceiver::send_to(
    std::span<const std::byte> datagram,
    const UdpEndpoint& destination,
    std::uint16_t port_override) {
    if (destination.size == 0 || destination.size > destination.storage.size()) {
        throw std::invalid_argument("invalid UDP endpoint");
    }
    sockaddr_storage address{};
    std::memcpy(&address, destination.storage.data(), destination.size);
    if (port_override != 0) {
        if (address.ss_family == AF_INET) {
            reinterpret_cast<sockaddr_in*>(&address)->sin_port = htons(port_override);
        } else if (address.ss_family == AF_INET6) {
            reinterpret_cast<sockaddr_in6*>(&address)->sin6_port = htons(port_override);
        } else {
            throw std::invalid_argument("unsupported UDP endpoint family");
        }
    }
    const int sent = sendto(
        native(fd_), reinterpret_cast<const char*>(datagram.data()),
        static_cast<int>(datagram.size()), 0,
        reinterpret_cast<const sockaddr*>(&address),
        static_cast<int>(destination.size));
    if (sent < 0 || static_cast<std::size_t>(sent) != datagram.size()) {
        throw socket_error("send UDP datagram");
    }
}

std::uint16_t UdpReceiver::local_port() const {
    sockaddr_storage address{};
    int size = sizeof(address);
    if (getsockname(
            native(fd_), reinterpret_cast<sockaddr*>(&address), &size) != 0) {
        throw socket_error("read UDP socket address");
    }
    if (address.ss_family == AF_INET) {
        return ntohs(reinterpret_cast<const sockaddr_in*>(&address)->sin_port);
    }
    if (address.ss_family == AF_INET6) {
        return ntohs(reinterpret_cast<const sockaddr_in6*>(&address)->sin6_port);
    }
    throw std::runtime_error("unsupported UDP socket family");
}

}  // namespace multipoint::network
