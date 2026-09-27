#pragma once

#include <cstddef>
#include <map>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace multipoint::protocol {

inline constexpr std::string_view kSessionPrefix = "SOUNDMUX/2";
inline constexpr std::size_t kMaximumSessionDatagramBytes = 1'200;

enum class SessionMessageType {
    hello,
    pair_required,
    rejected,
    welcome,
    ping,
    pong,
};

struct SessionMessage {
    SessionMessageType type = SessionMessageType::hello;
    std::map<std::string, std::string> fields;
};

struct SessionDecodeResult {
    bool recognized = false;
    bool valid = false;
    SessionMessage message;
    std::string error;
};

[[nodiscard]] std::vector<std::byte> serialize_session(
    const SessionMessage& message);
[[nodiscard]] SessionDecodeResult deserialize_session(
    std::span<const std::byte> datagram);
[[nodiscard]] std::string_view session_message_name(SessionMessageType type);

}  // namespace multipoint::protocol
