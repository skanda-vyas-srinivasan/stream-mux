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
