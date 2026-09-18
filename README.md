# Linkverge

`multipoint` is a peer-to-peer, low-latency audio-routing project. The first
milestone is intentionally limited to capturing iPhone system audio with
ScreenCaptureKit on iOS 27. Networking and macOS playback begin only after the
capture probe works on a physical iPhone.

## Current phase

The iOS app presents Apple's system content-sharing picker, starts a
full-display capture after explicit approval, receives system-audio sample
buffers, logs their format and timing, updates a live buffer counter, and
discards screen frames.

See [docs/phase-1-ios-capture.md](docs/phase-1-ios-capture.md) for requirements,
build instructions, and the current toolchain blocker.

## Layout

```text
core/                 Portable C++20 components (future phases)
  protocol/
  network/
  jitter/
  clock/
  audio/
  util/
ios/MultiAudioIOS/    iOS 27 ScreenCaptureKit capture probe
macos/MultiAudioMac/  macOS receiver placeholder (future phase)
tests/                Portable-core tests (future phase)
docs/                 Design and validation notes
```

