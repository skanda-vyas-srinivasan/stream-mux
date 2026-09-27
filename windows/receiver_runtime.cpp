#include "receiver_runtime.h"

#ifndef _WIN32
#error "receiver_runtime.cpp is only for Windows"
#endif

#include "wasapi_output.h"
#include "windows_identity.h"

#include "multipoint/network/udp_socket.h"
#include "multipoint/protocol/audio_packet.h"
#include "multipoint/protocol/session.h"
#include "multipoint/protocol/session_crypto.h"
#include "multipoint/transport/receiver_engine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>

namespace soundmux::windows {
namespace {

std::uint64_t now_ns() {
  return static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count());
}

} // namespace

struct ReceiverRuntime::Impl {
  Impl(ReceiverConfig input, PairingHandler handler)
      : config(std::move(input)), pairing_handler(std::move(handler)),
        device_id(identity.load_or_create_device_id()),
        device_key(identity.load_or_create_device_key()), socket(config.port),
        transport({
            .reorder_packets =
                std::clamp<std::size_t>(config.latency_ms / 5, 3, 24),
            .capacity_packets = 512,
            .hard_resync_gap_packets = 20,
            .maximum_fec_groups = 128,
        }),
        target_frames(std::max<std::size_t>(
            multipoint::protocol::kFramesPerPacket,
            static_cast<std::size_t>(multipoint::protocol::kSampleRate) *
                config.latency_ms / 1'000)) {
    if (config.device_name.empty()) {
      throw std::invalid_argument("receiver name is empty");
    }
    running.store(true, std::memory_order_release);
    network_thread = std::thread([this] { network_loop(); });
    pump_thread = std::thread([this] { pump_loop(); });
  }

  ~Impl() { stop(); }

  void stop() {
    if (!running.exchange(false, std::memory_order_acq_rel))
      return;
    if (network_thread.joinable())
      network_thread.join();
    if (pump_thread.joinable())
      pump_thread.join();
    output.set_playing(false);
  }

  void send_plain(const multipoint::protocol::SessionMessage &message,
                  const multipoint::network::UdpEndpoint &endpoint,
                  std::uint16_t port) {
    socket.send_to(multipoint::protocol::serialize_session(message), endpoint,
                   port);
  }

  void send_welcome(const multipoint::network::UdpEndpoint &endpoint,
                    std::uint16_t port) {
    if (!secrets)
      return;
    send_plain(
        {
            .type = multipoint::protocol::SessionMessageType::welcome,
            .fields =
                {
                    {"receiver_id", device_id},
                    {"receiver_name", config.device_name},
                    {"platform", "windows"},
                    {"protocol", "3"},
                    {"session", "3"},
                    {"public_key",
                     multipoint::protocol::hex_encode(device_key.public_key)},
                    {"server_nonce",
                     multipoint::protocol::hex_encode(server_nonce)},
                    {"proof",
                     multipoint::protocol::hex_encode(secrets->welcome_proof)},
                    {"heartbeat_ms", "1000"},
                    {"capabilities", "audio,latency,pairing,encryption,volume"},
                },
        },
        endpoint, port);
  }

  void reject(const std::string &reason,
              const multipoint::network::UdpEndpoint &endpoint,
              std::uint16_t port) {
    send_plain(
        {
            .type = multipoint::protocol::SessionMessageType::rejected,
            .fields = {{"reason", reason}},
        },
        endpoint, port);
  }

  void handle_hello(const multipoint::protocol::SessionMessage &message,
                    const multipoint::network::UdpEndpoint &endpoint) {
    const auto &fields = message.fields;
    if (!fields.contains("device_id") || !fields.contains("name") ||
        !fields.contains("public_key") || !fields.contains("client_nonce") ||
        !fields.contains("reply_port") || !fields.contains("session") ||
        fields.at("session") != "3") {
      return;
    }
    std::size_t parsed_characters = 0;
    const int parsed_port =
        std::stoi(fields.at("reply_port"), &parsed_characters);
    if (parsed_characters != fields.at("reply_port").size() ||
        parsed_port < 1 || parsed_port > 65'535) {
      return;
    }
    const auto reply_port = static_cast<std::uint16_t>(parsed_port);
    multipoint::protocol::CryptoKey sender_key{};
    multipoint::protocol::CryptoNonce new_client_nonce{};
    if (!multipoint::protocol::hex_decode(fields.at("public_key"),
                                          sender_key) ||
        !multipoint::protocol::hex_decode(fields.at("client_nonce"),
                                          new_client_nonce)) {
      return;
    }
    const auto &sender_id = fields.at("device_id");
    if (secrets && sender_id == active_sender_id &&
        sender_key == active_sender_key && new_client_nonce == client_nonce) {
      active_reply_port = reply_port;
      send_welcome(endpoint, reply_port);
      return;
    }

    const auto trusted = identity.trusted_key(sender_id);
    const bool pair_requested =
        fields.contains("pair_requested") && fields.at("pair_requested") == "1";
    if (trusted && *trusted != sender_key) {
      reject("Sender security key changed", endpoint, reply_port);
      return;
    }
    multipoint::protocol::CryptoNonce new_server_nonce{};
    if (!multipoint::protocol::secure_random(new_server_nonce))
      return;
    if (!trusted || pair_requested) {
      const auto code =
          multipoint::protocol::pairing_code(sender_key, device_key.public_key);
      send_plain(
          {
              .type = multipoint::protocol::SessionMessageType::pair_required,
              .fields =
                  {
                      {"receiver_id", device_id},
                      {"receiver_name", config.device_name},
                      {"platform", "windows"},
                      {"public_key",
                       multipoint::protocol::hex_encode(device_key.public_key)},
                      {"server_nonce",
                       multipoint::protocol::hex_encode(new_server_nonce)},
                      {"code", code},
                  },
          },
          endpoint, reply_port);
      if (!pairing_handler || !pairing_handler(fields.at("name"), code)) {
        reject("Pairing declined", endpoint, reply_port);
        return;
      }
      identity.remember_sender(sender_id, fields.at("name"), sender_key);
    }

    const auto new_secrets = multipoint::protocol::derive_session_secrets(
        device_key.secret, sender_key, sender_key, device_key.public_key,
        new_client_nonce, new_server_nonce);
    active_sender_id = sender_id;
    active_sender_key = sender_key;
    client_nonce = new_client_nonce;
    server_nonce = new_server_nonce;
    active_reply_port = reply_port;
    secrets = new_secrets;
    inbound = std::make_unique<multipoint::protocol::SessionCipher>(
        new_secrets.sender_to_receiver_key, new_secrets.sender_nonce_prefix);
    outbound = std::make_unique<multipoint::protocol::SessionCipher>(
        new_secrets.receiver_to_sender_key, new_secrets.receiver_nonce_prefix);
    {
      std::lock_guard lock(state_mutex);
      sender_name = fields.at("name");
      connected = true;
    }
    last_activity_ns.store(now_ns(), std::memory_order_relaxed);
    transport.reset();
    output.discard();
    output.set_playing(false);
    send_welcome(endpoint, reply_port);
  }

  void network_loop() {
    std::array<std::byte, 2'048> datagram{};
    while (running.load(std::memory_order_acquire)) {
      try {
        multipoint::network::UdpEndpoint endpoint;
        const auto size = socket.receive_from(datagram, endpoint);
        if (size == 0)
          continue;
        const auto raw = std::span<const std::byte>(datagram.data(), size);
        const auto message = multipoint::protocol::deserialize_session(raw);
        if (message.valid &&
            message.message.type ==
                multipoint::protocol::SessionMessageType::hello) {
          handle_hello(message.message, endpoint);
          continue;
        }
        if (!inbound)
          continue;
        auto opened = inbound->decrypt(raw);
        if (!opened.valid)
          continue;
        const auto control =
            multipoint::protocol::deserialize_session(opened.plaintext);
        if (control.valid &&
            control.message.type ==
                multipoint::protocol::SessionMessageType::ping) {
          last_activity_ns.store(now_ns(), std::memory_order_relaxed);
          if (!outbound || active_reply_port == 0)
            continue;
          const auto pong = multipoint::protocol::serialize_session({
              .type = multipoint::protocol::SessionMessageType::pong,
              .fields =
                  {
                      {"receiver_id", device_id},
                      {"counter", control.message.fields.contains("counter")
                                      ? control.message.fields.at("counter")
                                      : "0"},
                  },
          });
          socket.send_to(outbound->encrypt(pong), endpoint, active_reply_port);
          continue;
        }
        const auto arrival = now_ns();
        const auto result = transport.ingest(opened.plaintext, arrival);
        if (result.accepted) {
          last_activity_ns.store(arrival, std::memory_order_relaxed);
        }
        if (result.hard_resync) {
          reset_audio.store(true, std::memory_order_release);
        }
      } catch (const std::exception &) {
        if (!running.load(std::memory_order_acquire))
          break;
      }
    }
  }

  void pump_loop() {
    std::array<float, multipoint::protocol::kSamplesPerPacket> silence{};
    std::optional<std::chrono::steady_clock::time_point> missing_since;
    while (running.load(std::memory_order_acquire)) {
      if (reset_audio.exchange(false, std::memory_order_acq_rel)) {
        output.discard();
        output.set_playing(false);
        missing_since.reset();
      }
      if (output.available_to_write() >=
              multipoint::protocol::kFramesPerPacket &&
          output.available_to_read() < target_frames * 2) {
        auto result = transport.pop(false);
        if (result.status == multipoint::jitter::PopStatus::not_ready) {
          const auto current = transport.snapshot();
          if (current.started && current.depth > 0) {
            const auto now = std::chrono::steady_clock::now();
            if (!missing_since)
              missing_since = now;
            if (now - *missing_since >= std::chrono::milliseconds(30)) {
              result = transport.pop(true);
            }
          } else if (current.started && current.depth == 0 &&
                     output.available_to_read() == 0) {
            transport.rebuffer();
            output.set_playing(false);
          }
        }
        if (result.packet) {
          missing_since.reset();
          output.write(result.packet->interleaved_samples.data(),
                       multipoint::protocol::kFramesPerPacket);
        } else if (result.status == multipoint::jitter::PopStatus::missing) {
          output.write(silence.data(), multipoint::protocol::kFramesPerPacket);
          concealed.fetch_add(1, std::memory_order_relaxed);
        }
        if (!output.playing() && output.available_to_read() >= target_frames) {
          output.set_playing(true);
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  }

  ReceiverSnapshot snapshot() const {
    const auto stats = transport.snapshot();
    std::lock_guard lock(state_mutex);
    const auto activity = last_activity_ns.load(std::memory_order_relaxed);
    const bool session_alive =
        connected && activity != 0 && now_ns() - activity < 4'000'000'000ULL;
    return {
        .connected = session_alive,
        .playing = session_alive && output.playing(),
        .sender_name = sender_name,
        .packets_received = stats.jitter.packets_received,
        .packets_lost = stats.jitter.packets_lost,
        .packets_reordered = stats.jitter.packets_reordered,
        .late_packets = stats.jitter.late_packets,
        .fec_recovered = stats.fec_recovered,
        .concealed_packets = concealed.load(std::memory_order_relaxed),
        .audio_underruns = output.underruns(),
        .hard_resyncs = stats.hard_resyncs,
        .malformed_packets = stats.malformed_packets,
        .max_arrival_gap_ns = stats.max_arrival_gap_ns,
        .arrival_gap_events = stats.arrival_gap_events,
        .jitter_depth = stats.depth,
        .buffered_frames = output.available_to_read(),
        .trusted_senders = identity.trusted_sender_count(),
    };
  }

  ReceiverConfig config;
  PairingHandler pairing_handler;
  IdentityStore identity;
  std::string device_id;
  multipoint::protocol::DeviceKeyPair device_key;
  multipoint::network::UdpReceiver socket;
  multipoint::transport::ReceiverEngine transport;
  const std::size_t target_frames;
  WasapiOutput output;
  std::atomic<bool> running{false};
  std::thread network_thread;
  std::thread pump_thread;
  std::optional<multipoint::protocol::SessionSecrets> secrets;
  std::unique_ptr<multipoint::protocol::SessionCipher> inbound;
  std::unique_ptr<multipoint::protocol::SessionCipher> outbound;
  std::string active_sender_id;
  multipoint::protocol::CryptoKey active_sender_key{};
  multipoint::protocol::CryptoNonce client_nonce{};
  multipoint::protocol::CryptoNonce server_nonce{};
  std::uint16_t active_reply_port = 0;
  mutable std::mutex state_mutex;
  std::string sender_name;
  bool connected = false;
  std::atomic<std::uint64_t> concealed{0};
  std::atomic<std::uint64_t> last_activity_ns{0};
  std::atomic<bool> reset_audio{false};
};

ReceiverRuntime::ReceiverRuntime(ReceiverConfig config,
                                 PairingHandler pairing_handler)
    : impl_(std::make_unique<Impl>(std::move(config),
                                   std::move(pairing_handler))) {}

ReceiverRuntime::~ReceiverRuntime() = default;

void ReceiverRuntime::stop() {
  if (impl_)
    impl_->stop();
}

void ReceiverRuntime::set_volume(float volume) {
  if (impl_)
    impl_->output.set_volume(volume);
}

ReceiverSnapshot ReceiverRuntime::snapshot() const {
  return impl_ ? impl_->snapshot() : ReceiverSnapshot{};
}

} // namespace soundmux::windows
