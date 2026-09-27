# MultiAudioMac

This directory contains both macOS platform adapters:

- `multipoint_receiver`: UDP input to the portable receiver engine and the
  current CoreAudio default output.
- `multipoint_mac_sender`: pure Core Audio process-tap/IOProc input to the
  worker-side sample-rate conversion, the portable sender engine, and UDP
  output. It accepts packed stereo float32 at the tap's sample rate and
  normalizes it to 48 kHz, with an exact bypass at 48 kHz. It also receives Previous,
  Play/Pause, and Next commands on the adjacent UDP port and emits macOS media
  keys. The app discovers iPhone receivers over Bonjour and retains a manual
  IP fallback for overlays such as Tailscale. It does not use ScreenCaptureKit.
- `multipoint_sine_sender`: a synthetic 440 Hz protocol test source.

See the repository README for iPhone-to-Mac usage and
`docs/mac-to-ios.md` for the reverse direction.
