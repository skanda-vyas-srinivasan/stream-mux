# Mac-to-Windows Receiver Acceptance Plan

## Objective

Deliver a native Windows receiver that accepts audio from the existing SoundMux
Mac sender without introducing a second transport or wire protocol. The first
usable version is a standalone Windows process; integration with Sonexis and a
polished Windows UI come only after the receiver is audibly reliable.

## Architecture boundary

The Windows receiver must reuse the existing portable components for:

- protocol version 3 packet parsing;
- X25519 pairing and remembered device trust;
- XChaCha20-Poly1305 session encryption and replay protection;
- UDP transport through the existing Winsock backend;
- 10-data + 5-parity FEC recovery;
- jitter buffering, concealment, and hard resynchronization; and
- the fixed 48 kHz, stereo PCM wire format.

Windows-specific code is limited to the application lifecycle, durable settings,
network discovery, and WASAPI playback. Audio networking must run in the
standalone SoundMux process, never inside `audiodg.exe` or an APO callback.

## Delivery milestones

1. **Windows build and portable tests**
   - Configure and build with current Visual Studio/MSVC and CMake on Windows 11
     x64.
   - Run the portable protocol, crypto, FEC, jitter, and connection-planner tests.
   - Keep the existing macOS and iOS builds passing.

2. **Secure command-line receiver**
   - Listen on a configurable UDP port, defaulting to `48100`.
   - Expose a stable receiver ID and persistent device key.
   - Complete the existing HELLO / PAIR_REQUIRED / WELCOME handshake.
   - Display the six-digit comparison code and require explicit first-use
     approval.
   - Remember an approved Mac and reject a changed key for the same identity.
   - Support manual connection from the Mac sender by Windows IP address.

3. **WASAPI playback**
   - Render through the current default Windows output in shared mode.
   - Keep blocking, allocation, decryption, and network work off the WASAPI
     render callback.
   - Convert from the 48 kHz stereo wire format when the endpoint mix format
     differs.
   - Rebuffer cleanly after endpoint changes, device invalidation, and stream
     restarts without replaying stale audio.

4. **Diagnostics and recovery**
   - Report packet arrival gaps, loss, FEC recovery, concealment, jitter depth,
     buffered audio, render underruns, hard resyncs, and session state.
   - Timestamp anomalous counter changes so an audible event can be assigned to
     capture, network/transport, or playback.
   - Detect sender loss through the existing heartbeat contract and accept a
     trusted reconnection without another pairing prompt.

5. **Discovery and native controls**
   - Advertise the receiver through DNS-SD/mDNS with the same service metadata as
     the Apple receivers.
   - Appear automatically in the Mac sender while retaining manual-IP fallback.
   - Provide start/stop, receiver name, port, latency, volume, output device,
     trusted-device management, and live diagnostics in a native Windows UI.

6. **Sonexis integration**
   - Package the proven receiver engine as a standalone worker usable by the
     Sonexis Windows application.
   - Keep the APO boundary limited to a lock-free audio handoff; do not move
     sockets, crypto, or blocking calls into `audiodg.exe`.

## Physical acceptance gate

The feature is not complete merely because the Windows machine produces sound.
Before merging to `main`, all of the following must pass on real hardware:

- A Mac pairs with a Windows 11 x64 machine and begins playback through the
  selected Windows output.
- Left/right channels, pitch, and playback speed are correct.
- A continuous 30-minute 48 kHz listening test has no sustained corruption,
  stale replay, or unexplained disconnect.
- Ordinary use of both computers during that test does not cause a prolonged
  degraded-audio period.
- Any audible artifact is matched to timestamped diagnostic evidence.
- The Stable (100 ms) preset tolerates ordinary LAN jitter without render
  underruns; lower-latency presets may trade resilience only as labeled.
- Stopping and restarting either application recovers automatically for a
  trusted peer and starts from fresh audio.
- Temporarily disabling and restoring Wi-Fi produces a clean rebuffer and
  reconnect rather than a stale or permanently damaged stream.
- Changing the Windows default output device either migrates cleanly or reports
  a clear recoverable error, then resumes without restarting the computer.
- A wrong pairing code, changed device key, malformed datagram, replayed
  encrypted packet, and unauthorized sender are rejected without playback or a
  crash.
- Windows Firewall requirements are surfaced clearly on first run.
- The existing Mac-to-iPhone path and portable automated tests still pass.

## Initial test matrix

Record the Windows version, network route, output device, endpoint mix format,
latency preset, duration, and counter deltas for each physical run.

| Route | Network | Windows output | Required first pass |
| --- | --- | --- | --- |
| Mac to Windows | Same Wi-Fi LAN | Built-in speakers/headphones | Yes |
| Mac to Windows | Ethernet or mixed Ethernet/Wi-Fi | Built-in output | Yes |
| Mac to Windows | Same Wi-Fi LAN | Bluetooth headset | Yes |
| Mac to Windows | Tailscale/manual IP | Built-in output | After LAN passes |

## Merge policy

- Development stays on `feature/windows-receiver`.
- Each milestone lands as a focused, signed commit and is pushed for recovery.
- `main` is updated only after the physical acceptance gate passes or after an
  explicitly labeled partial milestone is intentionally approved for merge.
