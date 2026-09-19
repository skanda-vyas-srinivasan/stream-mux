#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace multipoint::protocol {

inline constexpr std::uint32_t kMagic = 0x4d504155;  // "MPAU"
inline constexpr std::uint8_t kProtocolVersion = 4;
inline constexpr std::uint8_t kAudioPacketType = 1;
inline constexpr std::uint8_t kFecParityPacketType = 2;
inline constexpr std::uint8_t kFecDataShards = 5;
inline constexpr std::uint8_t kFecParityShards = 5;
inline constexpr std::uint16_t kHeaderSize = 52;
inline constexpr std::uint32_t kSampleRate = 48'000;
inline constexpr std::uint16_t kChannelCount = 2;
inline constexpr std::uint16_t kFramesPerPacket = 240;
inline constexpr std::size_t kSamplesPerPacket =
    static_cast<std::size_t>(kFramesPerPacket) * kChannelCount;
inline constexpr std::size_t kPayloadBytes = kSamplesPerPacket * sizeof(std::int16_t);
inline constexpr std::size_t kDatagramBytes = kHeaderSize + kPayloadBytes;

struct AudioPacketHeader {
    std::uint8_t packet_type = kAudioPacketType;
    std::uint64_t stream_id = 0;
    std::uint32_t sequence = 0;
    std::uint64_t sender_timestamp_ns = 0;
    std::uint64_t sample_index = 0;
    std::uint32_t sample_rate = kSampleRate;
    std::uint16_t channel_count = kChannelCount;
    std::uint16_t frames_per_packet = kFramesPerPacket;
    std::uint8_t fec_data_shards = kFecDataShards;
    std::uint8_t fec_parity_shards = kFecParityShards;
    std::uint8_t fec_shard_index = 0;
};

struct AudioPacket {
    AudioPacketHeader header;
    std::vector<float> interleaved_samples;
    // Exact PCM16 network bytes are retained so FEC can reconstruct a lost
    // datagram without a float -> PCM16 re-quantization round trip.
    std::vector<std::byte> encoded_payload;
};

struct DecodeResult {
    std::optional<AudioPacket> packet;
    std::string error;
};

[[nodiscard]] std::vector<std::byte> serialize(const AudioPacket& packet);
[[nodiscard]] DecodeResult deserialize(std::span<const std::byte> datagram);
[[nodiscard]] std::optional<AudioPacket> decode_audio_payload(
    AudioPacketHeader header,
    std::span<const std::byte> encoded_payload);

}  // namespace multipoint::protocol
