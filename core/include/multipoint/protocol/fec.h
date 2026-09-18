#pragma once

#include "multipoint/protocol/audio_packet.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

namespace multipoint::protocol {

using FecDataPayloads =
    std::array<std::span<const std::byte>, kFecDataShards>;

struct RecoveredFecShard {
    std::uint8_t data_index = 0;
    std::vector<std::byte> payload;
};

// Systematic Reed-Solomon parity over GF(256). The ten audio shards are the
// systematic portion and any five missing shards can be reconstructed from
// the five parity shards.
[[nodiscard]] bool encode_fec_parity(
    const FecDataPayloads& data,
    std::uint8_t parity_index,
    std::span<std::byte> output);

[[nodiscard]] std::optional<std::vector<RecoveredFecShard>> recover_fec_data(
    const std::array<std::optional<std::vector<std::byte>>, kFecDataShards>& data,
    const std::array<std::optional<std::vector<std::byte>>, kFecParityShards>& parity);

}  // namespace multipoint::protocol
