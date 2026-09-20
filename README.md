# SoundMux

SoundMux is a peer-to-peer audio-routing app that sends audio between devices
over a local network and plays it through the receiver's selected speakers,
headphones, or AirPods.

```text
iPhone ───────┐
Windows PC ───┼──> SoundMux receiver ──> audio output
Linux PC ─────┤
Mac ──────────┘
```

The finished app is designed to support automatic device discovery, multiple
simultaneous senders, receiver-side mixing, output selection, live connection
statistics, clock synchronization, and direct encrypted connections across
iOS, macOS, Windows, Linux, and Android.

## Current implementation

The physically proven path is iPhone to Mac. The iPhone uses the supported iOS 27
ScreenCaptureKit sharing flow to capture system audio after explicit approval,
converts it to 48 kHz stereo PCM, and sends it over UDP. The Mac reconstructs
recoverable packet loss, buffers network jitter, and plays the stream through
CoreAudio.

A separately isolated **Mac to iPhone** path is now implemented for validation.
The Mac captures pure system audio with a Core Audio process tap and HAL IOProc,
then sends it through the same portable packet/FEC engine. The iPhone listens
with Network.framework, uses the portable receiver and jitter buffer, and
renders through AVAudioEngine. This direction does not use ScreenCaptureKit on
either device. It has been validated on a physical iPhone with artifact-free
playback.

The portable C++20 core provides reusable sender and receiver engines around
packet serialization, stream epochs, UDP adapters, jitter buffering, an audio
ring buffer, hard resynchronization, and 10-data + 5-parity erasure coding.
Apple capture, networking policy, and playback integrations remain thin
platform adapters outside the portable transport engines.

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 8
ctest --test-dir build --output-on-failure

./build/macos/MultiAudioMac/multipoint_receiver 48100 100
```

For Mac-to-iPhone streaming, install and open the iOS app. It starts listening
on UDP port `48101` and advertises itself automatically. Then open the native
**SoundMux Sender** Mac app with:

```sh
./send
```

On the same local network, the Mac discovers and selects **SoundMux iPhone**;
click **Connect**. If Bonjour is unavailable across a VPN or isolated hotspot,
choose **Manual address…** and enter the iPhone's reachable IP. The command-line
equivalent remains available for diagnostics:

```sh
./build/macos/MultiAudioMac/multipoint_mac_sender <iphone-ip> 48101
```

The iPhone's Previous, Play/Pause, and Next buttons send three fixed UDP
commands back to the Mac on port `48102`. The first Mac capture run requests
System Audio Recording permission; remote playback control also needs
Accessibility permission. See
[docs/mac-to-ios.md](docs/mac-to-ios.md) for the validation procedure.

The iOS receiver declares background audio playback, so an active stream keeps
playing when SoundMux is backgrounded or the phone is locked. It cannot keep
running after the user force-quits the app.

For an interactive zsh configured with the repository shortcut, use `run` for
the default port `48100` and `100` ms latency, or `run <port> <latency-ms>` to
override them. Use `stop` to stop the receiver on port `48100`, or
`stop <port>` for a custom port.

Build the iPhone sender from
`ios/MultiAudioIOS/MultiAudioIOS.xcodeproj` using Xcode 27 and a physical iPhone
running iOS 27 or later.

Detailed implementation and test notes are in
[docs/project-context.md](docs/project-context.md).
