#include "wasapi_output.h"

#ifndef _WIN32
#error "wasapi_output.cpp is only for Windows"
#endif

#include "multipoint/protocol/audio_packet.h"

#include <audioclient.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <future>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>

namespace soundmux::windows {
namespace {

void check_hresult(HRESULT result, const char *operation) {
  if (FAILED(result)) {
    throw std::runtime_error(
        std::string(operation) + " failed: HRESULT " +
        std::to_string(static_cast<unsigned long>(result)));
  }
}

template <typename Interface> class ComPtr {
public:
  ~ComPtr() { reset(); }
  ComPtr() = default;
  ComPtr(const ComPtr &) = delete;
  ComPtr &operator=(const ComPtr &) = delete;

  [[nodiscard]] Interface *get() const { return value_; }
  Interface **put() {
    reset();
    return &value_;
  }
  Interface *operator->() const { return value_; }

private:
  void reset() {
    if (value_)
      value_->Release();
    value_ = nullptr;
  }
  Interface *value_ = nullptr;
};

class ScopedHandle {
public:
  explicit ScopedHandle(HANDLE value) : value_(value) {
    if (!value_)
      throw std::runtime_error("create Windows event");
  }
  ~ScopedHandle() { CloseHandle(value_); }
  ScopedHandle(const ScopedHandle &) = delete;
  ScopedHandle &operator=(const ScopedHandle &) = delete;
  [[nodiscard]] HANDLE get() const { return value_; }

private:
  HANDLE value_ = nullptr;
};

} // namespace

struct WasapiOutput::Impl {
  Impl()
      : ring(48'000, multipoint::protocol::kChannelCount),
        audio_event(CreateEventW(nullptr, FALSE, FALSE, nullptr)),
        stop_event(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {
    std::promise<void> ready;
    auto result = ready.get_future();
    thread = std::thread([this, promise = std::move(ready)]() mutable {
      run(std::move(promise));
    });
    try {
      result.get();
    } catch (...) {
      SetEvent(stop_event.get());
      if (thread.joinable())
        thread.join();
      throw;
    }
  }

  ~Impl() {
    SetEvent(stop_event.get());
    if (thread.joinable())
      thread.join();
  }

  void run(std::promise<void> ready) {
    bool announced = false;
    auto announce_error = [&](std::exception_ptr error) {
      if (!announced) {
        announced = true;
        ready.set_exception(error);
      }
    };
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(initialized)) {
      announce_error(std::make_exception_ptr(
          std::runtime_error("initialize COM for WASAPI")));
      return;
    }
    try {
      ComPtr<IMMDeviceEnumerator> enumerator;
      check_hresult(
          CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                           __uuidof(IMMDeviceEnumerator),
                           reinterpret_cast<void **>(enumerator.put())),
          "create audio endpoint enumerator");
      ComPtr<IMMDevice> device;
      check_hresult(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia,
                                                        device.put()),
                    "get default audio output");
      ComPtr<IAudioClient> client;
      check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL,
                                     nullptr,
                                     reinterpret_cast<void **>(client.put())),
                    "open default audio output");

      WAVEFORMATEXTENSIBLE format{};
      format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
      format.Format.nChannels = 2;
      format.Format.nSamplesPerSec = multipoint::protocol::kSampleRate;
      format.Format.wBitsPerSample = 32;
      format.Format.nBlockAlign =
          format.Format.nChannels * format.Format.wBitsPerSample / 8;
      format.Format.nAvgBytesPerSec =
          format.Format.nSamplesPerSec * format.Format.nBlockAlign;
      format.Format.cbSize =
          sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
      format.Samples.wValidBitsPerSample = 32;
      format.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
      format.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

      constexpr DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                              AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                              AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
      check_hresult(client->Initialize(
                        AUDCLNT_SHAREMODE_SHARED, flags, 0, 0,
                        reinterpret_cast<WAVEFORMATEX *>(&format), nullptr),
                    "initialize shared-mode WASAPI output");
      check_hresult(client->SetEventHandle(audio_event.get()),
                    "set WASAPI render event");
      UINT32 buffer_frames = 0;
      check_hresult(client->GetBufferSize(&buffer_frames),
                    "get WASAPI buffer size");
      ComPtr<IAudioRenderClient> render;
      check_hresult(client->GetService(__uuidof(IAudioRenderClient),
                                       reinterpret_cast<void **>(render.put())),
                    "get WASAPI render client");

      BYTE *initial = nullptr;
      check_hresult(render->GetBuffer(buffer_frames, &initial),
                    "prime WASAPI buffer");
      check_hresult(
          render->ReleaseBuffer(buffer_frames, AUDCLNT_BUFFERFLAGS_SILENT),
          "release initial WASAPI buffer");
      check_hresult(client->Start(), "start WASAPI output");
      announced = true;
      ready.set_value();

      const HANDLE waits[] = {stop_event.get(), audio_event.get()};
      while (WaitForMultipleObjects(2, waits, FALSE, INFINITE) ==
             WAIT_OBJECT_0 + 1) {
        UINT32 padding = 0;
        check_hresult(client->GetCurrentPadding(&padding),
                      "get WASAPI padding");
        const UINT32 available = buffer_frames - padding;
        if (available == 0)
          continue;
        BYTE *output = nullptr;
        check_hresult(render->GetBuffer(available, &output),
                      "get WASAPI render buffer");
        if (!playing.load(std::memory_order_acquire)) {
          check_hresult(
              render->ReleaseBuffer(available, AUDCLNT_BUFFERFLAGS_SILENT),
              "release silent WASAPI buffer");
          continue;
        }
        auto *samples = reinterpret_cast<float *>(output);
        ring.read(samples, available);
        const float level = volume.load(std::memory_order_relaxed);
        if (level != 1.0F) {
          const auto sample_count = static_cast<std::size_t>(available) * 2;
          for (std::size_t index = 0; index < sample_count; ++index) {
            samples[index] *= level;
          }
        }
        check_hresult(render->ReleaseBuffer(available, 0),
                      "release WASAPI render buffer");
      }
      client->Stop();
    } catch (...) {
      announce_error(std::current_exception());
    }
    CoUninitialize();
  }

  multipoint::audio::SpscAudioRing ring;
  std::atomic<bool> playing{false};
  std::atomic<float> volume{1.0F};
  ScopedHandle audio_event;
  ScopedHandle stop_event;
  std::thread thread;
};

WasapiOutput::WasapiOutput() : impl_(std::make_unique<Impl>()) {}
WasapiOutput::~WasapiOutput() = default;

std::size_t WasapiOutput::available_to_read() const {
  return impl_->ring.available_to_read();
}

std::size_t WasapiOutput::available_to_write() const {
  return impl_->ring.available_to_write();
}

std::size_t WasapiOutput::write(const float *interleaved, std::size_t frames) {
  return impl_->ring.write(interleaved, frames);
}

void WasapiOutput::discard() { impl_->ring.discard(); }

void WasapiOutput::set_playing(bool playing) {
  impl_->playing.store(playing, std::memory_order_release);
}

bool WasapiOutput::playing() const {
  return impl_->playing.load(std::memory_order_acquire);
}

void WasapiOutput::set_volume(float volume) {
  impl_->volume.store(std::clamp(volume, 0.0F, 1.0F),
                      std::memory_order_relaxed);
}

std::uint64_t WasapiOutput::underruns() const {
  return impl_->ring.underruns();
}

} // namespace soundmux::windows
