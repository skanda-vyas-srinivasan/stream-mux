#include "multipoint/clock/monotonic_clock.h"
#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <numbers>
#include <string>
#include <thread>

namespace {

constexpr double kFrequency = 440.0;
constexpr float kAmplitude = 0.12F;

}  // namespace

int main(int argc, char** argv) {
    try {
        const std::string host = argc > 1 ? argv[1] : "127.0.0.1";
        const auto port = static_cast<std::uint16_t>(argc > 2 ? std::stoi(argv[2]) : 48100);
        const double duration_seconds = argc > 3 ? std::stod(argv[3]) : 0.0;

        multipoint::network::UdpSender sender(host, port);
        const auto stream_id = multipoint::clock::monotonic_time_ns();
        std::uint32_t sequence = 0;
        std::uint64_t sample_index = 0;
        const auto packet_duration = std::chrono::nanoseconds(
            1'000'000'000LL * multipoint::protocol::kFramesPerPacket /
            multipoint::protocol::kSampleRate);
        const auto start = std::chrono::steady_clock::now();
        auto deadline = start;

        std::cout << "Sending 440 Hz PCM to " << host << ':' << port
                  << " (Ctrl-C to stop)\n";

        while (duration_seconds <= 0.0 ||
               std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() <
                   duration_seconds) {
            multipoint::protocol::AudioPacket packet;
            packet.header.stream_id = stream_id;
            packet.header.sequence = sequence++;
            packet.header.sender_timestamp_ns = multipoint::clock::monotonic_time_ns();
            packet.header.sample_index = sample_index;
            packet.interleaved_samples.resize(multipoint::protocol::kSamplesPerPacket);

            for (std::uint16_t frame = 0;
                 frame < multipoint::protocol::kFramesPerPacket;
                 ++frame) {
                const auto absolute_frame = sample_index + frame;
                const double phase = 2.0 * std::numbers::pi * kFrequency *
                    static_cast<double>(absolute_frame) /
                    multipoint::protocol::kSampleRate;
                const auto value = static_cast<float>(std::sin(phase)) * kAmplitude;
                const auto offset = static_cast<std::size_t>(frame) * 2;
                packet.interleaved_samples[offset] = value;
                packet.interleaved_samples[offset + 1] = value;
            }
            sample_index += multipoint::protocol::kFramesPerPacket;
            const auto datagram = multipoint::protocol::serialize(packet);
            sender.send(datagram);
            deadline += packet_duration;
            std::this_thread::sleep_until(deadline);
        }
        std::cout << "Sent " << sequence << " packets\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "sender error: " << error.what() << '\n';
        return EXIT_FAILURE;
    }
}
