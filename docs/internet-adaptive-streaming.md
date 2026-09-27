# Internet and adaptive streaming

## Current checkpoint

The `feature/internet-adaptive-streaming` branch contains the first portable
pieces of the internet path:

- an `SMR1` relay envelope carrying an unguessable 128-bit route capability;
- a standalone UDP relay that maps sender and receiver endpoints, expires idle
  routes, and forwards opaque payloads without decrypting them;
- relay framing validation and size limits that keep existing audio datagrams
  below the normal network MTU;
- an adaptive controller that observes packet loss, arrival gaps, round-trip
  time, and audio underruns; and
- hysteresis and cooldown behavior so a single bad interval cannot make the
  stream oscillate between profiles.

The relay payload is the existing SoundMux session or encrypted `SME1`
datagram. Pairing, device-key verification, authenticated encryption, and
replay protection remain end to end; the relay is not trusted with audio keys.

This checkpoint is not yet an app-usable internet route. The platform adapters
still need a bidirectional relay socket, route invitation UI, receiver
keepalives, and fallback integration with the connection planner. The adaptive
decision also needs protocol negotiation before it can safely change live
receiver buffering or FEC parameters.

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

1. Add a portable bidirectional UDP channel and relay client adapter.
2. Exercise sender → relay → receiver session pairing in an automated local
   integration test.
3. Add receiver feedback fields for loss, jitter, buffered duration, and
   underruns to authenticated heartbeat replies.
4. Negotiate adaptive profile changes and apply them at safe rebuffer/FEC group
   boundaries.
5. Add route-invitation creation and acceptance to the Mac and iPhone apps.
6. Deploy a rate-limited relay on a public test host and perform a real
   cross-network listening test.
7. Evaluate Opus before mobile-data use. The current stereo PCM plus FEC path is
   appropriate for validation but consumes substantially more bandwidth than a
   compressed internet mode.
