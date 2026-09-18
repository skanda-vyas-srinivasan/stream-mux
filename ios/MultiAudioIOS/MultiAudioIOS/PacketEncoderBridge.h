#ifndef MULTIPOINT_PACKET_ENCODER_BRIDGE_H
#define MULTIPOINT_PACKET_ENCODER_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MPAudioFramesPerPacket = 120,
    MPAudioChannelCount = 2,
    MPAudioSamplesPerPacket = MPAudioFramesPerPacket * MPAudioChannelCount,
    MPAudioDatagramSize = 48 + MPAudioSamplesPerPacket * 4,
};

size_t MPAudioPacketEncode(
    const float* interleaved_samples,
    size_t sample_count,
    uint64_t stream_id,
    uint32_t sequence,
    uint64_t sender_timestamp_ns,
    uint64_t sample_index,
    uint8_t* output,
    size_t output_capacity);

#ifdef __cplusplus
}
#endif

#endif
