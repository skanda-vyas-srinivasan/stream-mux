#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace soundmux::windows {

struct ReceiverConfig {
  std::uint16_t port = 48'100;
  std::uint32_t latency_ms = 100;
  std::string device_name;
};

struct ReceiverSnapshot {
  bool connected = false;
  bool playing = false;
  std::string sender_name;
  std::uint64_t packets_received = 0;
  std::uint64_t packets_lost = 0;
  std::uint64_t packets_reordered = 0;
  std::uint64_t late_packets = 0;
  std::uint64_t fec_recovered = 0;
  std::uint64_t concealed_packets = 0;
  std::uint64_t audio_underruns = 0;
  std::uint64_t hard_resyncs = 0;
  std::uint64_t malformed_packets = 0;
  std::uint64_t max_arrival_gap_ns = 0;
  std::uint64_t arrival_gap_events = 0;
  std::size_t jitter_depth = 0;
  std::size_t buffered_frames = 0;
  std::size_t trusted_senders = 0;
};

class ReceiverRuntime {
public:
  using PairingHandler = std::function<bool(
      const std::string &sender_name, const std::string &comparison_code)>;

  ReceiverRuntime(ReceiverConfig config, PairingHandler pairing_handler);
  ~ReceiverRuntime();
  ReceiverRuntime(const ReceiverRuntime &) = delete;
  ReceiverRuntime &operator=(const ReceiverRuntime &) = delete;

  void stop();
  void set_volume(float volume);
  [[nodiscard]] ReceiverSnapshot snapshot() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace soundmux::windows
