#include "windows_identity.h"

#ifndef _WIN32
#error "windows_identity.cpp is only for Windows"
#endif

#include <wincrypt.h>
#include <windows.h>

#include <array>
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace soundmux::windows {
namespace {

constexpr const char *kRegistryPath = "Software\\SoundMux\\Receiver";
constexpr const char *kDeviceIDValue = "DeviceID";
constexpr const char *kDeviceKeyValue = "ProtectedDeviceKey";
constexpr const char *kTrustedPrefix = "TrustedKey.";
constexpr const char *kTrustedNamePrefix = "TrustedName.";

class RegistryKey {
public:
  RegistryKey() {
    const auto status = RegCreateKeyExA(
        HKEY_CURRENT_USER, kRegistryPath, 0, nullptr, REG_OPTION_NON_VOLATILE,
        KEY_READ | KEY_WRITE, nullptr, &key_, nullptr);
    if (status != ERROR_SUCCESS) {
      throw std::runtime_error("open SoundMux registry key: " +
                               std::to_string(status));
    }
  }

  ~RegistryKey() {
    if (key_)
      RegCloseKey(key_);
  }

  RegistryKey(const RegistryKey &) = delete;
  RegistryKey &operator=(const RegistryKey &) = delete;

  [[nodiscard]] HKEY get() const { return key_; }

private:
  HKEY key_ = nullptr;
};

std::string sender_value_name(const char *prefix,
                              const std::string &sender_id) {
  std::string encoded;
  encoded.reserve(sender_id.size() * 2);
  constexpr char digits[] = "0123456789abcdef";
  for (const auto character : sender_id) {
    const auto value = static_cast<unsigned char>(character);
    encoded.push_back(digits[value >> 4U]);
    encoded.push_back(digits[value & 0x0fU]);
  }
  return std::string(prefix) + encoded;
}

std::optional<std::string> read_string(HKEY key, const std::string &name) {
  DWORD type = 0;
  DWORD bytes = 0;
  auto status =
      RegQueryValueExA(key, name.c_str(), nullptr, &type, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND)
    return std::nullopt;
  if (status != ERROR_SUCCESS || type != REG_SZ || bytes == 0) {
    throw std::runtime_error("read SoundMux registry string");
  }
  std::vector<char> buffer(bytes, '\0');
  status = RegQueryValueExA(key, name.c_str(), nullptr, &type,
                            reinterpret_cast<BYTE *>(buffer.data()), &bytes);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("read SoundMux registry string data");
  }
  if (!buffer.empty() && buffer.back() == '\0')
    buffer.pop_back();
  return std::string(buffer.begin(), buffer.end());
}

void write_string(HKEY key, const std::string &name, const std::string &value) {
  const auto bytes = static_cast<DWORD>(value.size() + 1);
  const auto status =
      RegSetValueExA(key, name.c_str(), 0, REG_SZ,
                     reinterpret_cast<const BYTE *>(value.c_str()), bytes);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("write SoundMux registry string");
  }
}

std::optional<std::vector<std::byte>> read_binary(HKEY key, const char *name) {
  DWORD type = 0;
  DWORD bytes = 0;
  auto status = RegQueryValueExA(key, name, nullptr, &type, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND)
    return std::nullopt;
  if (status != ERROR_SUCCESS || type != REG_BINARY || bytes == 0) {
    throw std::runtime_error("read SoundMux registry data");
  }
  std::vector<std::byte> buffer(bytes);
  status = RegQueryValueExA(key, name, nullptr, &type,
                            reinterpret_cast<BYTE *>(buffer.data()), &bytes);
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("read SoundMux registry binary data");
  }
  buffer.resize(bytes);
  return buffer;
}

void write_binary(HKEY key, const char *name,
                  const std::vector<std::byte> &value) {
  const auto status = RegSetValueExA(
      key, name, 0, REG_BINARY, reinterpret_cast<const BYTE *>(value.data()),
      static_cast<DWORD>(value.size()));
  if (status != ERROR_SUCCESS) {
    throw std::runtime_error("write SoundMux registry data");
  }
}

