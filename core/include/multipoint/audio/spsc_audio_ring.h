#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace multipoint::audio {

class SpscAudioRing {
public:
    SpscAudioRing(std::size_t capacity_frames, std::size_t channel_count)
        : capacity_frames_(capacity_frames),
          channel_count_(channel_count),
          samples_(capacity_frames * channel_count, 0.0F) {}

    [[nodiscard]] std::size_t available_to_read() const {
        const auto read = read_frame_.load(std::memory_order_acquire);
        const auto write = write_frame_.load(std::memory_order_acquire);
        return static_cast<std::size_t>(write - read);
    }

    [[nodiscard]] std::size_t available_to_write() const {
        return capacity_frames_ - std::min(capacity_frames_, available_to_read());
    }

    std::size_t write(const float* interleaved, std::size_t frame_count) {
        const auto writable = std::min(frame_count, available_to_write());
        const auto write = write_frame_.load(std::memory_order_relaxed);
        for (std::size_t frame = 0; frame < writable; ++frame) {
            const auto ring_frame = static_cast<std::size_t>((write + frame) % capacity_frames_);
            for (std::size_t channel = 0; channel < channel_count_; ++channel) {
                samples_[ring_frame * channel_count_ + channel] =
                    interleaved[frame * channel_count_ + channel];
            }
        }
        write_frame_.store(write + writable, std::memory_order_release);
        return writable;
    }

    std::size_t read(float* interleaved, std::size_t frame_count) {
        const auto readable = std::min(frame_count, available_to_read());
        const auto read = read_frame_.load(std::memory_order_relaxed);
        for (std::size_t frame = 0; frame < readable; ++frame) {
            const auto ring_frame = static_cast<std::size_t>((read + frame) % capacity_frames_);
            for (std::size_t channel = 0; channel < channel_count_; ++channel) {
                interleaved[frame * channel_count_ + channel] =
                    samples_[ring_frame * channel_count_ + channel];
            }
        }
        std::fill(
            interleaved + readable * channel_count_,
            interleaved + frame_count * channel_count_,
            0.0F);
        read_frame_.store(read + readable, std::memory_order_release);
        if (readable < frame_count) {
            underruns_.fetch_add(1, std::memory_order_relaxed);
        }
        return readable;
    }

    [[nodiscard]] std::uint64_t underruns() const {
        return underruns_.load(std::memory_order_relaxed);
    }

    void discard() {
        const auto write = write_frame_.load(std::memory_order_acquire);
        read_frame_.store(write, std::memory_order_release);
    }

private:
    std::size_t capacity_frames_;
    std::size_t channel_count_;
    std::vector<float> samples_;
    alignas(64) std::atomic<std::uint64_t> read_frame_{0};
    alignas(64) std::atomic<std::uint64_t> write_frame_{0};
    std::atomic<std::uint64_t> underruns_{0};
};

}  // namespace multipoint::audio
