@preconcurrency import AVFAudio
import Combine
import Foundation

@MainActor
final class MicrophoneCaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Idle"
    @Published private(set) var audioBufferCount: UInt64 = 0
    @Published private(set) var latestFormat: String?
    @Published private(set) var latestRMSLevel = "—"
    @Published private(set) var latestPeakLevel = "—"
    @Published var receiverHost: String {
        didSet { UserDefaults.standard.set(receiverHost, forKey: "receiverHost") }
    }
    @Published var receiverPort: String {
        didSet { UserDefaults.standard.set(receiverPort, forKey: "receiverPort") }
    }
    @Published private(set) var transportState = "Stopped"
    @Published private(set) var packetsSent: UInt64 = 0
    @Published private(set) var queueDrops: UInt64 = 0
    @Published private(set) var conversionDrops: UInt64 = 0
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private let captureQueue = DispatchQueue(
        label: "com.skandavyas.soundmux.microphone-capture",
        qos: .userInteractive
    )
    nonisolated(unsafe) private var converter: AVAudioConverter?
    private var microphoneTapInstalled = false
    nonisolated private let transportPipeline = AudioTransportPipeline()

    init() {
        receiverHost = UserDefaults.standard.string(forKey: "receiverHost") ?? "10.0.0.14"
        receiverPort = UserDefaults.standard.string(forKey: "receiverPort") ?? "48100"
    }

    func startStreaming() {
        guard !receiverHost.isEmpty,
              let port = UInt16(receiverPort), port > 0 else {
            errorMessage = "Enter the Mac's IP address and a valid UDP port."
            return
        }
        guard !isCapturing else { return }
        errorMessage = nil
        status = "Requesting microphone access"

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.status = "Microphone access denied"
                    self.errorMessage = "Allow microphone access in Settings to use the iPhone as a Mac input."
                    return
                }
                self.beginMicrophoneCapture(host: self.receiverHost, port: port)
            }
        }
    }

    private func beginMicrophoneCapture(host: String, port: UInt16) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.010)
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48_000,
                    channels: 1,
                    interleaved: false
                  ),
                  let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw MicrophoneCaptureError.unsupportedFormat
            }
            self.converter = converter
            transportPipeline.start(host: host, port: port)
            transportState = "Connecting securely"
            audioBufferCount = 0
            latestFormat = "48,000 Hz, mono microphone → stereo transport"

            input.installTap(onBus: 0, bufferSize: 480, format: inputFormat) {
                [weak self] buffer, _ in
                guard let self else { return }
                self.captureQueue.async { [weak self] in self?.consume(buffer) }
            }
            microphoneTapInstalled = true
            engine.prepare()
            try engine.start()
            isCapturing = true
            status = "Streaming iPhone microphone"
        } catch {
            if microphoneTapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                microphoneTapInstalled = false
            }
            transportPipeline.stop()
            captureQueue.sync { converter = nil }
            status = "Microphone capture failed"
            errorMessage = error.localizedDescription
            try? AVAudioSession.sharedInstance().setActive(false)
        }
    }

    func stopCapture() async {
        if engine.isRunning { engine.stop() }
        if microphoneTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        captureQueue.sync { converter = nil }
        transportPipeline.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        transportState = "Stopped"
        isCapturing = false
        status = "Idle"
    }

    nonisolated private func consume(_ input: AVAudioPCMBuffer) {
        guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
              ) else { return }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity),
              let converter else { return }
        var supplied = false
        var conversionError: NSError?
        let result = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard result != .error, conversionError == nil,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }

        let frames = Int(output.frameLength)
        var stereo = Array(repeating: Float.zero, count: frames * 2)
        var sum = 0.0
        var peak = Float.zero
        for frame in 0..<frames {
            let sample = channel[frame]
            stereo[frame * 2] = sample
            stereo[frame * 2 + 1] = sample
            sum += Double(sample * sample)
            peak = max(peak, abs(sample))
        }
        let rms = sqrt(sum / Double(frames))
        let rmsDB = rms > 0 ? 20 * log10(rms) : -.infinity
        let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        transportPipeline.submitInterleavedFloatStereo48k(
            stereo,
            callbackTimestampNS: DispatchTime.now().uptimeNanoseconds
        ) { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioBufferCount &+= 1
                self.packetsSent = snapshot.packetsSent
                self.queueDrops = snapshot.queueDrops
                self.conversionDrops = snapshot.conversionDrops
                self.transportState = snapshot.state
                self.latestRMSLevel = Self.level(rmsDB)
                self.latestPeakLevel = Self.level(peakDB)
            }
        }
    }

    private static func level(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f dBFS", value) : "−∞ dBFS"
    }
}

private enum MicrophoneCaptureError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "The active iPhone microphone format could not be converted to SoundMux audio."
    }
}

