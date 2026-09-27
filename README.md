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

The Mac sender converts stereo float32 capture audio to the fixed 48 kHz wire
format on its sending worker. Capture at 48 kHz passes through unchanged;
other sample rates use AudioToolbox conversion. Automated conversion tests
cover 32, 44.1, 48, 88.2, 96, and 192 kHz. Physical validation of non-48-kHz
capture remains pending.

The portable C++20 core provides reusable sender and receiver engines around
packet serialization, stream epochs, UDP adapters for POSIX and Winsock,
jitter buffering, an audio ring buffer, hard resynchronization, a portable
session protocol, and 10-data + 5-parity erasure coding. Platform capture and
playback integrations remain thin adapters outside the transport engines.

Receivers advertise a stable device UUID, user-facing name, platform, protocol
versions, and capabilities. The first connection requires approval on the
receiver with a matching six-digit code. Long-term X25519 public keys are then
pinned to the stable device IDs. Each connection derives fresh directional
keys and encrypts audio, heartbeats, and media commands with authenticated
XChaCha20-Poly1305 envelopes. Trusted devices reconnect automatically and
heartbeats prevent a UDP socket from being mistaken for a live connection.

The connection planner keeps local discovery, remembered addresses, future
rendezvous results, and relay routes separate from the audio engine. The
rendezvous and relay services themselves are not deployed yet; current builds
still require a directly reachable LAN address.

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 8
ctest --test-dir build --output-on-failure

./build/macos/MultiAudioMac/multipoint_receiver 48100 100
```

Open the unified native **SoundMux** Mac app with:

```sh
./send
```

Use **Send Audio** to discover an iPhone, Mac, or compatible Windows receiver,
then click **Connect**. Use **Receive Audio** to make the Mac discoverable and
play incoming audio through its current system output. Receiver mode includes
latency presets, volume, remembered pairing, and optional automatic startup.

On first use, confirm the same pairing code on both devices and approve it on
the receiver. Later launches reconnect automatically. If Bonjour is unavailable
across a VPN or isolated hotspot, choose **Manual address…** and enter the
receiver's reachable IP. The command-line sender remains available for
diagnostics:

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

For Mac-to-Mac use, select **Receive Audio** on the destination Mac and click
**Make This Mac Available**. The sending Mac discovers it automatically. The
receiver filters its own identity to prevent a same-Mac feedback loop.

The terminal receiver remains available for diagnostics:

```sh
./build/macos/MultiAudioMac/multipoint_receiver 48100 60
```

It advertises itself as a macOS receiver and prints the first-use comparison
code in the terminal.

The portable core now builds on Windows with Winsock. The intended
Sonexis-Windows integration copies post-DSP APO samples into a lock-free ring
and performs SoundMux networking in a separate worker process—never inside
`audiodg.exe`. See [docs/session-protocol.md](docs/session-protocol.md).

Use `./run` for the default receiver port `48100` and `100` ms latency, or
`./run <port> <latency-ms>` to override them. Use `./stop` to stop this
checkout's receiver on port `48100`, or `./stop <port>` for a custom port.
The launcher scripts resolve their build paths relative to their own location.

Build the iPhone sender from
`ios/MultiAudioIOS/MultiAudioIOS.xcodeproj` using Xcode 27 and a physical iPhone
running iOS 27 or later.

Detailed implementation and test notes are in
[docs/project-context.md](docs/project-context.md).
