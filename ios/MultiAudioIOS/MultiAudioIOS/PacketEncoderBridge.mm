#include "PacketEncoderBridge.h"

#include "multipoint/protocol/audio_packet.h"

#include <cstring>

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
    packet.interleaved_samples.assign(
        interleaved_samples,
        interleaved_samples + sample_count);

    const auto bytes = multipoint::protocol::serialize(packet);
    if (bytes.size() > output_capacity) return 0;
    std::memcpy(output, bytes.data(), bytes.size());
    return bytes.size();
}
