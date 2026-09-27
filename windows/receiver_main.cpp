#ifndef _WIN32
#error "receiver_main.cpp is only for Windows"
#endif

#include "receiver_runtime.h"

#include <windows.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

namespace {

std::atomic<bool> keep_running{true};

BOOL WINAPI console_handler(DWORD signal) {
  if (signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT ||
      signal == CTRL_CLOSE_EVENT || signal == CTRL_SHUTDOWN_EVENT) {
    keep_running.store(false, std::memory_order_release);
    return TRUE;
  }
  return FALSE;
}

std::uint32_t parse_number(const char *text, std::uint32_t minimum,
                           std::uint32_t maximum, const char *description) {
  std::size_t parsed = 0;
  const auto value = std::stoul(text, &parsed);
  if (text[parsed] != '\0' || value < minimum || value > maximum) {
    throw std::invalid_argument(std::string("invalid ") + description);
  }
  return static_cast<std::uint32_t>(value);
}

std::string computer_name() {
  char name[MAX_COMPUTERNAME_LENGTH + 1]{};
  DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
  if (!GetComputerNameA(name, &size))
    return "Windows PC";
  return std::string(name, size);
}

} // namespace

int main(int argc, char **argv) {
  try {
    if (argc == 2 && std::string(argv[1]) == "--help") {
      std::cout << "Usage: soundmux_windows_receiver [port] [latency-ms]\n"
                << "Defaults: UDP port 48100, target latency 100 ms.\n";
      return EXIT_SUCCESS;
    }
    const auto port =
        argc > 1 ? parse_number(argv[1], 1, 65'534, "UDP port") : 48'100U;
    const auto latency =
        argc > 2 ? parse_number(argv[2], 40, 500, "latency") : 100U;
    if (argc > 3) {
      std::cerr << "Usage: soundmux_windows_receiver [port] [latency-ms]\n";
      return EXIT_FAILURE;
    }
    SetConsoleCtrlHandler(console_handler, TRUE);
    std::cout
        << "SoundMux Windows receiver\n"
        << "Listening securely on UDP " << port << " with " << latency
        << " ms target latency.\n"
        << "On the Mac, choose Manual address and enter this PC's IP:" << port
        << ".\n"
        << "Windows may ask you to allow SoundMux through the firewall.\n";

    soundmux::windows::ReceiverRuntime receiver(
        {
            .port = static_cast<std::uint16_t>(port),
            .latency_ms = latency,
            .device_name = computer_name(),
        },
        [](const std::string &sender, const std::string &code) {
          std::cout << "\nPairing request from " << sender << "\n"
                    << "Comparison code: " << code << "\n"
                    << "Approve only if the Mac shows the same code. [y/N] "
                    << std::flush;
          std::string answer;
          std::getline(std::cin, answer);
          return answer == "y" || answer == "Y" || answer == "yes" ||
                 answer == "YES";
        });

    while (keep_running.load(std::memory_order_acquire)) {
      const auto stats = receiver.snapshot();
      std::cout << '\r'
                << (stats.playing ? "Playing"
                                  : (stats.connected ? "Buffering" : "Waiting"))
                << " packets=" << stats.packets_received
                << " lost=" << stats.packets_lost
                << " recovered=" << stats.fec_recovered
                << " concealed=" << stats.concealed_packets
                << " underruns=" << stats.audio_underruns
                << " buffer_ms=" << std::fixed << std::setprecision(0)
                << stats.buffered_frames * 1'000.0 / 48'000.0
                << " max_gap_ms=" << std::setprecision(1)
                << stats.max_arrival_gap_ns / 1'000'000.0
                << " resyncs=" << stats.hard_resyncs
                << " malformed=" << stats.malformed_packets << "      "
                << std::flush;
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    std::cout << "\nStopping SoundMux receiver.\n";
    receiver.stop();
    return EXIT_SUCCESS;
  } catch (const std::exception &error) {
    std::cerr << "SoundMux receiver error: " << error.what() << '\n';
    return EXIT_FAILURE;
  }
}
