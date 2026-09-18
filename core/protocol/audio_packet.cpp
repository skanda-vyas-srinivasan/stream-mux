#include "multipoint/protocol/audio_packet.h"

#include <bit>
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace multipoint::protocol {
namespace {

class Writer {
public:
    explicit Writer(std::vector<std::byte>& bytes) : bytes_(bytes) {}

    void u8(std::uint8_t value) { bytes_.push_back(static_cast<std::byte>(value)); }

    void u16(std::uint16_t value) {
        u8(static_cast<std::uint8_t>(value >> 8));
        u8(static_cast<std::uint8_t>(value));
    }

    void u32(std::uint32_t value) {
        u16(static_cast<std::uint16_t>(value >> 16));
        u16(static_cast<std::uint16_t>(value));
    }

    void u64(std::uint64_t value) {
        u32(static_cast<std::uint32_t>(value >> 32));
        u32(static_cast<std::uint32_t>(value));
    }

private:
    std::vector<std::byte>& bytes_;
};

class Reader {
public:
    explicit Reader(std::span<const std::byte> bytes) : bytes_(bytes) {}

    bool u8(std::uint8_t& value) {
        if (offset_ + 1 > bytes_.size()) return false;
        value = std::to_integer<std::uint8_t>(bytes_[offset_++]);
        return true;
    }

    bool u16(std::uint16_t& value) {
        std::uint8_t high = 0;
        std::uint8_t low = 0;
        if (!u8(high) || !u8(low)) return false;
        value = static_cast<std::uint16_t>(
            (static_cast<std::uint16_t>(high) << 8) | low);
        return true;
    }

    bool u32(std::uint32_t& value) {
        std::uint16_t high = 0;
        std::uint16_t low = 0;
        if (!u16(high) || !u16(low)) return false;
        value = (static_cast<std::uint32_t>(high) << 16) | low;
        return true;
    }

    bool u64(std::uint64_t& value) {
        std::uint32_t high = 0;
        std::uint32_t low = 0;
        if (!u32(high) || !u32(low)) return false;
        value = (static_cast<std::uint64_t>(high) << 32) | low;
        return true;
    }

private:
    std::span<const std::byte> bytes_;
    std::size_t offset_ = 0;
};

DecodeResult failure(std::string message) {
    return {.packet = std::nullopt, .error = std::move(message)};
}

}  // namespace

std::vector<std::byte> serialize(const AudioPacket& packet) {
    const auto expected_samples =
        static_cast<std::size_t>(packet.header.frames_per_packet) *
        packet.header.channel_count;
    if (expected_samples > std::numeric_limits<std::uint32_t>::max() / sizeof(std::int16_t)) {
        throw std::invalid_argument("payload is too large");
    }

    const bool is_audio = packet.header.packet_type == kAudioPacketType;
    const bool is_parity = packet.header.packet_type == kFecParityPacketType;
    if (!is_audio && !is_parity) {
        throw std::invalid_argument("unsupported packet type");
    }
    if (is_audio && packet.interleaved_samples.size() != expected_samples) {
        throw std::invalid_argument("sample count does not match packet header");
    }
    if (is_parity && packet.encoded_payload.size() != kPayloadBytes) {
        throw std::invalid_argument("parity payload has wrong size");
    }

    const auto payload_size =
        static_cast<std::uint32_t>(expected_samples * sizeof(std::int16_t));
    std::vector<std::byte> bytes;
    bytes.reserve(kHeaderSize + payload_size);
    Writer writer(bytes);
    writer.u32(kMagic);
    writer.u8(kProtocolVersion);
    writer.u8(packet.header.packet_type);
    writer.u16(kHeaderSize);
    writer.u64(packet.header.stream_id);
    writer.u32(packet.header.sequence);
    writer.u64(packet.header.sender_timestamp_ns);
    writer.u64(packet.header.sample_index);
    writer.u32(packet.header.sample_rate);
    writer.u16(packet.header.channel_count);
    writer.u16(packet.header.frames_per_packet);
    writer.u32(payload_size);
    writer.u8(packet.header.fec_data_shards);
    writer.u8(packet.header.fec_parity_shards);
    writer.u8(packet.header.fec_shard_index);
    writer.u8(0);

    if (is_audio) {
        for (const float sample : packet.interleaved_samples) {
            const auto clamped = std::clamp(sample, -1.0F, 1.0F);
            const auto quantized = static_cast<std::int16_t>(std::lrint(
                clamped * (clamped < 0.0F ? 32'768.0F : 32'767.0F)));
            writer.u16(std::bit_cast<std::uint16_t>(quantized));
        }
    } else {
        bytes.insert(
            bytes.end(), packet.encoded_payload.begin(), packet.encoded_payload.end());
    }
    return bytes;
}

std::optional<AudioPacket> decode_audio_payload(
    AudioPacketHeader header,
    std::span<const std::byte> encoded_payload) {
    if (header.packet_type != kAudioPacketType ||
        header.sample_rate != kSampleRate ||
        header.channel_count != kChannelCount ||
        header.frames_per_packet != kFramesPerPacket ||
        encoded_payload.size() != kPayloadBytes) {
        return std::nullopt;
    }

    AudioPacket packet;
    packet.header = header;
    packet.encoded_payload.assign(encoded_payload.begin(), encoded_payload.end());
    packet.interleaved_samples.resize(kSamplesPerPacket);
    Reader payload_reader(encoded_payload);
    for (auto& sample : packet.interleaved_samples) {
        std::uint16_t bits = 0;
        if (!payload_reader.u16(bits)) return std::nullopt;
        const auto quantized = std::bit_cast<std::int16_t>(bits);
        sample = static_cast<float>(quantized) / 32'768.0F;
    }
    return packet;
}

DecodeResult deserialize(std::span<const std::byte> datagram) {
    if (datagram.size() < kHeaderSize) return failure("datagram shorter than header");

    Reader reader(datagram);
    std::uint32_t magic = 0;
    std::uint8_t version = 0;
    std::uint8_t packet_type = 0;
    std::uint16_t header_size = 0;
    AudioPacket packet;
    std::uint32_t payload_size = 0;

    if (!reader.u32(magic) || !reader.u8(version) || !reader.u8(packet_type) ||
        !reader.u16(header_size) || !reader.u64(packet.header.stream_id) ||
        !reader.u32(packet.header.sequence) ||
        !reader.u64(packet.header.sender_timestamp_ns) ||
        !reader.u64(packet.header.sample_index) ||
        !reader.u32(packet.header.sample_rate) ||
        !reader.u16(packet.header.channel_count) ||
        !reader.u16(packet.header.frames_per_packet) ||
        !reader.u32(payload_size) ||
        !reader.u8(packet.header.fec_data_shards) ||
        !reader.u8(packet.header.fec_parity_shards) ||
        !reader.u8(packet.header.fec_shard_index)) {
        return failure("truncated header");
    }
    std::uint8_t reserved = 0;
    if (!reader.u8(reserved)) return failure("truncated header");
    packet.header.packet_type = packet_type;

    if (magic != kMagic) return failure("invalid magic");
    if (version != kProtocolVersion) return failure("unsupported protocol version");
    if (packet_type != kAudioPacketType && packet_type != kFecParityPacketType) {
        return failure("unsupported packet type");
    }
    if (header_size != kHeaderSize) return failure("unsupported header size");
    if (packet.header.sample_rate != kSampleRate ||
        packet.header.channel_count != kChannelCount ||
        packet.header.frames_per_packet != kFramesPerPacket) {
        return failure("unsupported audio format");
    }
    if (payload_size != kPayloadBytes) return failure("invalid payload size");
    if (packet.header.fec_data_shards != kFecDataShards ||
        packet.header.fec_parity_shards != kFecParityShards ||
        packet.header.fec_shard_index >= kFecDataShards + kFecParityShards) {
        return failure("unsupported FEC layout");
    }
    if (datagram.size() != static_cast<std::size_t>(header_size) + payload_size) {
        return failure("datagram size does not match payload size");
    }

    const auto payload = datagram.subspan(header_size, payload_size);
    packet.encoded_payload.assign(payload.begin(), payload.end());
    if (packet_type == kAudioPacketType) {
        auto decoded = decode_audio_payload(packet.header, payload);
        if (!decoded) return failure("truncated PCM payload");
        return {.packet = std::move(decoded), .error = {}};
    }
    return {.packet = std::move(packet), .error = {}};
}

}  // namespace multipoint::protocol
