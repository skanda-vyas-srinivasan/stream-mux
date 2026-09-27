# Mac system audio to iPhone

This is an isolated transport direction that does not use iOS ScreenCaptureKit:

```text
macOS Core Audio global process tap
    -> private HAL aggregate device + IOProc
    -> capture ring -> worker-side conversion to 48 kHz stereo float32
    -> C++ SenderEngine (PCM16 packets + delayed 10+5 FEC)
    -> UDP
    -> iOS Network.framework listener
    -> C++ ReceiverEngine (validation + FEC + jitter)
    -> lock-free audio ring
    -> AVAudioEngine / iPhone output route
```

The previous iPhone-to-Mac capture code remains in the repository, but starting
the iOS receiver does not initialize the picker, an `SCStream`, or its outbound
UDP connection.

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j 8

xcodebuild \
  -project ios/MultiAudioIOS/MultiAudioIOS.xcodeproj \
  -scheme MultiAudioIOS \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

For a physical test, sign and install the iOS app using the existing team and
bundle identifier.

## Connect

1. Put the Mac and iPhone on the same reachable local network.
2. Open SoundMux on the iPhone.
3. The phone starts listening on port `48101` and advertises **SoundMux iPhone**
   automatically. Accept the local-network prompt if iOS shows one.
4. Open the native sender app on the Mac:

   ```sh
   ./send
   ```

   The discovered iPhone is selected automatically. Click **Connect**.
5. If local discovery is blocked by a VPN, guest Wi-Fi, or hotspot isolation,
   choose **Manual address…** and enter an IP that the Mac can reach. Tailscale
   addresses work through this fallback.
6. For terminal diagnostics, the equivalent command is:

   ```sh
   ./build/macos/MultiAudioMac/multipoint_mac_sender <iphone-ip> 48101
   ```

7. Grant the Mac process **System Audio Recording** access if prompted.
8. Play ordinary, unprotected audio on the Mac. The iPhone status should move
   from **Listening** to **Buffering** and then **Playing**.
9. Use the iPhone's Previous, Play/Pause, and Next buttons to control the active
   Mac media app. Grant **Accessibility** access to SoundMux Sender if macOS
   prompts; this is separate from audio-capture permission.

The CLI reports the capture sample rate and fixed 48 kHz wire rate at startup.
The sender prints capture, packet, capture-drop, and sender-failure counters.
The iPhone shows raw datagrams, decoded audio packets, FEC recovery, loss,
concealment, hard resyncs, audio underruns, and buffered duration.

## Initial scope

- One Mac sender and one iPhone receiver.
- No ScreenCaptureKit or video capture exists in this direction.
- Mac capture uses `AudioHardwareCreateProcessTap`, a private aggregate audio
  device, and `AudioDeviceCreateIOProcIDWithBlock`.
- Core Audio process taps require macOS 14.2 or later.
- Bonjour discovery on local networks, with manual IP/Tailscale fallback.
- Audio uses the selected UDP port (`48101` by default). The three fixed remote
  control commands return on the next UDP port (`48102` by default); no
  arbitrary input is executed.
- Fixed 48 kHz stereo PCM16 wire format.
- The Mac tap must supply packed stereo float32, either interleaved or planar.
  A persistent AudioToolbox converter on the sending worker normalizes other
  sample rates to 48 kHz; 48 kHz input bypasses conversion. The capture callback
  only interleaves/copies audio into the capture ring. Temporary input gaps
  preserve converter state without adding silence or replaying old samples.
- Conversion tests cover 32, 44.1, 48, 88.2, 96, and 192 kHz. Non-48-kHz
  physical playback is not yet validated. Disconnect and reconnect after a
  Mac device/sample-rate change; automatic live format reconfiguration is
  still future work.
- The receiver uses a 60 ms audio-ring prebuffer and a 12-packet jitter
  threshold, plus conversion, network, and device-output latency. Its displayed
  buffered duration counts only the audio ring, not end-to-end latency.
- iOS background audio mode is enabled, so an active stream can continue while
  using other apps or while the phone is locked. Force-quitting SoundMux still
  stops the receiver,
  as required by iOS.
- The receiver requests a mixable playback session, allowing Mac audio and
  ordinary audio from another iPhone app to play concurrently. Apps that demand
  exclusive audio can still cause a temporary iOS interruption; SoundMux
  reactivates and starts from fresh buffered audio when it ends.
- Protected Mac media may be silent because of source/platform policy.

## Success criteria

- Continuous Mac audio is audible through the iPhone-selected output route.
- Sender packet counters and iPhone datagram counters rise together.
- No continuing growth in malformed packets, losses, concealment, or audio
  underruns on a healthy LAN.
- Stopping and restarting the Mac sender produces one clean receiver rebuffer,
  not stale replay.

## Sample-rate validation

Run `ctest --test-dir build --output-on-failure`. The macOS-only
`soundmux_capture_conversion_tests` exercises rate/duration, pitch, channel
separation, anti-aliasing, exact 48 kHz bypass, irregular chunks, repeated empty
input polls, and converted PCM16 packet contents without using audio hardware.

For a physical pass, disconnect the sender, choose a supported Mac output rate
in Audio MIDI Setup (start with 44.1 kHz, then 48 and 96 kHz where available),
and reconnect. Use the CLI startup line to confirm the actual tap rate; a
device's configured rate alone does not prove that the tap uses it. Listen for
pitch changes, gaps, or clicks and compare capture drops, sender failures,
receiver losses, concealment, and underruns over a sustained stream. Restore
the original output rate afterward. Record hardware, actual tap rate, duration,
and counter deltas before calling a rate physically validated.
