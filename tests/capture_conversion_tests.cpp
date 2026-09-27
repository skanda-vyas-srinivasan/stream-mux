#include "stereo_sample_rate_converter.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/transport/sender_engine.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <iostream>
#include <limits>
#include <numbers>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

std::vector<float> tone(double rate, double seconds, double left_hz, double right_hz) {
    const auto frames = static_cast<std::size_t>(rate * seconds);
    std::vector<float> samples(frames * 2);
    for (std::size_t frame = 0; frame < frames; ++frame) {
        const auto phase = 2 * std::numbers::pi * static_cast<double>(frame) / rate;
        samples[frame * 2] = static_cast<float>(0.5 * std::sin(phase * left_hz));
        samples[frame * 2 + 1] = static_cast<float>(0.25 * std::sin(phase * right_hz));
    }
    return samples;
}

std::vector<float> convert(
    double rate, const std::vector<float>& source, bool fragmented) {
    multipoint::audio::SpscAudioRing ring(source.size() / 2, 2);
    multipoint::macos::StereoSampleRateConverter converter(rate, ring);
    constexpr std::array<std::size_t, 6> input_sizes{1, 17, 240, 511, 7, 1'024};
    constexpr std::array<std::size_t, 4> output_sizes{1, 7, 240, 1'024};
    std::array<float, 1'024 * 2> scratch{};
    std::vector<float> output;
    std::size_t iteration = 0;
    auto drain = [&] {
        // A finite guard catches accidental replay of input on starvation.
        for (std::size_t attempts = 0; attempts < source.size() + 100; ++attempts) {
            const auto requested = fragmented
                ? output_sizes[iteration++ % output_sizes.size()] : 240;
            const auto frames = converter.read(std::span(scratch).first(requested * 2));
            require(frames <= requested, "converter exceeded output capacity");
            if (!frames) return;
            output.insert(output.end(), scratch.data(), scratch.data() + frames * 2);
        }
        throw std::runtime_error("converter never ran out of input");
    };

    require(converter.read(scratch) == 0, "empty capture generated audio");
    std::size_t offset = 0;
    std::size_t chunk = 0;
    while (offset < source.size() / 2) {
        const auto frames = std::min(source.size() / 2 - offset,
            fragmented ? input_sizes[chunk++ % input_sizes.size()] : source.size() / 2);
        require(ring.write(source.data() + offset * 2, frames) == frames,
                "test input overflowed ring");
        offset += frames;
        drain();
        // Model repeated worker polls during pauses between capture callbacks.
        require(converter.read(scratch) == 0, "starvation repeated audio");
        require(converter.read(scratch) == 0, "starvation generated silence");
    }
    require(ring.available_to_read() == 0, "converter left input unread");
    require(ring.underruns() == 0, "converter requested missing ring samples");
    return output;
}

double amplitude(const std::vector<float>& samples, std::size_t channel, double hz) {
    constexpr std::size_t skip = 1'024;
    const auto count = samples.size() / 2 - skip;
    double sine = 0;
    double cosine = 0;
    for (std::size_t frame = skip; frame < samples.size() / 2; ++frame) {
        const auto phase = 2 * std::numbers::pi * hz * static_cast<double>(frame) / 48'000;
        sine += samples[frame * 2 + channel] * std::sin(phase);
        cosine += samples[frame * 2 + channel] * std::cos(phase);
    }
    return 2 * std::hypot(sine, cosine) / static_cast<double>(count);
}

void check_packetization(const std::vector<float>& output) {
    multipoint::transport::SenderEngine sender(123);
    const auto datagrams = sender.push_audio(output, 1'000);
    std::size_t audio_count = 0;
    for (const auto& datagram : datagrams) {
        const auto decoded = multipoint::protocol::deserialize(datagram);
        require(decoded.packet.has_value(), "converted audio produced malformed packet");
        const auto& packet = *decoded.packet;
        if (packet.header.packet_type != multipoint::protocol::kAudioPacketType) continue;
        require(packet.header.sequence == audio_count, "converted sequence skipped");
        require(packet.header.sample_index == audio_count * 240, "wire sample index skipped");
        for (std::size_t index = 0; index < packet.interleaved_samples.size(); ++index) {
            require(std::abs(packet.interleaved_samples[index] -
                             output[audio_count * 480 + index]) <= 1.0F / 32'767.0F,
                    "converted audio changed beyond PCM16 quantization");
        }
        ++audio_count;
    }
    require(audio_count == output.size() / 480, "wrong converted audio packet count");
}

void test_rate(double rate) {
    const auto input = tone(rate, 2, 1'000, 1'733);
    const auto continuous = convert(rate, input, false);
    const auto fragmented = convert(rate, input, true);
    require(continuous.size() == fragmented.size(), "chunking changed output duration");
    for (std::size_t index = 0; index < continuous.size(); ++index) {
        require(std::isfinite(fragmented[index]), "nonfinite converted sample");
        require(std::abs(continuous[index] - fragmented[index]) < 0.00001F,
                "chunking or starvation changed the waveform");
    }
    // A live converter retains its filter tail; no end-of-stream flush occurs.
    const auto frames = static_cast<double>(fragmented.size() / 2);
    require(std::abs(frames - 96'000) < 512, "wrong converted duration/sample rate");
    require(std::abs(amplitude(fragmented, 0, 1'000) - 0.5) < 0.005,
            "left-channel pitch or gain changed");
    require(std::abs(amplitude(fragmented, 1, 1'733) - 0.25) < 0.005,
            "right-channel pitch or gain changed");
    require(amplitude(fragmented, 0, 1'733) < 0.005, "right leaked into left channel");
    require(amplitude(fragmented, 1, 1'000) < 0.005, "left leaked into right channel");
    if (rate == 48'000) require(fragmented == input, "48 kHz bypass changed samples");
    check_packetization(fragmented);
    std::cout << rate << " -> 48000 Hz: " << frames << " frames, chunk/pitch/packet checks passed\n";
}

void test_antialiasing() {
    const auto output = convert(96'000, tone(96'000, 1, 30'000, 30'000), true);
    double energy = 0;
    for (std::size_t index = 2'048; index < output.size(); ++index) {
        energy += static_cast<double>(output[index]) * output[index];
    }
    require(std::sqrt(energy / static_cast<double>(output.size() - 2'048)) < 0.005,
            "downsampling aliased an above-Nyquist tone");
}

void test_invalid_input() {
    multipoint::audio::SpscAudioRing ring(480, 2);
    for (const auto rate : {0.0, -1.0, std::numeric_limits<double>::infinity(),
                           std::numeric_limits<double>::quiet_NaN()}) {
        bool rejected = false;
        try {
            multipoint::macos::StereoSampleRateConverter converter(rate, ring);
        } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "invalid source rate accepted");
    }
    multipoint::macos::StereoSampleRateConverter converter(48'000, ring);
    require(converter.read({}) == 0, "empty output requested audio");
    std::array<float, 3> incomplete_frame{};
    bool rejected = false;
    try { converter.read(incomplete_frame); }
    catch (const std::invalid_argument&) { rejected = true; }
    require(rejected, "partial stereo output frame accepted");
}

}  // namespace

int main() {
    try {
        test_invalid_input();
        for (const auto rate : {32'000.0, 44'100.0, 48'000.0, 88'200.0, 96'000.0, 192'000.0}) {
            test_rate(rate);
        }
        test_antialiasing();
        std::cout << "Capture conversion tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Capture conversion test failed: " << error.what() << '\n';
        return 1;
    }
}
