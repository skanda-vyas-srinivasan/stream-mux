# SoundMux Project Context

This document is the handoff point for the next session.

## Project goal

SoundMux is a cross-platform, peer-to-peer multi-device audio-routing system. The first implemented platform path is:

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
- Protocol v3 uses an explicit 52-byte header with magic, version, packet type, stream ID, sequence number, sender timestamp, audio sample index, audio format, payload size, and FEC shard metadata.
- Capture/playback are float32; the wire format is 48 kHz stereo PCM16.
- 240 frames per audio packet (5 ms), producing 1,012-byte datagrams.
- Integer fields and PCM16 samples use network byte order.
- A systematic 10-data + 5-parity erasure code over GF(256) is implemented. Unit tests prove byte-exact recovery of five simultaneously missing PCM packets.
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
- Capture callback feeds a bounded queue; a separate UDP sender queue performs nonblocking socket transmission.
- iOS 27 background execution only remained reliable when sends were triggered by ScreenCaptureKit deliveries. Independent 3.33 ms and 5 ms pacing timers were throttled after leaving the app, even though audio capture callbacks continued.
- Parity is intentionally delayed by one FEC group (~50 ms) so a short radio blackout does not erase both source audio and its recovery data.
- UI exposes receiver IP/port, network state, sent packets, queue drops, and conversion drops.

## Build and test

From the repository root:

```sh
/Users/skandavyas/Library/Python/3.9/bin/cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
/Users/skandavyas/Library/Python/3.9/bin/cmake --build build -j 8
/Users/skandavyas/Library/Python/3.9/bin/ctest --test-dir build --output-on-failure
```

The core test suite currently passes. Tests cover packet round trips/rejection, sequence wrap, jitter reorder/loss/duplicates/recovery, the audio ring, and exact recovery of five missing FEC shards.

The iOS app is built/deployed from Xcode to the physical iPhone using the configured development team. The Mac receiver can be launched from the build directory, for example:

```sh
./build/macos/MultiAudioMac/multipoint_receiver 48100 40
```

The second argument is target jitter latency in milliseconds. Recent LAN/FEC testing uses 100 ms.

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

### Current LAN diagnosis (September 18, 2026)

- Direct iPhone -> Mac streaming works at Mac address `10.0.0.14:48100`, including while another iPhone app is in the foreground.
- ScreenCaptureKit continues delivering 48 kHz audio buffers in the background. The app declares `UIBackgroundModes = screen-capture`.
- The iPhone's successful UDP writes were stable, with zero queue/conversion drops, while the Mac observed recurring loss bursts. macOS socket overflow counters did not increase. The loss therefore occurred between the successful iPhone socket write and Mac socket receipt.
- Wi-Fi signal was strong, but ping also showed intermittent loss. The user cannot test another Wi-Fi network right now.
- PCM16 reduced bandwidth from the earlier float32 wire format. A 100 ms receiver buffer, improved gap handling, and history-based concealment reduced but did not eliminate artifacts.
- Pairwise XOR FEC was physically tested and was insufficient: in one run 17 packets were declared lost and only 6 were recovered. The user still heard bad artifacts.
- Pairwise XOR was replaced with a systematic GF(256) 10+5 erasure code capable of recovering any five missing packets in a group. It compiles in CMake and Xcode, passes byte-exact recovery tests, and has now been validated on the physical iPhone/Mac path.
- In the first physical GF(256) run, the user reported a stark improvement and heard few gaps. The sender sustained roughly 300 total audio/parity datagrams per second with zero queue drops or send failures, the Mac reported zero CoreAudio underruns, and the recovery counter increased during observed network loss.
- Some bursts still exceeded or escaped the current recovery window, so the audio path is substantially improved but not yet artifact-free.
- The previously installed delayed-XOR build proved that callback-triggered sending continues off-app. Do not restore independent high-frequency sender timers; iOS throttled them in the background and the queue overflowed.

## Important current limitations

- The definitive quality test still needs to be performed on a normal private/home Wi-Fi LAN, directly to the Mac's LAN IP, using a 40–50 ms target buffer.
- Tailscale is test plumbing only; it is not part of the product design.
- Bonjour/mDNS discovery is not implemented; manual Mac IP entry is intentional for this milestone.
- No Opus compression, encryption/authentication, NAT traversal, TURN relay, clock-drift correction, adaptive resampling, or multi-peer mixing yet.
- The receiver currently outputs to the macOS default output; explicit output-device selection is not implemented.
- iOS local output is mirrored rather than suppressed. iOS public APIs do not provide a general system-wide virtual null sink or a way to make another app believe volume is nonzero while muting the iPhone speaker.
- The current implementation is a prototype and should not claim production-grade relay reliability.

## Next session: recommended order

1. Repeat a controlled multi-minute GF(256) run and separate startup/app-switch loss from steady-state loss in the statistics.
2. Track loss by FEC group so diagnostics distinguish recovered source loss, unrecoverable groups, and lost parity.
3. If more than five data shards per group are missing, increase interleaving across groups or evaluate Opus; do not return to co-locating parity with its protected audio.
4. Add clock-drift estimation and gradual adaptive resampling after burst recovery is stable.
5. Add Bonjour discovery after manual-IP streaming is consistently reliable.

## Current honest milestone

SoundMux has proven supported iOS 27 ScreenCaptureKit system-audio capture, background capture delivery, UDP transport, GF(256) burst-loss recovery, and CoreAudio playback on a physical iPhone/Mac pair. The newest recovery design produced a clear audible improvement, but occasional artifacts remain. Do not call the transport production-reliable until steady-state unrecoverable loss is understood and controlled.
