#include "multipoint/audio/spsc_audio_ring.h"
#include "multipoint/jitter/jitter_buffer.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/fec.h"
#include "multipoint/transport/receiver_engine.h"
#include "multipoint/transport/sender_engine.h"
#include "multipoint/util/sequence.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

multipoint::protocol::AudioPacket make_packet(std::uint32_t sequence) {
    multipoint::protocol::AudioPacket packet;
    packet.header.stream_id = 42;
    packet.header.sequence = sequence;
    packet.header.fec_shard_index = static_cast<std::uint8_t>(
        sequence % multipoint::protocol::kFecDataShards);
    packet.header.sender_timestamp_ns = 123'456 + sequence;
    packet.header.sample_index =
        static_cast<std::uint64_t>(sequence) * multipoint::protocol::kFramesPerPacket;
    packet.interleaved_samples.resize(multipoint::protocol::kSamplesPerPacket);
    for (std::size_t index = 0; index < packet.interleaved_samples.size(); ++index) {
        packet.interleaved_samples[index] = static_cast<float>(index) / 1000.0F;
    }
    return packet;
}

void test_fec_pair_recovery() {
    std::array<std::optional<std::vector<std::byte>>,
               multipoint::protocol::kFecDataShards> data;
    std::array<std::vector<std::byte>,
               multipoint::protocol::kFecDataShards> originals;
    multipoint::protocol::FecDataPayloads spans;
    for (std::size_t index = 0; index < data.size(); ++index) {
        auto packet = make_packet(100 + static_cast<std::uint32_t>(index));
        packet.header.fec_shard_index = static_cast<std::uint8_t>(index);
        auto decoded = multipoint::protocol::deserialize(
            multipoint::protocol::serialize(packet));
        require(decoded.packet.has_value(), "FEC source decode failed");
        originals[index] = decoded.packet->encoded_payload;
        data[index] = originals[index];
        spans[index] = originals[index];
    }

    std::array<std::optional<std::vector<std::byte>>,
               multipoint::protocol::kFecParityShards> parity;
    for (std::size_t index = 0; index < parity.size(); ++index) {
        parity[index] = std::vector<std::byte>(
            multipoint::protocol::kPayloadBytes);
        require(multipoint::protocol::encode_fec_parity(
                    spans, static_cast<std::uint8_t>(index), *parity[index]),
                "parity generation failed");
    }

    constexpr std::array<std::size_t, 5> missing = {0, 1, 2, 3, 4};
    for (const auto index : missing) data[index].reset();
    const auto recovered = multipoint::protocol::recover_fec_data(data, parity);
    require(recovered.has_value(), "five-shard FEC recovery failed");
    require(recovered->size() == missing.size(), "wrong recovered shard count");
    for (const auto& shard : *recovered) {
        require(shard.payload == originals[shard.data_index],
                "FEC did not reconstruct exact PCM16 bytes");
    }
}

void test_packet_round_trip() {
    const auto original = make_packet(99);
    const auto bytes = multipoint::protocol::serialize(original);
    require(bytes.size() == multipoint::protocol::kDatagramBytes, "wrong datagram size");
    const auto decoded = multipoint::protocol::deserialize(bytes);
    require(decoded.packet.has_value(), decoded.error);
    require(decoded.packet->header.sequence == 99, "sequence did not round trip");
    require(decoded.packet->header.sample_index == original.header.sample_index,
            "sample index did not round trip");
    for (std::size_t index = 0; index < original.interleaved_samples.size(); ++index) {
        require(std::abs(decoded.packet->interleaved_samples[index] -
                         original.interleaved_samples[index]) <= 1.0F / 32'767.0F,
                "PCM16 payload exceeded quantization tolerance");
    }
}

