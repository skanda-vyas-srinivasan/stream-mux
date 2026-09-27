#include "multipoint/protocol/session.h"

#include <algorithm>
#include <cctype>
#include <optional>
#include <stdexcept>

namespace multipoint::protocol {
namespace {

constexpr std::size_t kMaximumFields = 24;
constexpr std::size_t kMaximumKeyBytes = 32;
constexpr std::size_t kMaximumValueBytes = 512;

bool is_unreserved(unsigned char value) {
    return std::isalnum(value) || value == '-' || value == '.' ||
        value == '_' || value == '~';
}

char hex_digit(unsigned value) {
    return static_cast<char>(value < 10 ? '0' + value : 'A' + value - 10);
}

std::string percent_encode(std::string_view value) {
    std::string output;
    output.reserve(value.size());
    for (const char character : value) {
        const auto byte = static_cast<unsigned char>(character);
        if (is_unreserved(byte)) {
            output.push_back(static_cast<char>(byte));
        } else {
            output.push_back('%');
            output.push_back(hex_digit(byte >> 4));
            output.push_back(hex_digit(byte & 0x0fU));
        }
    }
    return output;
}

int hex_value(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

bool percent_decode(std::string_view value, std::string& output) {
    output.clear();
    output.reserve(value.size());
    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] != '%') {
            output.push_back(value[index]);
            continue;
        }
        if (index + 2 >= value.size()) return false;
        const int high = hex_value(value[index + 1]);
        const int low = hex_value(value[index + 2]);
        if (high < 0 || low < 0) return false;
        output.push_back(static_cast<char>((high << 4) | low));
        index += 2;
    }
    return true;
}

bool valid_key(std::string_view key) {
    return !key.empty() && key.size() <= kMaximumKeyBytes &&
        std::all_of(key.begin(), key.end(), [](unsigned char value) {
            return std::isalnum(value) || value == '_';
        });
}

std::optional<SessionMessageType> parse_type(std::string_view value) {
    if (value == "HELLO") return SessionMessageType::hello;
    if (value == "PAIR_REQUIRED") return SessionMessageType::pair_required;
    if (value == "REJECTED") return SessionMessageType::rejected;
    if (value == "WELCOME") return SessionMessageType::welcome;
    if (value == "PING") return SessionMessageType::ping;
    if (value == "PONG") return SessionMessageType::pong;
    if (value == "PROFILE") return SessionMessageType::profile;
    return std::nullopt;
}

SessionDecodeResult failure(bool recognized, std::string error) {
    return {
        .recognized = recognized,
        .valid = false,
        .message = {},
        .error = std::move(error),
    };
}

}  // namespace

std::string_view session_message_name(SessionMessageType type) {
    switch (type) {
        case SessionMessageType::hello: return "HELLO";
        case SessionMessageType::pair_required: return "PAIR_REQUIRED";
        case SessionMessageType::rejected: return "REJECTED";
        case SessionMessageType::welcome: return "WELCOME";
        case SessionMessageType::ping: return "PING";
        case SessionMessageType::pong: return "PONG";
        case SessionMessageType::profile: return "PROFILE";
    }
    throw std::invalid_argument("unknown session message type");
}

std::vector<std::byte> serialize_session(const SessionMessage& message) {
    if (message.fields.size() > kMaximumFields) {
        throw std::invalid_argument("too many session fields");
    }
    std::string text(kSessionPrefix);
    text.push_back('|');
    text.append(session_message_name(message.type));
    for (const auto& [key, value] : message.fields) {
        if (!valid_key(key)) throw std::invalid_argument("invalid session field key");
        if (value.size() > kMaximumValueBytes) {
            throw std::invalid_argument("session field value is too large");
        }
        text.push_back('|');
        text.append(key);
        text.push_back('=');
        text.append(percent_encode(value));
    }
    if (text.size() > kMaximumSessionDatagramBytes) {
        throw std::invalid_argument("session datagram is too large");
    }
    return {
        reinterpret_cast<const std::byte*>(text.data()),
        reinterpret_cast<const std::byte*>(text.data() + text.size()),
    };
}

SessionDecodeResult deserialize_session(std::span<const std::byte> datagram) {
    if (datagram.size() < kSessionPrefix.size()) return {};
    const std::string_view text(
        reinterpret_cast<const char*>(datagram.data()), datagram.size());
    if (!text.starts_with(kSessionPrefix)) return {};
    if (text.size() > kMaximumSessionDatagramBytes) {
        return failure(true, "session datagram is too large");
    }
    if (text.size() == kSessionPrefix.size() ||
        text[kSessionPrefix.size()] != '|') {
        return failure(true, "invalid session prefix separator");
    }

    const auto type_begin = kSessionPrefix.size() + 1;
    const auto type_end = text.find('|', type_begin);
    const auto type_text = text.substr(
        type_begin,
        type_end == std::string_view::npos
            ? text.size() - type_begin
            : type_end - type_begin);
    const auto type = parse_type(type_text);
    if (!type) return failure(true, "unknown session message type");

    SessionMessage message{.type = *type};
    std::size_t cursor = type_end;
    while (cursor != std::string_view::npos) {
        const auto field_begin = cursor + 1;
        const auto field_end = text.find('|', field_begin);
        const auto field = text.substr(
            field_begin,
            field_end == std::string_view::npos
                ? text.size() - field_begin
                : field_end - field_begin);
        const auto equals = field.find('=');
        if (equals == std::string_view::npos) {
            return failure(true, "session field has no value");
        }
        const auto key = field.substr(0, equals);
        if (!valid_key(key)) return failure(true, "invalid session field key");
        std::string value;
        if (!percent_decode(field.substr(equals + 1), value)) {
            return failure(true, "invalid session field encoding");
        }
        if (value.size() > kMaximumValueBytes) {
            return failure(true, "session field value is too large");
        }
        if (!message.fields.emplace(std::string(key), std::move(value)).second) {
            return failure(true, "duplicate session field");
        }
        if (message.fields.size() > kMaximumFields) {
            return failure(true, "too many session fields");
        }
        cursor = field_end;
    }
    return {
        .recognized = true,
        .valid = true,
        .message = std::move(message),
        .error = {},
    };
}

}  // namespace multipoint::protocol
