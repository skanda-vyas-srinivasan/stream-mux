#pragma once

#include "multipoint/protocol/session_crypto.h"

#include <cstddef>
#include <optional>
#include <string>

namespace soundmux::windows {

class IdentityStore {
public:
  [[nodiscard]] std::string load_or_create_device_id() const;
  [[nodiscard]] multipoint::protocol::DeviceKeyPair
  load_or_create_device_key() const;
  [[nodiscard]] std::optional<multipoint::protocol::CryptoKey>
  trusted_key(const std::string &sender_id) const;
  void remember_sender(const std::string &sender_id,
                       const std::string &sender_name,
                       const multipoint::protocol::CryptoKey &public_key) const;
  [[nodiscard]] std::size_t trusted_sender_count() const;
};

} // namespace soundmux::windows
