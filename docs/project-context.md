# SoundMux Session Handoff

Last updated: September 19, 2026

## Product

SoundMux is intended to become a cross-platform, peer-to-peer-first audio-routing system for sending audio among phones and computers and playing it through a selected receiver device. The only active milestone is still:

```text
iPhone ScreenCaptureKit system audio
    -> packetization/FEC
    -> UDP
    -> Mac jitter buffer
    -> CoreAudio default output
```

Do not start Windows, Linux, Android, multi-peer mixing, cloud networking, or a polished UI until this path is reliable.

## Repository

- Local repository: `/Users/skandavyas/multipoint`
- Remote: `https://github.com/skanda-vyas-srinivasan/stream-mux.git`
- Branch: `main`
- Previous diagnostic checkpoint: `c7a428c Checkpoint capture stall diagnosis and recovery work`
- Product name shown to users: **SoundMux**
- Internal target/path/bundle names still use MultiAudio/multipoint for stability.

Environment:

- macOS 27.0, Xcode 27.0
- iPhone 13 on iOS 27.0 with Developer Mode enabled
- iPhone UDID: `00008110-000254980A51801E`
- Team: `7934D5M686`
- Bundle ID: `com.skandavyas.multipoint.ios`
- CMake tools: `/Users/skandavyas/Library/Python/3.9/bin`

## Implemented and physically proven

- iOS 27 ScreenCaptureKit capture through Apple's system content-sharing picker.
- Full-display capture with video frames discarded and audio `CMSampleBuffer`s processed.
- Live sample format, frame count, timestamps, RMS, peak, capture-rate, and transport metrics.
- 48 kHz stereo capture converted to the portable network format.
- Protocol v3 with explicit 52-byte serialization; raw C++ structs are never sent.
- PCM16 wire payload, 240 frames/5 ms per audio packet, 1,012-byte datagrams.
- Systematic GF(256) 10-data + 5-parity FEC with parity delayed one group (~50 ms).
- Portable C++20 packet, FEC, sequence, jitter, ring-buffer, clock, and UDP components.
- Mac UDP receiver, jitter buffer, concealment, lock-free audio ring, and CoreAudio output.
- Synthetic Mac 440 Hz path works.
- Real iPhone audio has been heard through the Mac both on a LAN and through Tailscale.

## Important transport change that worked

The old iOS portable BSD UDP socket could report successful sends while delivering **zero** packets through the iPhone's Tailscale VPN route. This was proven by adding raw UDP counters to the Mac receiver. At the same time:

- Mac synthetic audio sent to `100.72.75.93:48100` played correctly.
- Safari on the iPhone successfully reached an HTTP listener at `100.72.75.93:48101` from iPhone Tailscale IP `100.65.45.43`.
- Therefore the Mac receiver and Tailscale path worked; the old iOS socket adapter did not use the route correctly.

Commit `feb6114` replaced only the iOS socket adapter with `Network.framework` `NWConnection` UDP. The portable packet/FEC logic remained unchanged. This build was physically installed and immediately restored iPhone-to-Mac audio.

In a controlled two-minute run after that change:

- About 36,000 raw UDP datagrams arrived.
- About 24,000 were audio packets; the rest were parity.
- Loss, late, duplicate, malformed, concealed, and CoreAudio-underrun counters stayed at zero.
- No new latency drops occurred.
- The stream sounded markedly better.

The test path used:

- Mac Tailscale IP: `100.72.75.93`
- iPhone Tailscale IP: `100.65.45.43`
- UDP port: `48100`

## Long-run stall discovered

A later long-running test exposed occasional multi-second audible chopping. Receiver evidence showed this was not ordinary clock drift:

- Maximum observed arrival freeze: about 36.2 seconds.
- Hundreds of packet positions became missing after delivery resumed.
- Concealment and bulk latency-drop counters rose sharply.
- CoreAudio underruns stayed at zero because concealment kept feeding the callback.

Observed behavior:

```text
delivery stalls
    -> receiver conceals/rebuffers
    -> stale queued packets resume in a burst
    -> jitter depth becomes excessive
    -> receiver repeatedly sheds old audio
    -> several seconds of audible chopping
```

This is a correctness issue worth fixing before implementing the reverse direction. It is separate from later latency and clock-drift optimization.

