#ifndef MULTIPOINT_PACKET_ENCODER_BRIDGE_H
#define MULTIPOINT_PACKET_ENCODER_BRIDGE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MPAudioFramesPerPacket = 240,
    MPAudioChannelCount = 2,
    MPAudioSamplesPerPacket = MPAudioFramesPerPacket * MPAudioChannelCount,
    MPAudioFECDataShards = 10,
    MPAudioFECParityShards = 5,
    MPAudioDatagramSize = 52 + MPAudioSamplesPerPacket * 2,
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

size_t MPAudioFECParityEncode(
    const uint8_t* data_datagrams,
    size_t datagram_size,
    size_t data_count,
    uint8_t parity_index,
    uint8_t* output,
    size_t output_capacity);

typedef void* MPUdpSenderRef;

MPUdpSenderRef MPUdpSenderCreate(const char* host, uint16_t port);
bool MPUdpSenderSend(MPUdpSenderRef sender, const uint8_t* bytes, size_t size);
void MPUdpSenderDestroy(MPUdpSenderRef sender);

#ifdef __cplusplus
}
#endif

#endif
