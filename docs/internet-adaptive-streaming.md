# Internet and adaptive streaming

## Current checkpoint

The `feature/internet-adaptive-streaming` branch contains the first portable
pieces of the internet path:

- an `SMR1` relay envelope carrying an unguessable 128-bit route capability;
- a standalone UDP relay that maps sender and receiver endpoints, expires idle
  routes, and forwards opaque payloads without decrypting them;
- a portable bidirectional relay channel that keeps registration, keepalives,
  audio datagrams, and replies on one UDP socket so the same NAT mapping is
  used in both directions;
- Mac sender and iPhone receiver integration, with an explicit internet-relay
  mode and a shared private route code;
- relay framing validation and size limits that keep existing audio datagrams
  below the normal network MTU;
- authenticated receiver-health feedback plus an adaptive controller that
  observes packet loss, round-trip time, and audio underruns;
- hysteresis and cooldown behavior so a single bad interval cannot make the
  stream oscillate between profiles.

The relay payload is the existing SoundMux session or encrypted `SME1`
datagram. Pairing, device-key verification, authenticated encryption, and
replay protection remain end to end; the relay is not trusted with audio keys.

The Mac sender and iPhone receiver can now use a manually configured relay. A
loopback integration test proves bidirectional delivery of session handshakes
and authenticated encrypted payloads, and both platform targets compile with
the relay path. A public relay has not been deployed or physically validated
across two networks yet. Windows, route
invitations, automatic direct-to-relay fallback, compression, and production
relay abuse controls remain future work.

Adaptive latency is enabled for internet-relay sessions. Profile messages are
authenticated inside the end-to-end encrypted session and the receiver applies
them at an explicit rebuffer boundary. FEC remains at the protocol's fixed
10+5 layout; the controller must not change parity until a future protocol
version negotiates that change safely.

## Manual test setup

Build the project, generate a private route, and run the relay on a host whose
UDP port is reachable from both devices:

```sh
./build/core/soundmux_relay --generate-route
./build/core/soundmux_relay 48200
```

On the iPhone, enable **Internet relay**, enter the relay host, UDP port, and
generated 32-character route code, then restart the receiver. On the Mac,
enable **Connect through an internet relay**, enter the same values, and
connect. Treat the route code like a password.

## Adaptive profiles

| Profile | Target latency | Planned parity | Intended use |
| --- | ---: | ---: | --- |
| Responsive | 60 ms | 2 shards | Stable LAN or excellent direct internet |
| Balanced | 100 ms | 3 shards | Default internet route |
| Resilient | 180 ms | 5 shards | Lossy or bursty network |

Two consecutive bad intervals are required to increase protection. Twenty
consecutive good intervals are required to reduce it, with a cooldown after
each transition. This intentionally favors uninterrupted audio over rapidly
chasing a low latency number.

## Relay threat model

The route capability is a bearer secret and must be generated with the system
cryptographic random source. Device IDs are never sufficient relay
credentials. A relay operator can observe timing, addresses, and datagram
sizes, and can drop traffic, but cannot authenticate as a paired endpoint or
decrypt audio. Production deployment still requires per-source rate limits,
route quotas, abuse controls, operational monitoring, and protection against
UDP amplification.

## Remaining milestones

1. Integrate the portable relay channel with Windows and the remaining
   sender/receiver directions.
2. Add interval arrival-gap feedback and expose adaptive profile history in
   connection diagnostics.
3. Negotiate variable FEC in a future protocol version and apply changes only
   at an agreed group boundary.
4. Add route-invitation creation and acceptance to the Mac and iPhone apps.
5. Deploy a rate-limited relay on a public test host and perform a real
   cross-network listening test.
6. Evaluate Opus before mobile-data use. The current stereo PCM plus FEC path is
   appropriate for validation but consumes substantially more bandwidth than a
   compressed internet mode.