## Stall-recovery checkpoint

The checkpoint includes changes in:

- `ios/MultiAudioIOS/MultiAudioIOS/AudioTransport.swift`
- `macos/MultiAudioMac/receiver_main.mm`

Do not discard these changes.

The iOS change:

- Timestamps every queued UDP datagram.
- Evicts the oldest queued datagram when the bounded queue is full, preserving live audio.
- Drops queued datagrams older than 150 ms before transmission.
- Counts those stale/evicted packets in the existing queue-drop metric.
- Keeps at most one `NWConnection` send in flight, preventing a hidden multi-second framework backlog.

The Mac change:

- Detects a forward audio-sequence jump greater than 20 packets.
- Clears stale jitter/FEC state on that discontinuity.
- Requests a single hard playout resynchronization.
- Discards the stale audio ring, clears concealment history, and waits for a fresh prebuffer.
- Exposes a `hard_resyncs` receiver statistic.

Both targets compile successfully and the portable test suite passes. The build
was explicitly signed, installed with `devicectl`, and identified on the phone
with a temporary `Stall recovery build` label.

Physical testing proved that this recovery is incomplete. Actively opening and
closing iPhone apps produced 5--10 seconds of badly chopped audio, and the
receiver's sequence-gap detector did not engage (`hard_resyncs=0`). Do not
describe this checkpoint as a completed fix.

## September 18 synchronized capture diagnosis

A controlled run captured the iPhone's existing `USBMetricLogger` output and a
fresh Mac receiver timeline at the same time. Before phone interaction, capture
callback gaps were about 22--37 ms, PTS error was effectively zero, send gaps
were below 39 ms, and there were no queue drops or send failures.

During app switching:

- ScreenCaptureKit stopped delivering audio callbacks for 3.079 seconds.
- The captured audio PTS skipped about 1.880 seconds.
- iPhone UDP sending consequently paused for 3.237 seconds.
- `NWConnection` remained `Ready`; there were no send failures.
- The Mac observed the matching 3.389-second arrival freeze.
- Recovery accumulated 77 concealed packets, 423 latency drops, 5 CoreAudio
  underruns, and zero hard resyncs.

This proves that the initiating discontinuity is already present at the iPhone
ScreenCaptureKit audio boundary. The remaining difference between the callback
gap and media PTS gap indicates that stale capture buffers are also delivered
afterward, producing a catch-up burst. Receiver recovery then extends the
audible damage beyond the original capture pause.

An audio-output-only experiment removed the `.screen` stream output entirely.
It compiled, installed, captured audio successfully, and reproduced the same
interaction-triggered failure. This rules out SoundMux's discarded video
callback and shared callback queue as the primary cause, although iOS still
uses the full-display sharing session internally.

The next fix should:

1. Keep the ScreenCaptureKit callback minimal and move conversion, metering,
   FEC, logging, and UI publication off that callback queue.
2. Compare buffer PTS progress with monotonic host progress and discard stale
   capture buffers delivered after a long callback stall.
3. On a callback/PTS discontinuity over roughly 150--250 ms, clear pending
   transport data, start a new stream ID, and force one receiver hard resync.
4. Mute/rebuffer/fade in cleanly instead of replaying old audio.

## September 19 portable transport refactor

The sender and receiver transport orchestration now lives in the portable C++
core rather than being reimplemented by each app:

```text
platform capture adapter
    -> normalized timestamped PCM
    -> C++ SenderEngine (packetization, epochs, delayed FEC)
    -> platform datagram adapter
    -> C++ ReceiverEngine (decode, epochs, FEC, jitter, resync)
    -> platform playback adapter
```

- `transport::SenderEngine` owns partial PCM, packet sequence/sample indexes,
  stream epochs, and 10+5 delayed parity generation.
- `transport::ReceiverEngine` owns validation, retired-epoch rejection, FEC
  recovery, sequence-gap hard resync, jitter buffering, and receiver metrics.
- The iOS app retains only the Apple capture/freshness adapter and
  `Network.framework` UDP queue; its Swift packet/FEC implementation was
  removed and replaced with a small C bridge to `SenderEngine`.
- The Mac app retains POSIX UDP, concealment/ring management, and CoreAudio;
  its duplicated decode/FEC/jitter/epoch implementation was replaced by
  `ReceiverEngine`.
