# SoundMux Windows receiver

The first Windows target is a standalone encrypted receiver for audio sent by
the existing macOS SoundMux application. It deliberately runs outside audio
engine and APO processes.

## Build

From a Visual Studio 2022 Developer PowerShell on Windows 11:

```powershell
cmake -S . -B build-windows -A x64 -DCMAKE_BUILD_TYPE=Release
cmake --build build-windows --config Release
ctest --test-dir build-windows -C Release --output-on-failure
```

Run the receiver with the default UDP port `48100` and 100 ms latency:

```powershell
.\build-windows\windows\Release\soundmux_windows_receiver.exe
```

The optional arguments are `[port] [latency-ms]`.

On the Mac, open SoundMux, choose **Send Audio**, select **Manual address…**,
and enter the Windows machine's reachable IP address and receiver port. Approve
the matching six-digit code in the Windows terminal. Windows Defender Firewall
may request permission for private networks on first launch.

The receiver stores its stable identity and trusted sender keys under the
current user's `HKCU\Software\SoundMux\Receiver` registry key. Its private
identity key is encrypted with Windows DPAPI before storage.

Automatic DNS-SD discovery and the native Windows UI are later milestones. See
[`docs/windows-receiver-acceptance.md`](../docs/windows-receiver-acceptance.md)
for the complete acceptance gate.
