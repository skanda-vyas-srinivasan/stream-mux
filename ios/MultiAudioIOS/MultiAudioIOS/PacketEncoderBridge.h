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
    MPAudioFECDataShards = 5,
    MPAudioFECParityShards = 5,
    MPAudioDatagramSize = 52 + MPAudioSamplesPerPacket * 2,
};

typedef void* MPSenderEngineRef;

MPSenderEngineRef MPSenderEngineCreate(uint64_t stream_id);
bool MPSenderEngineReset(MPSenderEngineRef sender, uint64_t stream_id);
bool MPSenderEnginePush(
    MPSenderEngineRef sender,
    const float* interleaved_samples,
    size_t sample_count,
    uint64_t sender_timestamp_ns,
    uint8_t* output,
    size_t output_capacity,
    size_t* datagram_count);
void MPSenderEngineDestroy(MPSenderEngineRef sender);

typedef void* MPUdpSenderRef;

MPUdpSenderRef MPUdpSenderCreate(const char* host, uint16_t port);
bool MPUdpSenderSend(MPUdpSenderRef sender, const uint8_t* bytes, size_t size);
void MPUdpSenderDestroy(MPUdpSenderRef sender);

#ifdef __cplusplus
}
#endif

#endif
