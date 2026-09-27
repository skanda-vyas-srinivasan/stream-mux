#pragma once

#include "multipoint/audio/spsc_audio_ring.h"

#include <AudioToolbox/AudioToolbox.h>

#include <array>
#include <span>

namespace multipoint::macos {

// Pulls interleaved stereo float32 capture audio and produces 48 kHz audio.
// Used only by the sending worker, never by the Core Audio IOProc. The ring
// must have two channels and outlive this converter.
class StereoSampleRateConverter {
public:
    StereoSampleRateConverter(double input_sample_rate, audio::SpscAudioRing& input);
    ~StereoSampleRateConverter();

    StereoSampleRateConverter(const StereoSampleRateConverter&) = delete;
    StereoSampleRateConverter& operator=(const StereoSampleRateConverter&) = delete;

    // Returns produced frames, possibly fewer than requested. Temporary input
    // starvation preserves filter state; it never inserts silence or ends the
    // stream. Only the returned frames in output are valid.
    std::size_t read(std::span<float> output);

private:
    static OSStatus supply_input(
        AudioConverterRef, UInt32* packets, AudioBufferList* data,
        AudioStreamPacketDescription**, void* context);

    audio::SpscAudioRing& input_;
    AudioConverterRef converter_ = nullptr;
    // Input buffers must remain valid until the converter next calls supply_input.
    std::array<float, 8'192 * 2> input_scratch_{};
};

}  // namespace multipoint::macos
