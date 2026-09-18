#include "multipoint/protocol/fec.h"

#include <algorithm>

namespace multipoint::protocol {
namespace {

using Matrix = std::vector<std::vector<std::uint8_t>>;

std::uint8_t gf_multiply(std::uint8_t left, std::uint8_t right) {
    std::uint8_t result = 0;
    for (int bit = 0; bit < 8; ++bit) {
        if ((right & 1U) != 0) result ^= left;
        const bool high_bit = (left & 0x80U) != 0;
        left = static_cast<std::uint8_t>(left << 1U);
        if (high_bit) left ^= 0x1dU;
        right = static_cast<std::uint8_t>(right >> 1U);
    }
    return result;
}

std::uint8_t gf_power(std::uint8_t value, unsigned exponent) {
    std::uint8_t result = 1;
    while (exponent > 0) {
        if ((exponent & 1U) != 0) result = gf_multiply(result, value);
        value = gf_multiply(value, value);
        exponent >>= 1U;
    }
    return result;
}

std::optional<Matrix> invert(Matrix matrix) {
    const auto size = matrix.size();
    if (size == 0) return Matrix{};
    for (const auto& row : matrix) {
        if (row.size() != size) return std::nullopt;
    }

    Matrix augmented(size, std::vector<std::uint8_t>(size * 2, 0));
    for (std::size_t row = 0; row < size; ++row) {
        std::copy(matrix[row].begin(), matrix[row].end(), augmented[row].begin());
        augmented[row][size + row] = 1;
    }

    for (std::size_t column = 0; column < size; ++column) {
        auto pivot = column;
        while (pivot < size && augmented[pivot][column] == 0) ++pivot;
        if (pivot == size) return std::nullopt;
        if (pivot != column) std::swap(augmented[pivot], augmented[column]);

        const auto inverse = gf_power(augmented[column][column], 254);
        for (auto& value : augmented[column]) {
            value = gf_multiply(value, inverse);
        }
        for (std::size_t row = 0; row < size; ++row) {
            if (row == column) continue;
            const auto factor = augmented[row][column];
            if (factor == 0) continue;
            for (std::size_t item = 0; item < size * 2; ++item) {
                augmented[row][item] ^=
                    gf_multiply(factor, augmented[column][item]);
            }
        }
    }

    Matrix result(size, std::vector<std::uint8_t>(size, 0));
    for (std::size_t row = 0; row < size; ++row) {
        std::copy(
            augmented[row].begin() + static_cast<std::ptrdiff_t>(size),
            augmented[row].end(), result[row].begin());
    }
    return result;
}

const std::array<std::array<std::uint8_t, kFecDataShards>, kFecParityShards>&
parity_matrix() {
    static const auto matrix = [] {
        constexpr std::size_t total_shards = kFecDataShards + kFecParityShards;
        Matrix vandermonde(total_shards,
                           std::vector<std::uint8_t>(kFecDataShards, 0));
        for (std::size_t row = 0; row < total_shards; ++row) {
            const auto point = static_cast<std::uint8_t>(row + 1);
            for (std::size_t column = 0; column < kFecDataShards; ++column) {
                vandermonde[row][column] = gf_power(
                    point, static_cast<unsigned>(column));
            }
        }

        Matrix top(kFecDataShards);
        for (std::size_t row = 0; row < kFecDataShards; ++row) {
            top[row] = vandermonde[row];
        }
        const auto top_inverse = invert(std::move(top)).value();

        std::array<std::array<std::uint8_t, kFecDataShards>,
                   kFecParityShards> result{};
        for (std::size_t parity = 0; parity < kFecParityShards; ++parity) {
            const auto source_row = kFecDataShards + parity;
            for (std::size_t column = 0; column < kFecDataShards; ++column) {
                std::uint8_t value = 0;
                for (std::size_t inner = 0; inner < kFecDataShards; ++inner) {
                    value ^= gf_multiply(
                        vandermonde[source_row][inner],
                        top_inverse[inner][column]);
                }
                result[parity][column] = value;
            }
        }
        return result;
    }();
    return matrix;
}

}  // namespace

bool encode_fec_parity(
    const FecDataPayloads& data,
    std::uint8_t parity_index,
    std::span<std::byte> output) {
    if (parity_index >= kFecParityShards || output.size() != kPayloadBytes) {
        return false;
    }
    for (const auto payload : data) {
        if (payload.size() != kPayloadBytes) return false;
    }

    std::fill(output.begin(), output.end(), std::byte{0});
    const auto& coefficients = parity_matrix()[parity_index];
    for (std::size_t shard = 0; shard < kFecDataShards; ++shard) {
        const auto coefficient = coefficients[shard];
        for (std::size_t index = 0; index < output.size(); ++index) {
            const auto value = std::to_integer<std::uint8_t>(data[shard][index]);
            output[index] ^= static_cast<std::byte>(
                gf_multiply(coefficient, value));
        }
    }
    return true;
}

std::optional<std::vector<RecoveredFecShard>> recover_fec_data(
    const std::array<std::optional<std::vector<std::byte>>, kFecDataShards>& data,
    const std::array<std::optional<std::vector<std::byte>>, kFecParityShards>& parity) {
    std::vector<std::size_t> missing;
    for (std::size_t index = 0; index < data.size(); ++index) {
        if (!data[index]) missing.push_back(index);
        else if (data[index]->size() != kPayloadBytes) return std::nullopt;
    }
    if (missing.empty()) return std::vector<RecoveredFecShard>{};
    if (missing.size() > kFecParityShards) return std::nullopt;

    std::vector<std::size_t> parity_rows;
    for (std::size_t index = 0;
         index < parity.size() && parity_rows.size() < missing.size(); ++index) {
        if (parity[index]) {
            if (parity[index]->size() != kPayloadBytes) return std::nullopt;
            parity_rows.push_back(index);
        }
    }
    if (parity_rows.size() < missing.size()) return std::nullopt;

    Matrix coefficients(missing.size(),
                        std::vector<std::uint8_t>(missing.size(), 0));
    for (std::size_t row = 0; row < missing.size(); ++row) {
        for (std::size_t column = 0; column < missing.size(); ++column) {
            coefficients[row][column] =
                parity_matrix()[parity_rows[row]][missing[column]];
        }
    }
    const auto inverse = invert(std::move(coefficients));
    if (!inverse) return std::nullopt;

    std::vector<RecoveredFecShard> recovered;
    recovered.reserve(missing.size());
    for (const auto index : missing) {
        recovered.push_back({
            .data_index = static_cast<std::uint8_t>(index),
            .payload = std::vector<std::byte>(kPayloadBytes, std::byte{0}),
        });
    }

    std::vector<std::uint8_t> right_hand_side(missing.size(), 0);
    for (std::size_t byte_index = 0; byte_index < kPayloadBytes; ++byte_index) {
        for (std::size_t row = 0; row < parity_rows.size(); ++row) {
            auto value = std::to_integer<std::uint8_t>(
                (*parity[parity_rows[row]])[byte_index]);
            for (std::size_t data_index = 0;
                 data_index < kFecDataShards; ++data_index) {
                if (!data[data_index]) continue;
                value ^= gf_multiply(
                    parity_matrix()[parity_rows[row]][data_index],
                    std::to_integer<std::uint8_t>((*data[data_index])[byte_index]));
            }
            right_hand_side[row] = value;
        }
        for (std::size_t output_index = 0;
             output_index < recovered.size(); ++output_index) {
            std::uint8_t value = 0;
            for (std::size_t row = 0; row < parity_rows.size(); ++row) {
                value ^= gf_multiply(
                    (*inverse)[output_index][row], right_hand_side[row]);
            }
            recovered[output_index].payload[byte_index] =
                static_cast<std::byte>(value);
        }
    }
    return recovered;
}

}  // namespace multipoint::protocol
