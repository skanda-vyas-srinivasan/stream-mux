#include "stereo_sample_rate_converter.h"

#include "multipoint/protocol/audio_packet.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <string>

namespace multipoint::macos {
namespace {

constexpr UInt32 kChannels = 2;
constexpr UInt32 kBytesPerFrame = kChannels * sizeof(float);
constexpr OSStatus kNeedsInput = 0x736d6e69;  // 'smni'; temporary, not end of stream.

AudioStreamBasicDescription stereo_format(double sample_rate) {
    return {
        .mSampleRate = sample_rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = kBytesPerFrame,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = kBytesPerFrame,
        .mChannelsPerFrame = kChannels,
        .mBitsPerChannel = 32,
        .mReserved = 0,
    };
}

void check_converter(OSStatus status, const char* operation) {
    if (status != noErr) {
        throw std::runtime_error(
            std::string(operation) + " failed: " + std::to_string(status));
    }
}

}  // namespace

StereoSampleRateConverter::StereoSampleRateConverter(
    double input_sample_rate, audio::SpscAudioRing& input) : input_(input) {
    if (!std::isfinite(input_sample_rate) || input_sample_rate <= 0) {
        throw std::invalid_argument("Core Audio tap sample rate must be positive and finite");
    }
    if (input_sample_rate == protocol::kSampleRate) return;

    const auto source = stereo_format(input_sample_rate);
    const auto destination = stereo_format(protocol::kSampleRate);
    check_converter(AudioConverterNew(&source, &destination, &converter_),
                    "create capture sample-rate converter");
    const UInt32 quality = kAudioConverterQuality_High;
    const auto status = AudioConverterSetProperty(
        converter_, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);
    if (status != noErr) {
        AudioConverterDispose(converter_);
        converter_ = nullptr;
        check_converter(status, "set capture sample-rate conversion quality");
    }
}

StereoSampleRateConverter::~StereoSampleRateConverter() {
    if (converter_) AudioConverterDispose(converter_);
}

std::size_t StereoSampleRateConverter::read(std::span<float> output) {
    if (output.size() % kChannels != 0 ||
        output.size_bytes() > std::numeric_limits<UInt32>::max()) {
        throw std::invalid_argument("conversion output must contain whole stereo frames");
    }
    if (output.empty()) return 0;
    const auto requested_frames = output.size() / kChannels;
    if (!converter_) {
        const auto frames = std::min(requested_frames, input_.available_to_read());
        return input_.read(output.data(), frames);
    }

    AudioBufferList buffers{};
    buffers.mNumberBuffers = 1;
    buffers.mBuffers[0] = {
        .mNumberChannels = kChannels,
        .mDataByteSize = static_cast<UInt32>(output.size_bytes()),
        .mData = output.data(),
    };
    auto frames = static_cast<UInt32>(requested_frames);
    const auto status = AudioConverterFillComplexBuffer(
        converter_, supply_input, this, &frames, &buffers, nullptr);
    // A nonzero callback status with zero input packets means "try later".
    // AudioConverter can still return valid partial output on that call.
    if (status != kNeedsInput) check_converter(status, "convert capture sample rate");
    return frames;
}

OSStatus StereoSampleRateConverter::supply_input(
    AudioConverterRef, UInt32* packets, AudioBufferList* data,
    AudioStreamPacketDescription**, void* context) {
    auto& self = *static_cast<StereoSampleRateConverter*>(context);
    const auto frames = std::min({
        static_cast<std::size_t>(*packets),
        self.input_.available_to_read(),
        self.input_scratch_.size() / kChannels,
    });
    *packets = static_cast<UInt32>(frames);
    data->mNumberBuffers = 1;
    data->mBuffers[0] = {
        .mNumberChannels = kChannels,
        .mDataByteSize = static_cast<UInt32>(frames * kBytesPerFrame),
        .mData = frames ? self.input_scratch_.data() : nullptr,
    };
    if (frames == 0) return kNeedsInput;
    self.input_.read(self.input_scratch_.data(), frames);
    return noErr;
}

}  // namespace multipoint::macos
