# Multipoint Project Context

This document is the handoff point for the next session.

## Project goal

Multipoint is intended to become a cross-platform, peer-to-peer multi-device audio-routing system. The first and only active milestone is:

```text
iPhone ScreenCaptureKit audio -> PCM packets -> UDP/LAN -> Mac jitter buffer
-> CoreAudio output -> Mac speakers/headphones/AirPods
```

Do not begin Windows, Linux, Android, multi-peer mixing, cloud services, or a large GUI until iPhone -> Mac is reliable on a private LAN.

## Repository and remote

- Local path: `/Users/skandavyas/multipoint`
- GitHub: `https://github.com/skanda-vyas-srinivasan/multipoint`
- Visibility: private
- Branch: `main`
- Initial commit: `72af87b` (`Initial iPhone to Mac audio streaming MVP`)
- `main` tracks `origin/main`

Build products are ignored by `.gitignore`, including `build/`, Xcode `DerivedData/`, user data, and `.xcuserstate` files.

## Environment used

- macOS 27.0
- Xcode 27.0
- iPhone 13, iOS 27.0, Developer Mode enabled and physically paired
- iPhone UDID: `00008110-000254980A51801E`
- Apple development team: `7934D5M686`
- iOS bundle ID: `com.skandavyas.multipoint.ios`
- User-local CMake: `/Users/skandavyas/Library/Python/3.9/bin/cmake`

## What is implemented

### iOS capture

- Swift iOS app in `ios/MultiAudioIOS`.
- Uses iOS 27 ScreenCaptureKit and `SCContentSharingPicker`.
- User starts streaming, approves **Share Entire Screen**, and the app captures audio sample buffers.
- Screen/video frames are discarded.
- The app logs sample rate, channel count, format, frame count, presentation timestamp, duration, RMS, and peak without dumping PCM data.
- A live UI indicates audio buffers and RMS/peak activity.
- Physical iPhone testing proved that real system audio changes the RMS level.
- The Apple `com.apple.developer.screen-recording` entitlement was rejected for this development team and was removed. Runtime capture works through the supported picker and usage description.
- Instagram can produce silence at very low volume because the app appears to stop/mute its own renderer. Spotify continues rendering. This is an app/source behavior; supported iOS APIs cannot force another app to render muted audio.

### Portable C++20 core

Located under `core/`:

- Explicit network packet serialization/deserialization; no raw C++ structs on the wire.
- 48-byte header with magic, protocol version, packet type, stream ID, sequence number, sender timestamp, audio sample index, sample rate, channels, frames per packet, and payload size.
- Network format: 48 kHz, stereo, float32 PCM.
- 120 frames per packet (2.5 ms), producing approximately 1008-byte datagrams to stay below common MTUs.
- Network byte order is used for integer fields; float bits are serialized explicitly.
- POSIX UDP sender/receiver.
- Jitter buffer supporting reorder detection, duplicates, late packets, missing packets, bounded capacity, stale-audio shedding, and gap resynchronization.
- Lock-free single-producer/single-consumer audio ring buffer.
- Monotonic clock and sequence utilities.

### macOS receiver and synthetic test

Located under `macos/MultiAudioMac`:

- Synthetic 440 Hz sender and Mac UDP receiver.
- Receiver pipeline: UDP receive thread -> jitter buffer -> audio ring -> CoreAudio default output AudioUnit.
- CoreAudio callback does not perform network I/O, allocation, blocking mutex waits, or logging.
- Synthetic Mac loopback was heard successfully with clean packet statistics.
- macOS currently uses the selected system default output device.

### iPhone-to-Mac transport

- Objective-C++ bridge reuses the portable packet encoder.
- Swift capture boundary converts supported linear PCM input to interleaved 48 kHz stereo float32.
- Supports float32/int16 and interleaved/non-interleaved input forms.
- Capture callback feeds a bounded queue; a separate UDP sender queue performs network transmission.
- UI exposes receiver IP/port, network state, sent packets, queue drops, and conversion drops.

## Build and test

From the repository root:

```sh
/Users/skandavyas/Library/Python/3.9/bin/cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
/Users/skandavyas/Library/Python/3.9/bin/cmake --build build -j 8
/Users/skandavyas/Library/Python/3.9/bin/ctest --test-dir build --output-on-failure
```

