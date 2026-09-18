#pragma once

#include <cstdint>

namespace multipoint::util {

inline bool sequence_before(std::uint32_t lhs, std::uint32_t rhs) {
    return static_cast<std::int32_t>(lhs - rhs) < 0;
}

inline bool sequence_after(std::uint32_t lhs, std::uint32_t rhs) {
    return sequence_before(rhs, lhs);
}

}  // namespace multipoint::util
