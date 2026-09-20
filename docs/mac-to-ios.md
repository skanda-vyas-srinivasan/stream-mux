# Mac system audio to iPhone

This is an isolated transport direction that does not use iOS ScreenCaptureKit:

```text
macOS Core Audio global process tap
    -> private HAL aggregate device + IOProc
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

The sender prints capture, packet, conversion-drop, and send-failure counters.
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
- The first sender version expects the current Mac output/tap format to be
  48 kHz stereo float32 and reports a clear error otherwise; a sender-side
  sample-rate converter is the next compatibility step.
- Roughly 60 ms receiver prebuffer, plus network/jitter and device-output
  latency.
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