- These engines are platform-neutral C++20 and are intended to be reused for
  Mac, Windows, and Android adapters. Platform networking and audio I/O remain
  separate by design.

Tests now cover sender packetization/reset, receiver FEC recovery, receiver
epoch transition, rejection of delayed packets from a retired epoch, and
large sequence-gap resync. The core, Mac receiver, and signed physical-iPhone
target all build successfully. The new app was installed on the iPhone on
September 19. An app-switch audio stress test is still required before claiming
the audible artifact is fixed; this refactor establishes the shared transport
boundary but does not make ScreenCaptureKit callback stalls disappear.

## Exact current runtime state

- The iPhone 13 was visible through CoreDevice over USB as connected at the
  last check (UDID `00008110-000254980A51801E`).
- The signed Debug app containing the portable sender engine was installed.
- Automated launch was denied only because the iPhone was locked; unlock it
  before the next launch/test.
- No Mac receiver process should be assumed to be running. Start it with:

```sh
./build/macos/MultiAudioMac/multipoint_receiver 48100 100
```

- The receiver binary now uses the portable `ReceiverEngine` and includes raw
  UDP, FEC, stale-epoch, arrival-gap, jitter, and hard-resync metrics.
- The installed iPhone app includes callback decoupling, capture freshness
  quarantine, new stream epochs after recovery, and the portable
  `SenderEngine`.

## Xcode/device tooling

CoreDevice works when `xcrun devicectl` is run with sandbox escalation and the
iPhone is connected, unlocked, and trusted over USB. Automatic provisioning
also works with `xcodebuild -allowProvisioningUpdates`. Prefer explicit signed
build and `devicectl device install app` commands over Xcode's Run UI.

Xcode Stop/Run behavior was confusing during active ScreenCaptureKit sharing: the Mac continued receiving the same stream after the Xcode stop button and another Run action. Treat the system capture session as independently persistent for debugging purposes. Before replacement installation, confirm capture is stopped inside SoundMux; it is stopped now.

The temporary `Stall recovery build` label is currently present in the UI and
should be removed after this investigation.

## Build and test commands

```sh
/Users/skandavyas/Library/Python/3.9/bin/cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
/Users/skandavyas/Library/Python/3.9/bin/cmake --build build -j 8
/Users/skandavyas/Library/Python/3.9/bin/ctest --test-dir build --output-on-failure

xcodebuild \
  -project ios/MultiAudioIOS/MultiAudioIOS.xcodeproj \
  -scheme MultiAudioIOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

The latest run of both builds and the core tests passed.

## Recommended next-session sequence

1. Do not redo the network or synchronized capture diagnosis.
2. Unlock the already-connected iPhone and launch the installed build.
3. Start the Mac receiver with clean counters and begin ScreenCaptureKit audio.
4. Repeat the app-switch stress test with synchronized iPhone/Mac metrics.
5. When the user says `now`, take a baseline immediately, continue collecting
   for exactly 10 seconds, then analyze that delta. Do not stop capture at the
   marker.
6. Success means the unavoidable capture pause becomes one clean mute/rebuffer
   transition with no stale catch-up burst or multi-second chopping.
7. Do not claim the artifact is fixed until the user confirms what they heard.

## Known limitations and later work

- Receiver-side buffering is currently much higher than the nominal 100 ms target; observed total receiver buffering was roughly 300 ms. Reliability comes first, then reduce latency.
- Clock-drift estimation/adaptive resampling is not implemented.
- Bonjour discovery is not implemented; manual IP is intentional.
- No Opus, encryption/authentication, NAT traversal, TURN, or multi-peer mixing.
- Tailscale is test plumbing, not the final product architecture.
- A future no-router local mode should prefer peer-to-peer Wi-Fi; pure app-level BLE is unsuitable for the current PCM/FEC bitrate.
- iOS public APIs cannot generally force another app to render nonzero audio while muting only the iPhone speaker.

## Interaction note for the next session

The user is understandably frustrated by repeated setup questions and contradictory Xcode instructions. Lead with concrete actions and evidence. Do not ask them to repeat steps already documented here. Do not stop a working receiver unless its replacement is already ready and immediately restarted.