std::vector<std::byte> protect(const multipoint::protocol::CryptoKey &secret) {
  DATA_BLOB input{
      static_cast<DWORD>(secret.size()),
      reinterpret_cast<BYTE *>(const_cast<std::byte *>(secret.data())),
  };
  DATA_BLOB output{};
  if (!CryptProtectData(&input, L"SoundMux receiver identity", nullptr, nullptr,
                        nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    throw std::runtime_error("protect SoundMux receiver identity");
  }
  std::vector<std::byte> result(
      reinterpret_cast<std::byte *>(output.pbData),
      reinterpret_cast<std::byte *>(output.pbData + output.cbData));
  LocalFree(output.pbData);
  return result;
}

multipoint::protocol::CryptoKey
unprotect(const std::vector<std::byte> &protected_key) {
  DATA_BLOB input{
      static_cast<DWORD>(protected_key.size()),
      reinterpret_cast<BYTE *>(const_cast<std::byte *>(protected_key.data())),
  };
  DATA_BLOB output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    throw std::runtime_error("unprotect SoundMux receiver identity");
  }
  if (output.cbData != multipoint::protocol::kCryptoKeyBytes) {
    LocalFree(output.pbData);
    throw std::runtime_error("stored SoundMux receiver identity is invalid");
  }
  multipoint::protocol::CryptoKey secret{};
  std::memcpy(secret.data(), output.pbData, secret.size());
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return secret;
}

} // namespace

std::string IdentityStore::load_or_create_device_id() const {
  RegistryKey registry;
  if (const auto stored = read_string(registry.get(), kDeviceIDValue)) {
    return *stored;
  }
  std::array<std::byte, 16> random{};
  if (!multipoint::protocol::secure_random(random)) {
    throw std::runtime_error("generate SoundMux receiver ID");
  }
  const auto id = multipoint::protocol::hex_encode(random);
  write_string(registry.get(), kDeviceIDValue, id);
  return id;
}

multipoint::protocol::DeviceKeyPair
IdentityStore::load_or_create_device_key() const {
  RegistryKey registry;
  if (const auto stored = read_binary(registry.get(), kDeviceKeyValue)) {
    auto secret = unprotect(*stored);
    return {secret, multipoint::protocol::public_key_for(secret)};
  }
  auto pair = multipoint::protocol::generate_device_key_pair();
  write_binary(registry.get(), kDeviceKeyValue, protect(pair.secret));
  return pair;
}

std::optional<multipoint::protocol::CryptoKey>
IdentityStore::trusted_key(const std::string &sender_id) const {
  RegistryKey registry;
  const auto value =
      read_string(registry.get(), sender_value_name(kTrustedPrefix, sender_id));
  if (!value)
    return std::nullopt;
  multipoint::protocol::CryptoKey key{};
  if (!multipoint::protocol::hex_decode(*value, key)) {
    throw std::runtime_error("stored SoundMux trusted key is invalid");
  }
  return key;
}

void IdentityStore::remember_sender(
    const std::string &sender_id, const std::string &sender_name,
    const multipoint::protocol::CryptoKey &public_key) const {
  RegistryKey registry;
  write_string(registry.get(), sender_value_name(kTrustedPrefix, sender_id),
               multipoint::protocol::hex_encode(public_key));
  write_string(registry.get(), sender_value_name(kTrustedNamePrefix, sender_id),
               sender_name);
}

std::size_t IdentityStore::trusted_sender_count() const {
  RegistryKey registry;
  DWORD values = 0;
  DWORD maximum_name = 0;
  if (RegQueryInfoKeyA(registry.get(), nullptr, nullptr, nullptr, nullptr,
                       nullptr, nullptr, &values, &maximum_name, nullptr,
                       nullptr, nullptr) != ERROR_SUCCESS) {
    return 0;
  }
  std::vector<char> name(static_cast<std::size_t>(maximum_name) + 2, '\0');
  std::size_t count = 0;
  for (DWORD index = 0; index < values; ++index) {
    DWORD length = static_cast<DWORD>(name.size());
    if (RegEnumValueA(registry.get(), index, name.data(), &length, nullptr,
                      nullptr, nullptr, nullptr) != ERROR_SUCCESS) {
      continue;
    }
    const std::string value_name(name.data(), length);
    if (value_name.starts_with(kTrustedPrefix))
      ++count;
  }
  return count;
}

} // namespace soundmux::windows
