# Phase 1: iOS system-audio capture

## Validation status

Validated on September 17, 2026 with an iPhone 13 running iOS 27.0:

- The system content-sharing picker approved full-display capture.
- ScreenCaptureKit delivered audio `CMSampleBuffer` values continuously.
- Silent periods still produced timed buffers, as expected.
- The live RMS meter rose when device audio played, confirming that the
  buffers contained non-silent system-audio samples.
- Screen frames were received only to support the full-display stream and were
  discarded immediately.

This completes the capture proof. UDP transport and macOS playback remain
outside phase 1.

## Toolchain requirement

The ScreenCaptureKit iOS API is introduced in iOS 27 and Xcode 27. This project
has been compiled successfully with Xcode 27.0 and the iPhoneOS 27.0 SDK. The
implementation was checked against Apple's official iOS 27 sample, *Capturing
screen content on iOS*. It uses ScreenCaptureKit and contains no ReplayKit
fallback.

Apple's sample includes a `com.apple.developer.screen-recording` entitlement,
but Apple's automatic-signing service rejects that key for the current team as
an invalid entitlement. The capture probe therefore relies on the documented
`NSScreenCaptureUsageDescription` permission and system content-sharing picker.
Physical-device validation must confirm whether this team also needs access to
a managed Screen Recording capability.

## Build

1. Install Xcode 27 or later.
2. Open `ios/MultiAudioIOS/MultiAudioIOS.xcodeproj`.
3. Select the `MultiAudioIOS` target and choose your Apple Development team.
4. If the default bundle identifier is already taken, replace
   `com.skandavyas.multipoint.ios` with a unique identifier.
5. Connect an iPhone running iOS 27 or later and select it as the run
   destination. The simulator is not a valid capture test.
6. Build and run.

Command-line compile check after Xcode 27 is selected:

```sh
xcodebuild \
  -project ios/MultiAudioIOS/MultiAudioIOS.xcodeproj \
  -scheme MultiAudioIOS \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Physical-device validation

1. Tap **Start Capture**.
2. Approve full-display capture in Apple's system picker.
3. Start audio in another app.
4. Return to MultiAudio if desired. The capture should survive backgrounding
   because the target declares the `screen-capture` background mode.
5. Confirm the audio-buffer count and latest format/timing values update.
   With no audio playing, RMS and peak should read `−∞ dBFS` or a very low
   level. Playing unprotected audio should make both levels rise visibly.
6. Inspect Console for `MultiAudioCapture` entries. The first audio buffer and
   periodic samples include sample rate, channel count, PCM format flags, frame
   count, presentation timestamp, and duration. Audio bytes are never logged.
7. Tap **Stop Capture** to end the stream.

## Expected behavior and limitations

- Screen buffers are required as a stream output but are immediately discarded.
- System audio arrives through `SCStreamOutputType.audio`; microphone capture is
  not enabled for this experiment.
- The requested capture format is 48 kHz stereo. The app logs the actual format
  delivered by the framework.
- Protected media may be absent or silenced by the source app or platform
  policy. Validate each important source on the physical device.
- No PCM conversion, buffering, UDP transport, receiver, or audio playback is
  implemented yet.
