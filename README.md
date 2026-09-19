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

The working path is iPhone to Mac. The iPhone uses the supported iOS 27
ScreenCaptureKit sharing flow to capture system audio after explicit approval,
converts it to 48 kHz stereo PCM, and sends it over UDP. The Mac reconstructs
recoverable packet loss, buffers network jitter, and plays the stream through
CoreAudio.

The portable C++20 core provides reusable sender and receiver engines around
packet serialization, stream epochs, UDP adapters, jitter buffering, an audio
ring buffer, hard resynchronization, and 5-data + 5-parity erasure coding.
Apple capture, networking policy, and playback integrations remain thin
platform adapters outside the portable transport engines.

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 8
ctest --test-dir build --output-on-failure

./build/macos/MultiAudioMac/multipoint_receiver 48100 100
```

For an interactive zsh configured with the repository shortcut, use `run` for
the default port `48100` and `100` ms latency, or `run <port> <latency-ms>` to
override them. Use `stop` to stop the receiver on port `48100`, or
`stop <port>` for a custom port.

Build the iPhone sender from
`ios/MultiAudioIOS/MultiAudioIOS.xcodeproj` using Xcode 27 and a physical iPhone
running iOS 27 or later.

Detailed implementation and test notes are in
[docs/project-context.md](docs/project-context.md).
