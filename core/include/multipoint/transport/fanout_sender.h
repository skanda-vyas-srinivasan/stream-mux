#pragma once

#include "multipoint/transport/sender_engine.h"

#include <cstdint>
#include <map>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace multipoint::transport {

struct PeerDatagrams {
    std::string peer_id;
    std::vector<std::vector<std::byte>> datagrams;
};

// Packetizes one captured PCM stream for multiple independent receiver
// sessions. Each peer owns its own stream epoch, sequence, and FEC state so a
// handoff or reconnect never resets the other members of an audio group.
class FanoutSender {
public:
    void add_peer(std::string peer_id, std::uint64_t stream_id);
    [[nodiscard]] bool remove_peer(const std::string& peer_id);
    [[nodiscard]] bool contains(const std::string& peer_id) const;
    [[nodiscard]] std::size_t size() const { return peers_.size(); }

    [[nodiscard]] std::vector<PeerDatagrams> push_audio(
        std::span<const float> interleaved_samples,
        std::uint64_t sender_timestamp_ns);
    [[nodiscard]] SenderStats peer_stats(const std::string& peer_id) const;

private:
    std::map<std::string, std::unique_ptr<SenderEngine>> peers_;
};

}  // namespace multipoint::transport
