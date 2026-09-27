# SoundMux project context

Last updated: September 24, 2026

## Current focus

Make **Mac → iPhone** dependable across common output configurations and daily
use. The reverse direction already has documented physical playback success;
the new sample-rate conversion has automated coverage but still needs physical
validation. The iPhone → Mac ScreenCaptureKit stall investigation is parked.
Do not resume it or expand to other platforms/multi-peer mixing unless that
scope is deliberately revisited.

```text
Mac Core Audio process tap + HAL IOProc
    -> stereo float32 capture ring
    -> sending worker: sample-rate conversion to 48 kHz
    -> portable SenderEngine: PCM16 packets + delayed 10+5 FEC
    -> UDP
    -> iPhone Network.framework listener
    -> portable ReceiverEngine: epochs + FEC + jitter
    -> audio ring -> AVAudioEngine -> selected iPhone output
```

Neither side uses ScreenCaptureKit in this direction. The capture callback
only copies/interleaves samples; conversion, packetization, FEC, and sending
run on the worker. AudioToolbox conversion retains state across capture chunks
and temporary input starvation. Native 48 kHz input bypasses conversion.

## Repository and launchers

- Working checkout: `/Users/skandavyas/stream-mux`
- Remote: `https://github.com/skanda-vyas-srinivasan/stream-mux.git`
- Product name: **SoundMux**; internal MultiAudio/multipoint names remain.
- Separate older checkouts exist; do not confuse their binaries or runtime
  state with this checkout.
- `./send` opens this checkout's native **SoundMux Sender** app.
- `./run [port] [latency-ms]` launches this checkout's Mac receiver, defaulting
  to `48100` and `100` ms, for the parked iPhone → Mac path.
- `./stop [port]` checks the executable path before stopping that receiver.
  All three scripts resolve paths relative to their own location.

## Implemented behavior

- The iPhone automatically listens on UDP `48101` and advertises
  **SoundMux iPhone** via Bonjour (`_soundmux._udp`).
- The native Mac sender discovers receivers and provides a manual IP fallback
  for VPN/hotspot paths where discovery does not work.
- Mac capture accepts packed stereo float32 at the tap's source sample rate;
  the wire format stays 48 kHz stereo PCM16, 240 frames / 5 ms per audio packet.
- Shared C++20 sender/receiver engines handle explicit protocol serialization,
  stream epochs, jitter, hard resync, and delayed 10-data + 5-parity FEC.
- The iPhone supports background/locked playback and a mixable audio session.
  Force-quitting ends reception. Interruption recovery is implemented but
  still belongs in the physical reliability test matrix.
- Previous, Play/Pause, and Next travel back on the adjacent UDP port (`48102`
  by default). Mac media-key control requires Accessibility permission;
  process-tap capture separately requires System Audio Recording permission.

## Build and verification

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 8
ctest --test-dir build --output-on-failure

xcodebuild \
  -project ios/MultiAudioIOS/MultiAudioIOS.xcodeproj \
  -scheme MultiAudioIOS \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

CMake/CTest are available under `/Users/skandavyas/Library/Python/3.9/bin` if
not already on PATH. The iOS capture target uses Xcode 27 / iOS 27 APIs.

The September 24 macOS Debug build and both CTest suites passed:

- `multipoint_core_tests`: protocol, FEC, sender/receiver, epoch changes,
  jitter, sequence wraparound, and audio-ring behavior.
- `soundmux_capture_conversion_tests`: 32, 44.1, 48, 88.2, 96, and 192 kHz
  conversion; duration/pitch/channel separation; anti-aliasing; exact 48 kHz
  bypass; uneven chunks and repeated starvation/resumption; invalid inputs;
  and converted packet contents.

These checks do not prove live process-tap capture, iPhone rendering, or
non-48-kHz physical playback. No iOS source changed in the conversion update.
Do not infer that an app is running or a particular build is installed from
this document.

## Next validation pass

1. Use the existing iPhone receiver and this checkout's new Mac sender.
2. Confirm ordinary 48 kHz playback remains clean.
3. Disconnect, select 44.1 kHz on a capable Mac output, then reconnect. Confirm
   the actual tap rate in the CLI startup line and check audible pitch and
   counter deltas. Repeat at 96 kHz if supported; restore the original rate.
4. Test sender restart, phone lock/background use, Wi-Fi interruption, and
   iPhone speaker/AirPods route changes. Record duration and counter deltas.
5. Measure end-to-end latency and long-session buffer growth before changing
   buffering or adding clock-drift compensation.

See [Mac-to-iPhone procedure](mac-to-ios.md) for detailed setup and success
criteria. Do not stop a working stream unless its replacement is ready.

## Known limitations

- Source format is established at connection time. Disconnect/reconnect after
  changing the Mac output sample rate; live format reconfiguration remains
  future work. Non-stereo/non-float32 tap formats remain unsupported.
- Receiver settings are a 12-packet jitter threshold and 2,880-frame (60 ms)
  audio-ring prebuffer. The displayed buffered duration counts only that ring,
  not jitter, conversion, network, or hardware latency.
- Clock-drift estimation and adaptive resampling are not implemented. Fixed
  nominal sample-rate conversion does not compensate independent device clocks.
- No encryption/authentication, Opus, NAT traversal, TURN, or multi-peer mixing.
- Tailscale is test plumbing, not the final networking architecture.
- The old iPhone → Mac path has source callback stalls during app switching;
  epoch recovery was observed, but that audible issue is not resolved.

## Historical evidence

The [September 19 handoff](archive/2026-09-19-project-context.md) preserves
capture-stall logs, the Network.framework routing diagnosis, earlier physical
test results, and device tooling details. Its runtime/install state and older
next-session instructions are historical, not current instructions.
