#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace multipoint::protocol {

inline constexpr std::uint32_t kMagic = 0x4d504155;  // "MPAU"
inline constexpr std::uint8_t kProtocolVersion = 1;
inline constexpr std::uint8_t kAudioPacketType = 1;
inline constexpr std::uint16_t kHeaderSize = 48;
inline constexpr std::uint32_t kSampleRate = 48'000;
inline constexpr std::uint16_t kChannelCount = 2;
inline constexpr std::uint16_t kFramesPerPacket = 120;
inline constexpr std::size_t kSamplesPerPacket =
    static_cast<std::size_t>(kFramesPerPacket) * kChannelCount;
inline constexpr std::size_t kPayloadBytes = kSamplesPerPacket * sizeof(float);
inline constexpr std::size_t kDatagramBytes = kHeaderSize + kPayloadBytes;

struct AudioPacketHeader {
    std::uint64_t stream_id = 0;
    std::uint32_t sequence = 0;
    std::uint64_t sender_timestamp_ns = 0;
    std::uint64_t sample_index = 0;
    std::uint32_t sample_rate = kSampleRate;
    std::uint16_t channel_count = kChannelCount;
    std::uint16_t frames_per_packet = kFramesPerPacket;
};

struct AudioPacket {
    AudioPacketHeader header;
    std::vector<float> interleaved_samples;
};

struct DecodeResult {
    std::optional<AudioPacket> packet;
    std::string error;
};

[[nodiscard]] std::vector<std::byte> serialize(const AudioPacket& packet);
[[nodiscard]] DecodeResult deserialize(std::span<const std::byte> datagram);

}  // namespace multipoint::protocol
