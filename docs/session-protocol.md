# SoundMux cross-platform session protocol

SoundMux separates discovery, session control, audio transport, and platform
audio I/O. Apple devices currently use Bonjour, but Bonjour is not required by
the wire protocol. A Windows adapter can use DNS-SD/mDNS, a manual address, or a
future directory service and then speak the same UDP session protocol.

## Receiver discovery

Local receivers advertise `_soundmux._udp` with these TXT fields:

| Key | Meaning | Example |
| --- | --- | --- |
| `id` | Stable receiver UUID | `B78F...37A2` |
| `name` | Human device name | `Studio iPhone` |
| `platform` | Adapter platform | `ios`, `macos`, `windows` |
| `protocol` | Audio packet protocol | `3` |
| `session` | Session protocol | `3` |
| `capabilities` | Comma-separated features | `audio,media,pairing,volume` |
| `pairing` | Optional trust policy | `approval`, `open` |
| `security` | Session protection | `x25519+xchacha20poly1305` |
| `public_key` | Receiver X25519 public key | 64 hex characters |

The instance name is presentation only. Senders remember `id`, never the
Bonjour instance name or current IP address. Duplicate names are valid.

## Session messages

Session messages are UTF-8 UDP datagrams on the receiver's audio port:

```text
SOUNDMUX/2|TYPE|key=percent-encoded-value|...
```

Fields are emitted in lexical order, keys contain ASCII letters, digits, and
underscores, and datagrams are limited to 1,200 bytes. The portable C++ codec is
in `multipoint/protocol/session.h`.

`SOUNDMUX/2` is the text-control framing marker. The current negotiated session
version is 3.

Connection sequence:

```text
sender                                  receiver
  | -------- HELLO ----------------------> |
  | <------- PAIR_REQUIRED (first use) --- |
  |       user confirms code on receiver  |
  | <------- WELCOME --------------------- |
  | -------- audio + FEC ----------------> |
  | -------- PING (every second) --------> |
  | <------- PONG ------------------------ |
```

`HELLO` includes `device_id`, `name`, `platform`, the sender `public_key`, a
fresh `client_nonce`, `reply_port`, `protocol`, `session`, and `pair_requested`.
For a connected UDP socket, `reply_port=0` asks the receiver to reply to the
source endpoint of the HELLO datagram. A nonzero value overrides that source
port for clients that listen for controls on a separate socket.
The last field lets a sender that deliberately forgot a device request a fresh
comparison even when the receiver still has one-sided trust. The receiver
answers with its public key and a fresh `server_nonce`. Both endpoints derive
the displayed six-digit comparison code locally from the ordered public keys.
After the user confirms the matching code, each endpoint pins the other public
key to its stable device ID.

X25519 produces the shared secret. BLAKE2b binds it to both public keys and
nonces and derives separate directional keys. `WELCOME` contains a keyed proof
of the transcript. After `WELCOME`, audio, PING/PONG, and media commands must be
inside `SME1` XChaCha20-Poly1305 authenticated envelopes. The authenticated
counter and sliding replay window allow normal UDP reordering while rejecting
duplicates, old datagrams, tampering, and plaintext traffic.

Apple long-term private keys are stored in Keychain. Monocypher 4.0.3 supplies
the portable primitives shared by Apple and future Windows adapters. Session
v3 does not yet provide forward secrecy: compromise of a long-term private key
can expose previously captured sessions. A later reviewed handshake can add
authenticated ephemeral keys without changing the envelope.

Three missed heartbeat windows make the session unavailable and trigger
remembered-device reconnection.

## Connection routes

`multipoint/network/connection_plan.h` models local discovery, remembered
direct addresses, rendezvous-provided direct candidates, and relay candidates.
Routes are tried in that order and duplicate endpoints are removed. Only local
and remembered routes are populated today; the hosted rendezvous and relay
services will feed the same planner later.

## Platform adapters

- iOS uses `NWListener`, `AVAudioEngine`, and an AirPlay route picker.
- macOS sending uses a Core Audio process tap and IOProc. The CLI receiver uses
  the default output AudioUnit and advertises a Mac receiver for Mac-to-Mac
  tests.
- Windows uses the portable C++ sender/receiver/session code and the Winsock
  backend. The Sonexis APO must not perform networking in `audiodg.exe`; it
  should copy post-DSP samples into a lock-free shared ring consumed by a
  separate SoundMux worker. Receiving should render through WASAPI from that
  worker process.

All adapters normalize to the existing 48 kHz stereo PCM16 packet format before
entering the portable transport engine.
