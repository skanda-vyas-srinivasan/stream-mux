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
    MPCryptoKeySize = 32,
    MPCryptoNonceSize = 16,
    MPCryptoProofSize = 32,
    MPCryptoEnvelopeOverhead = 32,
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

typedef void* MPReceiverEngineRef;

typedef struct {
    uint64_t raw_datagrams;
    uint64_t valid_datagrams;
    uint64_t malformed_packets;
    uint64_t stale_stream_packets;
    uint64_t packets_received;
    uint64_t packets_lost;
    uint64_t fec_recovered;
    uint64_t hard_resyncs;
    uint64_t concealed_packets;
    uint64_t audio_underruns;
    size_t jitter_depth;
    size_t buffered_frames;
    bool playout_active;
} MPReceiverStats;

// Owns the portable receiver, jitter buffer, concealment, and the lock-free
// audio ring used by the iOS render callback.
MPReceiverEngineRef MPReceiverEngineCreate(
    size_t reorder_packets,
    size_t prebuffer_frames);
bool MPReceiverEngineIngest(
    MPReceiverEngineRef receiver,
    const uint8_t* bytes,
    size_t size,
    uint64_t arrival_time_ns,
    bool* hard_resync);
// Moves as much decoded audio as practical from the jitter buffer into the
// playback ring. Call this from a non-real-time serial queue.
void MPReceiverEnginePump(MPReceiverEngineRef receiver);
// Discards queued audio/jitter and waits for a fresh prebuffer. Use after an
// audio-session interruption so stale audio is not replayed.
void MPReceiverEngineRebuffer(MPReceiverEngineRef receiver);
bool MPReceiverEngineSetTargetLatency(
    MPReceiverEngineRef receiver,
    uint32_t latency_ms);
// Real-time-safe single-consumer read. Missing frames are zero-filled.
size_t MPReceiverEngineRead(
    MPReceiverEngineRef receiver,
    float* interleaved_samples,
    size_t frame_count);
MPReceiverStats MPReceiverEngineSnapshot(MPReceiverEngineRef receiver);
void MPReceiverEngineDestroy(MPReceiverEngineRef receiver);

typedef void* MPUdpSenderRef;

MPUdpSenderRef MPUdpSenderCreate(const char* host, uint16_t port);
bool MPUdpSenderSend(MPUdpSenderRef sender, const uint8_t* bytes, size_t size);
void MPUdpSenderDestroy(MPUdpSenderRef sender);

typedef void* MPRelayChannelRef;

enum {
    MPRelayRoleSender = 1,
    MPRelayRoleReceiver = 2,
};

// The route is a 32-character hexadecimal bearer capability. A relay channel
// uses one bound UDP socket for registration, payloads, and replies.
MPRelayChannelRef MPRelayChannelCreate(
    const char* host,
    uint16_t port,
    const char* route_hex,
    int role);
bool MPRelayChannelAnnounce(MPRelayChannelRef channel);
bool MPRelayChannelKeepalive(MPRelayChannelRef channel);
bool MPRelayChannelSend(
    MPRelayChannelRef channel,
    const uint8_t* bytes,
    size_t size);
bool MPRelayChannelReceive(
    MPRelayChannelRef channel,
    uint8_t* output,
    size_t output_capacity,
    size_t* output_size);
void MPRelayChannelDestroy(MPRelayChannelRef channel);

typedef void* MPSessionCipherRef;

bool MPCryptoGenerateDeviceKey(uint8_t* secret_key, uint8_t* public_key);
bool MPCryptoPublicKey(const uint8_t* secret_key, uint8_t* public_key);
bool MPCryptoRandom(uint8_t* output, size_t size);
bool MPCryptoDeriveSession(
    const uint8_t* local_secret_key,
    const uint8_t* remote_public_key,
    const uint8_t* sender_public_key,
    const uint8_t* receiver_public_key,
    const uint8_t* client_nonce,
    const uint8_t* server_nonce,
    uint8_t* sender_key,
    uint8_t* receiver_key,
    uint8_t* sender_nonce_prefix,
    uint8_t* receiver_nonce_prefix,
    uint8_t* welcome_proof);
bool MPCryptoPairingCode(
    const uint8_t* sender_public_key,
    const uint8_t* receiver_public_key,
    char* output,
    size_t output_size);
bool MPCryptoHexDecode(const char* text, uint8_t* output, size_t output_size);
bool MPCryptoProofMatches(const uint8_t* expected, const uint8_t* actual);

MPSessionCipherRef MPSessionCipherCreate(
    const uint8_t* key,
    const uint8_t* nonce_prefix);
bool MPSessionCipherEncrypt(
    MPSessionCipherRef cipher,
    const uint8_t* plaintext,
    size_t plaintext_size,
    uint8_t* output,
    size_t output_capacity,
    size_t* output_size);
// Returns 1 for an authenticated envelope, 0 for non-encrypted input, and -1
// for a malformed, replayed, or unauthenticated encrypted envelope.
int MPSessionCipherDecrypt(
    MPSessionCipherRef cipher,
    const uint8_t* datagram,
    size_t datagram_size,
    uint8_t* output,
    size_t output_capacity,
    size_t* output_size);
void MPSessionCipherDestroy(MPSessionCipherRef cipher);

#ifdef __cplusplus
}
#endif

#endif