The core test suite currently passes. Tests cover packet round trips/rejection, sequence wrap, jitter reorder/loss/duplicates/recovery, and the audio ring.

The iOS app is built/deployed from Xcode to the physical iPhone using the configured development team. The Mac receiver can be launched from the build directory, for example:

```sh
./build/macos/MultiAudioMac/multipoint_receiver 48100 40
```

The second argument is target jitter latency in milliseconds. A 200 ms value was used for relayed testing.

## Tests completed and findings

### Direct/private-LAN components

- Packetization, UDP, jitter buffer, ring buffer, and CoreAudio were independently validated with the synthetic Mac sender.
- The iPhone capture path was physically validated.

### Public Wi-Fi and Tailscale relay

The outdoor/public Wi-Fi used client isolation: the Mac and iPhone were both in `172.16.101.0/24`, but ARP from the Mac to the iPhone was incomplete and direct UDP failed.

An iPhone Personal Hotspot test produced iOS error 50 (`network is down`) for the iPhone-to-tethered-Mac route. Do not treat that as proof that all hotspot configurations are impossible; it was the observed configuration.

Tailscale was installed temporarily on both devices to create a test path. The Mac Tailscale IP was `100.72.75.93`; the iPhone was `100.65.45.43`. Tailscale reported a relay path (`sfo`/`lax`), not direct peer-to-peer.

The complete iPhone -> Mac stream worked through the relay, but uncompressed float PCM was not consistently smooth. In a controlled roughly two-minute run:

- 48,801 packets received
- 2,028 packet positions missing during playout (~4%)
- 404 late packets
- 873 stale packets intentionally discarded during recovery
- 0 buffer overflows
- 0 CoreAudio underruns
- 0 malformed, reordered, or duplicate packets

The user heard occasional jitter and periods of silence, matching the measured relay outages. The sender UI showed network `Ready`, increasing packet count, and zero queue/conversion drops. Therefore those losses occurred after the iPhone sender, in the public network/relay path. The receiver recovered after outages instead of remaining permanently stuck.

The current uncompressed format is about 3.2 Mbps and roughly 400 UDP packets/second. That is intentionally simple for the MVP but demanding for a relayed path.

## Important current limitations

- The definitive quality test still needs to be performed on a normal private/home Wi-Fi LAN, directly to the Mac's LAN IP, using a 40–50 ms target buffer.
- Tailscale is test plumbing only; it is not part of the product design.
- Bonjour/mDNS discovery is not implemented; manual Mac IP entry is intentional for this milestone.
- No Opus compression, FEC, encryption/authentication, NAT traversal, TURN relay, clock-drift correction, adaptive resampling, or multi-peer mixing yet.
- The receiver currently outputs to the macOS default output; explicit output-device selection is not implemented.
- iOS local output is mirrored rather than suppressed. iOS public APIs do not provide a general system-wide virtual null sink or a way to make another app believe volume is nonzero while muting the iPhone speaker.
- The current implementation is a prototype and should not claim production-grade relay reliability.

## Next session: recommended order

1. Run the same two-minute test on private/home Wi-Fi with the Mac's direct LAN IP and 40–50 ms jitter target.
2. Record packet loss, late packets, jitter depth, recovery events, ring depth, and underruns.
3. If direct LAN is clean, document the first MVP as successful and avoid adding unrelated features.
4. Fix any direct-LAN timing or drift issue before working on discovery.
5. Add clock-drift estimation and small adaptive resampling after the direct demo is stable.
6. Add Bonjour/mDNS discovery after manual-IP streaming is reliable.
7. Add a proper connection layer later: direct LAN first, ICE/NAT traversal next, encrypted relay fallback last.
8. For relayed mode, evaluate Opus, lower packet rate, loss concealment, FEC, and adaptive latency rather than trying to hide multi-second outages with an enormous buffer.

## Current honest milestone

The project has proven that supported iOS 27 ScreenCaptureKit can obtain real iPhone system-audio sample buffers and that those samples can be packetized and played on a Mac over UDP. The remaining immediate proof is quality on a stable private LAN. Do not call the overall product complete until that test is clean.
