#include "PacketEncoderBridge.h"

#include "multipoint/network/udp_socket.h"
#include "multipoint/transport/sender_engine.h"

#include <cstring>
#include <new>

MPSenderEngineRef MPSenderEngineCreate(uint64_t stream_id) {
    try {
        return new multipoint::transport::SenderEngine(stream_id);
    } catch (...) {
        return nullptr;
    }
}

bool MPSenderEngineReset(MPSenderEngineRef sender, uint64_t stream_id) {
    if (!sender) return false;
    try {
        static_cast<multipoint::transport::SenderEngine*>(sender)->reset_stream(
            stream_id);
        return true;
    } catch (...) {
        return false;
    }
}

bool MPSenderEnginePush(
    MPSenderEngineRef sender,
    const float* interleaved_samples,
    size_t sample_count,
    uint64_t sender_timestamp_ns,
    uint8_t* output,
    size_t output_capacity,
    size_t* datagram_count) {
    if (!sender || !interleaved_samples || !output || !datagram_count) return false;
    try {
        auto datagrams = static_cast<multipoint::transport::SenderEngine*>(sender)
            ->push_audio(
                std::span<const float>(interleaved_samples, sample_count),
                sender_timestamp_ns);
        const auto required = datagrams.size() * MPAudioDatagramSize;
        if (required > output_capacity) return false;
        auto* cursor = output;
        for (const auto& datagram : datagrams) {
            if (datagram.size() != MPAudioDatagramSize) return false;
            std::memcpy(cursor, datagram.data(), datagram.size());
            cursor += datagram.size();
        }
        *datagram_count = datagrams.size();
        return true;
    } catch (...) {
        return false;
    }
}

void MPSenderEngineDestroy(MPSenderEngineRef sender) {
    delete static_cast<multipoint::transport::SenderEngine*>(sender);
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
