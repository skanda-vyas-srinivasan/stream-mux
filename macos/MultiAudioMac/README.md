# MultiAudioMac

This directory contains the unified native SoundMux Mac app and its platform
adapters:

- `SoundMux.app`: a friendly Send/Receive interface. Send mode discovers nearby
  receivers, remembers the selected device, and reconnects automatically.
  Receive mode advertises the Mac over Bonjour, asks before first-use pairing,
  and exposes latency, volume, output-settings, and trusted-device controls.

- `multipoint_receiver`: UDP input to the portable receiver engine and the
  current CoreAudio default output. It advertises stable macOS receiver
  identity/capabilities over Bonjour and answers the portable session
  handshake, enabling Mac-to-Mac routing from another machine.
- `multipoint_mac_sender`: command-line-capable build of the same pure Core
  Audio process-tap/IOProc sender and unified GUI. Its sender path performs
  worker-side sample-rate conversion, then connects to the portable sender
  engine and encrypted UDP output. It accepts packed stereo float32 at the
  tap's sample rate and normalizes it to 48 kHz, with an exact bypass at
  48 kHz. It also receives Previous,
  Play/Pause, and Next commands on the adjacent UDP port and emits macOS media
  keys. The app discovers compatible iOS, macOS, and Windows receivers over
  Bonjour, compares and pins cryptographic device identities on first use,
  encrypts audio and controls, monitors heartbeats, remembers the receiver, and
  retains a manual IP fallback. It does not use ScreenCaptureKit.
- `multipoint_sine_sender`: a synthetic 440 Hz protocol test source.

See the repository README for iPhone-to-Mac usage and
`docs/mac-to-ios.md` for the reverse direction.
