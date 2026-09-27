# Tests

`multipoint_core_tests` covers packet serialization/rejection, Reed-Solomon
recovery, sender packetization and epoch reset, receiver FEC and epoch handling,
sequence-gap resynchronization, sequence wraparound, jitter reorder/loss/latency
recovery, and the single-producer/single-consumer audio ring.

Run it with:

```sh
ctest --test-dir build --output-on-failure
```

Physical ScreenCaptureKit, Network.framework, and audio-output behavior remains
device integration testing rather than part of this portable suite.

On macOS, the same command also runs `soundmux_capture_conversion_tests` against
the AudioToolbox capture converter. It checks 32/44.1/48/88.2/96/192 kHz input,
duration and pitch, stereo separation, anti-aliasing, bit-exact 48 kHz bypass,
irregular input/output chunks, starvation/resumption, invalid input, and the
resulting PCM16 packets. It requires no capture permission or physical device.
