#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

struct MacReceiverConfig {
    std::uint16_t port = 48100;
    std::uint32_t latency_ms = 60;
    std::string device_id;
    std::string device_name;
    // Empty uses the system default output. A Core Audio device UID routes
    // received audio directly to that device (for example BlackHole 2ch).
    std::string output_device_uid;
};

struct MacReceiverSnapshot {
    bool running = false;
    bool connected = false;
    bool playing = false;
    std::string sender_name;
    std::uint64_t packets_received = 0;
    std::uint64_t packets_lost = 0;
    std::uint64_t fec_recovered = 0;
    std::uint64_t concealed_packets = 0;
    std::uint64_t audio_underruns = 0;
    std::size_t buffered_frames = 0;
    std::size_t trusted_senders = 0;
};

class MacReceiverRuntime {
public:
    using PairingHandler = std::function<bool(
        const std::string& sender_name,
        const std::string& code)>;

    MacReceiverRuntime(MacReceiverConfig config, PairingHandler pairing_handler);
    ~MacReceiverRuntime();
    MacReceiverRuntime(const MacReceiverRuntime&) = delete;
    MacReceiverRuntime& operator=(const MacReceiverRuntime&) = delete;

    void stop();
    void set_volume(float volume);
    [[nodiscard]] MacReceiverSnapshot snapshot() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
