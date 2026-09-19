#include "multipoint/transport/sender_engine.h"

#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/fec.h"

#include <array>
#include <stdexcept>
#include <utility>

namespace multipoint::transport {

SenderEngine::SenderEngine(std::uint64_t stream_id) {
    reset_stream(stream_id);
    stats_.stream_epochs = 0;
}

void SenderEngine::reset_stream(std::uint64_t stream_id) {
    if (stream_id == 0) {
        throw std::invalid_argument("stream ID must be nonzero");
    }
    pending_samples_.clear();
    pending_offset_ = 0;
    fec_group_.clear();
    delayed_parity_.clear();
    stream_id_ = stream_id;
    sequence_ = 0;
    sample_index_ = 0;
    ++stats_.stream_epochs;
}

std::vector<Datagram> SenderEngine::push_audio(
    std::span<const float> interleaved_samples,
    std::uint64_t sender_timestamp_ns) {
    if (interleaved_samples.size() % protocol::kChannelCount != 0) {
        throw std::invalid_argument("audio sample count is not frame aligned");
    }

    pending_samples_.insert(
        pending_samples_.end(), interleaved_samples.begin(), interleaved_samples.end());

    std::vector<Datagram> output;
    while (pending_samples_.size() - pending_offset_ >= protocol::kSamplesPerPacket) {
        protocol::AudioPacket packet;
        packet.header.stream_id = stream_id_;
        packet.header.sequence = sequence_;
        packet.header.sender_timestamp_ns = sender_timestamp_ns;
        packet.header.sample_index = sample_index_;
        packet.header.fec_shard_index = static_cast<std::uint8_t>(
            sequence_ % protocol::kFecDataShards);
        const auto begin = pending_samples_.begin() +
            static_cast<std::ptrdiff_t>(pending_offset_);
        packet.interleaved_samples.assign(
            begin,
            begin + static_cast<std::ptrdiff_t>(protocol::kSamplesPerPacket));

        auto datagram = protocol::serialize(packet);
        fec_group_.push_back(datagram);
        output.push_back(std::move(datagram));
        pending_offset_ += protocol::kSamplesPerPacket;
        ++sequence_;
        sample_index_ += protocol::kFramesPerPacket;
        ++stats_.audio_packets;

        if (fec_group_.size() == protocol::kFecDataShards) {
            for (auto& parity : delayed_parity_) {
                output.push_back(std::move(parity));
                ++stats_.parity_packets;
            }
            delayed_parity_ = make_parity();
            fec_group_.clear();
        }
    }

    if (pending_offset_ > 0 &&
        (pending_offset_ == pending_samples_.size() ||
         pending_offset_ >= protocol::kSamplesPerPacket * 16)) {
        pending_samples_.erase(
            pending_samples_.begin(),
            pending_samples_.begin() + static_cast<std::ptrdiff_t>(pending_offset_));
        pending_offset_ = 0;
    }
    return output;
}

std::vector<Datagram> SenderEngine::make_parity() const {
    if (fec_group_.size() != protocol::kFecDataShards) {
        throw std::logic_error("incomplete FEC source group");
    }

    std::array<protocol::AudioPacket, protocol::kFecDataShards> packets;
    protocol::FecDataPayloads payloads;
    for (std::size_t index = 0; index < fec_group_.size(); ++index) {
        auto decoded = protocol::deserialize(fec_group_[index]);
        if (!decoded.packet ||
            decoded.packet->header.packet_type != protocol::kAudioPacketType) {
            throw std::logic_error("sender produced an invalid source datagram");
        }
        packets[index] = std::move(*decoded.packet);
        payloads[index] = packets[index].encoded_payload;
    }

    std::vector<Datagram> parity_datagrams;
    parity_datagrams.reserve(protocol::kFecParityShards);
    for (std::uint8_t index = 0; index < protocol::kFecParityShards; ++index) {
        protocol::AudioPacket parity;
        parity.header = packets[0].header;
        parity.header.packet_type = protocol::kFecParityPacketType;
        parity.header.fec_shard_index = static_cast<std::uint8_t>(
            protocol::kFecDataShards + index);
        parity.encoded_payload.resize(protocol::kPayloadBytes);
        if (!protocol::encode_fec_parity(payloads, index, parity.encoded_payload)) {
            throw std::logic_error("FEC parity generation failed");
        }
        parity_datagrams.push_back(protocol::serialize(parity));
    }
    return parity_datagrams;
}

}  // namespace multipoint::transport
