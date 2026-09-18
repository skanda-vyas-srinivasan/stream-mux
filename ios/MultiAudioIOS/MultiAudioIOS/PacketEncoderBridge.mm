#include "PacketEncoderBridge.h"

#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/fec.h"
#include "multipoint/network/udp_socket.h"

#include <cstring>
#include <new>

size_t MPAudioPacketEncode(
    const float* interleaved_samples,
    size_t sample_count,
    uint64_t stream_id,
    uint32_t sequence,
    uint64_t sender_timestamp_ns,
    uint64_t sample_index,
    uint8_t* output,
    size_t output_capacity) {
    if (!interleaved_samples || !output ||
        sample_count != multipoint::protocol::kSamplesPerPacket) {
        return 0;
    }

    multipoint::protocol::AudioPacket packet;
    packet.header.stream_id = stream_id;
    packet.header.sequence = sequence;
    packet.header.sender_timestamp_ns = sender_timestamp_ns;
    packet.header.sample_index = sample_index;
    packet.header.fec_shard_index = static_cast<std::uint8_t>(
        sequence % multipoint::protocol::kFecDataShards);
    packet.interleaved_samples.assign(
        interleaved_samples,
        interleaved_samples + sample_count);

    const auto bytes = multipoint::protocol::serialize(packet);
    if (bytes.size() > output_capacity) return 0;
    std::memcpy(output, bytes.data(), bytes.size());
    return bytes.size();
}

size_t MPAudioFECParityEncode(
    const uint8_t* data_datagrams,
    size_t datagram_size,
    size_t data_count,
    uint8_t parity_index,
    uint8_t* output,
    size_t output_capacity) {
    using namespace multipoint::protocol;
    if (!data_datagrams || !output || data_count != kFecDataShards ||
        datagram_size != kDatagramBytes || parity_index >= kFecParityShards) {
        return 0;
    }

    std::array<AudioPacket, kFecDataShards> packets;
    FecDataPayloads payloads;
    for (std::size_t index = 0; index < kFecDataShards; ++index) {
        const auto decoded = deserialize(std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(
                data_datagrams + index * datagram_size),
            datagram_size));
        if (!decoded.packet ||
            decoded.packet->header.packet_type != kAudioPacketType ||
            decoded.packet->header.fec_shard_index != index) {
            return 0;
        }
        packets[index] = std::move(*decoded.packet);
        if (index > 0 &&
            (packets[index].header.stream_id != packets[0].header.stream_id ||
             packets[index].header.sequence != packets[0].header.sequence + index)) {
            return 0;
        }
        payloads[index] = packets[index].encoded_payload;
    }

    AudioPacket parity;
    parity.header = packets[0].header;
    parity.header.packet_type = kFecParityPacketType;
    parity.header.fec_shard_index = kFecDataShards + parity_index;
    parity.encoded_payload.resize(kPayloadBytes);
    if (!encode_fec_parity(payloads, parity_index, parity.encoded_payload)) return 0;

    const auto bytes = serialize(parity);
    if (bytes.size() > output_capacity) return 0;
    std::memcpy(output, bytes.data(), bytes.size());
    return bytes.size();
}

MPUdpSenderRef MPUdpSenderCreate(const char* host, uint16_t port) {
    if (!host) return nullptr;
    try {
        return new multipoint::network::UdpSender(host, port);
    } catch (...) {
        return nullptr;
    }
}

bool MPUdpSenderSend(MPUdpSenderRef sender, const uint8_t* bytes, size_t size) {
    if (!sender || !bytes || size == 0) return false;
    try {
        auto* udp = static_cast<multipoint::network::UdpSender*>(sender);
        udp->send(std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(bytes), size));
        return true;
    } catch (...) {
        return false;
    }
}

void MPUdpSenderDestroy(MPUdpSenderRef sender) {
    delete static_cast<multipoint::network::UdpSender*>(sender);
}