void test_sender_engine_packetization_and_epoch_reset() {
    multipoint::transport::SenderEngine sender(9001);
    std::vector<float> samples(
        multipoint::protocol::kSamplesPerPacket * 20, 0.25F);
    const auto datagrams = sender.push_audio(samples, 123'000);
    require(datagrams.size() == 35, "sender emitted wrong audio/parity count");

    std::size_t audio_count = 0;
    std::size_t parity_count = 0;
    for (const auto& datagram : datagrams) {
        const auto decoded = multipoint::protocol::deserialize(datagram);
        require(decoded.packet.has_value(), "sender emitted invalid datagram");
        require(decoded.packet->header.stream_id == 9001, "sender stream ID wrong");
        if (decoded.packet->header.packet_type ==
            multipoint::protocol::kAudioPacketType) {
            require(decoded.packet->header.sequence == audio_count,
                    "sender audio sequence wrong");
            ++audio_count;
        } else {
            const auto expected_group =
                (parity_count / multipoint::protocol::kFecParityShards) *
                multipoint::protocol::kFecDataShards;
            require(decoded.packet->header.sequence == expected_group,
                    "delayed parity protected wrong group");
            ++parity_count;
        }
    }
    require(audio_count == 20, "sender audio count wrong");
    require(parity_count == 15, "sender parity count wrong");

    sender.reset_stream(9002);
    const auto after_reset = sender.push_audio(
        std::span<const float>(samples.data(), multipoint::protocol::kSamplesPerPacket),
        456'000);
    require(after_reset.size() == 1, "sender retained FEC state across epoch");
    const auto decoded = multipoint::protocol::deserialize(after_reset.front());
    require(decoded.packet.has_value(), "reset sender emitted invalid packet");
    require(decoded.packet->header.stream_id == 9002, "sender reset stream ID wrong");
    require(decoded.packet->header.sequence == 0, "sender reset sequence wrong");
    require(decoded.packet->header.sample_index == 0, "sender reset sample index wrong");
}

void test_receiver_engine_fec_and_epoch_rejection() {
    multipoint::transport::SenderEngine sender(7001);
    multipoint::transport::ReceiverEngine receiver({
        .reorder_packets = 3,
        .capacity_packets = 64,
        .hard_resync_gap_packets = 20,
        .maximum_fec_groups = 16,
    });
    std::vector<float> samples(
        multipoint::protocol::kSamplesPerPacket * 20, 0.125F);
    const auto old_epoch = sender.push_audio(samples, 1'000'000);

    std::vector<std::byte> delayed_old_packet;
    std::uint64_t arrival_ns = 2'000'000;
    for (const auto& datagram : old_epoch) {
        const auto decoded = multipoint::protocol::deserialize(datagram);
        require(decoded.packet.has_value(), "receiver test source decode failed");
        const auto& header = decoded.packet->header;
        if (header.packet_type == multipoint::protocol::kAudioPacketType &&
            header.sequence == 2) {
            continue;
        }
        if (header.packet_type == multipoint::protocol::kAudioPacketType &&
            header.sequence == 3) {
            delayed_old_packet = datagram;
        }
        const auto ingest = receiver.ingest(datagram, arrival_ns);
        require(ingest.error.empty(), "receiver rejected a valid test datagram");
        arrival_ns += 1'000'000;
    }

    auto stats = receiver.snapshot();
    require(stats.fec_recovered == 1, "receiver did not recover one missing shard");
    for (std::uint32_t sequence = 0; sequence < 10; ++sequence) {
        const auto popped = receiver.pop();
        require(popped.packet && popped.packet->header.sequence == sequence,
                "receiver FEC playout sequence was not contiguous");
    }

    sender.reset_stream(7002);
    const auto new_epoch = sender.push_audio(
        std::span<const float>(samples.data(), multipoint::protocol::kSamplesPerPacket),
        3'000'000);
    const auto transition = receiver.ingest(new_epoch.front(), arrival_ns);
    require(transition.hard_resync, "new sender epoch did not hard resync receiver");
    const auto before_stale = receiver.snapshot();
    const auto stale = receiver.ingest(delayed_old_packet, arrival_ns + 1'000'000);
    require(!stale.accepted && !stale.hard_resync,
            "retired epoch packet was accepted or triggered resync");
    const auto after_stale = receiver.snapshot();
    require(after_stale.stale_stream_packets ==
                before_stale.stale_stream_packets + 1,
            "retired epoch packet was not counted");
    require(after_stale.hard_resyncs == before_stale.hard_resyncs,
            "retired epoch packet caused another hard resync");
}

void test_receiver_engine_sequence_gap_resync() {
    multipoint::transport::ReceiverEngine receiver({
        .reorder_packets = 3,
        .capacity_packets = 64,
        .hard_resync_gap_packets = 5,
        .maximum_fec_groups = 16,
    });
    auto first = make_packet(0);
    auto distant = make_packet(8);
    require(!receiver.ingest(multipoint::protocol::serialize(first), 1'000).hard_resync,
            "first receiver packet unexpectedly resynced");
    require(receiver.ingest(multipoint::protocol::serialize(distant), 2'000).hard_resync,
            "large forward sequence gap did not hard resync");
    require(receiver.snapshot().hard_resyncs == 1,
            "sequence gap hard resync count wrong");
}

void test_packet_rejection() {
    auto bytes = multipoint::protocol::serialize(make_packet(1));
    bytes[0] = std::byte{0};
    require(!multipoint::protocol::deserialize(bytes).packet, "bad magic was accepted");
    bytes = multipoint::protocol::serialize(make_packet(1));
    bytes.pop_back();
    require(!multipoint::protocol::deserialize(bytes).packet, "truncation was accepted");
}

void test_sequence_wrap() {
    require(multipoint::util::sequence_before(
                std::numeric_limits<std::uint32_t>::max(), 0),
            "wrap comparison failed");
    require(multipoint::util::sequence_after(
                0, std::numeric_limits<std::uint32_t>::max()),
            "wrap comparison inverse failed");
}

void test_jitter_reorder_loss_and_duplicate() {
    multipoint::jitter::JitterBuffer jitter(3, 16);
    require(jitter.insert(make_packet(10)), "insert 10 failed");
    require(jitter.insert(make_packet(12)), "insert 12 failed");
    require(jitter.insert(make_packet(11)), "insert 11 failed");
    require(!jitter.insert(make_packet(11)), "duplicate was accepted");

    auto first = jitter.pop();
    auto second = jitter.pop();
    auto third = jitter.pop();
    require(first.packet && first.packet->header.sequence == 10, "wrong first packet");
    require(second.packet && second.packet->header.sequence == 11, "reorder failed");
    require(third.packet && third.packet->header.sequence == 12, "wrong third packet");
    require(jitter.pop().status == multipoint::jitter::PopStatus::missing,
            "loss was not detected");
    require(!jitter.insert(make_packet(9)), "late packet was accepted");
    require(jitter.stats().packets_reordered == 1, "reorder statistic wrong");
    require(jitter.stats().duplicate_packets == 1, "duplicate statistic wrong");
    require(jitter.stats().packets_lost == 1, "loss statistic wrong");
    require(jitter.stats().late_packets == 1, "late statistic wrong");

    multipoint::jitter::JitterBuffer grace(2, 16);
    require(grace.insert(make_packet(50)), "grace insert 50 failed");
    require(grace.insert(make_packet(52)), "grace insert 52 failed");
    require(grace.pop().packet->header.sequence == 50, "grace start failed");
    require(grace.pop(false).status == multipoint::jitter::PopStatus::not_ready,
            "missing packet was declared during grace period");
    require(grace.stats().packets_lost == 0, "grace period counted a loss");
    require(grace.insert(make_packet(51)), "grace rejected delayed packet");
    require(grace.pop().packet->header.sequence == 51,
            "grace period advanced past delayed packet");

    const auto received_before_rebuffer = jitter.stats().packets_received;
    jitter.rebuffer();
    require(!jitter.started() && jitter.depth() == 0, "rebuffer did not pause");
    require(jitter.stats().packets_received == received_before_rebuffer,
            "rebuffer erased cumulative statistics");
}

void test_audio_ring() {
    multipoint::audio::SpscAudioRing ring(4, 2);
    const float input[] = {1, 2, 3, 4, 5, 6};
    require(ring.write(input, 3) == 3, "ring write failed");
    float output[8]{};
    require(ring.read(output, 4) == 3, "ring read count wrong");
    for (std::size_t index = 0; index < 6; ++index) {
        require(output[index] == input[index], "ring data mismatch");
    }
    require(output[6] == 0 && output[7] == 0, "ring did not zero-fill underrun");
    require(ring.underruns() == 1, "underrun statistic wrong");
}

void test_jitter_latency_recovery() {
    multipoint::jitter::JitterBuffer jitter(3, 16);
    for (std::uint32_t sequence = 10; sequence <= 20; ++sequence) {
        require(jitter.insert(make_packet(sequence)), "recovery insert failed");
    }
    require(jitter.pop().packet->header.sequence == 10, "recovery start failed");
    require(jitter.discard_oldest_until(3) == 7, "wrong latency discard count");
    require(jitter.depth() == 3, "latency trim missed target");
    require(jitter.stats().latency_drops == 7, "latency drops statistic wrong");
    require(jitter.pop().packet->header.sequence == 18, "latency trim kept stale audio");

    multipoint::jitter::JitterBuffer gap(3, 16);
    require(gap.insert(make_packet(30)), "gap insert 30 failed");
    require(gap.insert(make_packet(40)), "gap insert 40 failed");
    require(gap.insert(make_packet(41)), "gap insert 41 failed");
    require(gap.pop().packet->header.sequence == 30, "gap start failed");
    require(gap.pop().status == multipoint::jitter::PopStatus::missing,
            "gap was not detected");
    require(gap.advance_to_oldest_available(), "gap advance failed");
    require(gap.pop().packet->header.sequence == 40, "gap advance chose wrong packet");
}

}  // namespace

int main() {
    try {
        test_packet_round_trip();
        test_sender_engine_packetization_and_epoch_reset();
        test_receiver_engine_fec_and_epoch_rejection();
        test_receiver_engine_sequence_gap_resync();
        test_packet_rejection();
        test_fec_pair_recovery();
        test_sequence_wrap();
        test_jitter_reorder_loss_and_duplicate();
        test_jitter_latency_recovery();
        test_audio_ring();
        std::cout << "All multipoint core tests passed\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "Test failure: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
