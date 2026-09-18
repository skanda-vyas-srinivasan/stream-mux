#include "multipoint/protocol/audio_packet.h"

#include <bit>
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
    if (packet.interleaved_samples.size() != expected_samples) {
        throw std::invalid_argument("sample count does not match packet header");
    }
    if (expected_samples > std::numeric_limits<std::uint32_t>::max() / sizeof(float)) {
        throw std::invalid_argument("payload is too large");
    }

    const auto payload_size =
        static_cast<std::uint32_t>(expected_samples * sizeof(float));
    std::vector<std::byte> bytes;
    bytes.reserve(kHeaderSize + payload_size);
    Writer writer(bytes);
    writer.u32(kMagic);
    writer.u8(kProtocolVersion);
    writer.u8(kAudioPacketType);
    writer.u16(kHeaderSize);
    writer.u64(packet.header.stream_id);
    writer.u32(packet.header.sequence);
    writer.u64(packet.header.sender_timestamp_ns);
    writer.u64(packet.header.sample_index);
    writer.u32(packet.header.sample_rate);
    writer.u16(packet.header.channel_count);
    writer.u16(packet.header.frames_per_packet);
    writer.u32(payload_size);

    for (const float sample : packet.interleaved_samples) {
        writer.u32(std::bit_cast<std::uint32_t>(sample));
    }
    return bytes;
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
        !reader.u32(payload_size)) {
        return failure("truncated header");
    }

    if (magic != kMagic) return failure("invalid magic");
    if (version != kProtocolVersion) return failure("unsupported protocol version");
    if (packet_type != kAudioPacketType) return failure("unsupported packet type");
    if (header_size != kHeaderSize) return failure("unsupported header size");
    if (packet.header.sample_rate != kSampleRate ||
        packet.header.channel_count != kChannelCount ||
        packet.header.frames_per_packet != kFramesPerPacket) {
        return failure("unsupported audio format");
    }
    if (payload_size != kPayloadBytes) return failure("invalid payload size");
    if (datagram.size() != static_cast<std::size_t>(header_size) + payload_size) {
        return failure("datagram size does not match payload size");
    }

    packet.interleaved_samples.resize(kSamplesPerPacket);
    for (auto& sample : packet.interleaved_samples) {
        std::uint32_t bits = 0;
        if (!reader.u32(bits)) return failure("truncated PCM payload");
        sample = std::bit_cast<float>(bits);
    }
    return {.packet = std::move(packet), .error = {}};
}

}  // namespace multipoint::protocol
