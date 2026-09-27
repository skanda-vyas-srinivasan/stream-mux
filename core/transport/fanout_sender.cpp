#include "multipoint/transport/fanout_sender.h"

#include <stdexcept>
#include <utility>

namespace multipoint::transport {

void FanoutSender::add_peer(std::string peer_id, std::uint64_t stream_id) {
    if (peer_id.empty()) throw std::invalid_argument("peer ID is empty");
    auto [position, inserted] = peers_.emplace(
        std::move(peer_id), std::make_unique<SenderEngine>(stream_id));
    if (!inserted) throw std::invalid_argument("peer already exists");
    (void)position;
}

bool FanoutSender::remove_peer(const std::string& peer_id) {
    return peers_.erase(peer_id) != 0;
}

bool FanoutSender::contains(const std::string& peer_id) const {
    return peers_.contains(peer_id);
}

std::vector<PeerDatagrams> FanoutSender::push_audio(
    std::span<const float> interleaved_samples,
    std::uint64_t sender_timestamp_ns) {
    std::vector<PeerDatagrams> output;
    output.reserve(peers_.size());
    for (auto& [peer_id, sender] : peers_) {
        output.push_back({
            .peer_id = peer_id,
            .datagrams = sender->push_audio(
                interleaved_samples, sender_timestamp_ns),
        });
    }
    return output;
}

SenderStats FanoutSender::peer_stats(const std::string& peer_id) const {
    const auto found = peers_.find(peer_id);
    if (found == peers_.end()) throw std::out_of_range("unknown peer");
    return found->second->stats();
}

}  // namespace multipoint::transport
