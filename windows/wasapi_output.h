#pragma once

#include "multipoint/audio/spsc_audio_ring.h"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace soundmux::windows {

class WasapiOutput {
public:
  WasapiOutput();
  ~WasapiOutput();
  WasapiOutput(const WasapiOutput &) = delete;
  WasapiOutput &operator=(const WasapiOutput &) = delete;

  [[nodiscard]] std::size_t available_to_read() const;
  [[nodiscard]] std::size_t available_to_write() const;
  std::size_t write(const float *interleaved, std::size_t frames);
  void discard();
  void set_playing(bool playing);
  [[nodiscard]] bool playing() const;
  void set_volume(float volume);
  [[nodiscard]] std::uint64_t underruns() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace soundmux::windows
