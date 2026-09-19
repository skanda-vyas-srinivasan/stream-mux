import Combine
import AudioToolbox
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class CaptureManager: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Idle"
    @Published private(set) var audioBufferCount: UInt64 = 0
    @Published private(set) var latestFormat: String?
    @Published private(set) var latestFrameCount = 0
    @Published private(set) var latestPTS = "—"
    @Published private(set) var latestDuration = "—"
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
    @Published private(set) var captureHostRate = "—"
    @Published private(set) var captureMediaRate = "—"
    @Published private(set) var maxCallbackGap = "—"
    @Published private(set) var maxPTSError = "—"
    @Published private(set) var packetRate = "—"
    @Published private(set) var maxQueueDepth = 0
    @Published private(set) var pacingUnderruns: UInt64 = 0
    @Published private(set) var captureDiscontinuities: UInt64 = 0
    @Published private(set) var staleCaptureDrops: UInt64 = 0
    @Published private(set) var captureIngressDrops: UInt64 = 0
    @Published var errorMessage: String?

    private let picker = SCContentSharingPicker.shared
    private let sampleQueue = DispatchQueue(
        label: "com.skandavyas.multipoint.capture.samples",
        qos: .userInteractive
    )
    private var pickerObserver: CapturePickerObserver?
    private var stream: SCStream?
    nonisolated private let transportPipeline = AudioTransportPipeline()

    override init() {
        receiverHost = UserDefaults.standard.string(forKey: "receiverHost") ?? "10.0.0.14"
        receiverPort = UserDefaults.standard.string(forKey: "receiverPort") ?? "48100"
        super.init()
        pickerObserver = CapturePickerObserver(manager: self)
    }

    func startStreaming() {
        guard let pickerObserver else { return }
        guard !receiverHost.isEmpty,
              let port = UInt16(receiverPort),
              port > 0
        else {
            errorMessage = "Enter the Mac's IP address and a valid UDP port."
            return
        }
        transportPipeline.start(host: receiverHost, port: port)
        transportState = "Starting"

        var configuration = SCContentSharingPickerConfiguration()
#if os(iOS)
        configuration.showsMicrophoneControl = false
#endif
        picker.defaultConfiguration = configuration

        if !picker.isActive {
            picker.add(pickerObserver)
            picker.isActive = true
        }

        status = "Waiting for approval"
        errorMessage = nil
        picker.present()
    }

    func startCapture(with filter: SCContentFilter) async {
        await tearDownStream()

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = false

        do {
            let newStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )

            // SoundMux transports audio only. Do not attach a screen output:
            // producing frames we immediately discard can contend with audio
            // delivery during app switches and other display activity.
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: sampleQueue
            )

            try await newStream.startCapture()
            stream = newStream
            audioBufferCount = 0
            latestFormat = nil
            isCapturing = true
            status = "Capturing — waiting for audio"
            errorMessage = nil
        } catch {
            transportPipeline.stop()
            status = "Capture failed"
            errorMessage = error.localizedDescription
        }
    }

    func stopCapture() async {
        await tearDownStream()
        transportPipeline.stop()
        transportState = "Stopped"
        isCapturing = false
        status = "Idle"
        picker.isActive = false
        if let pickerObserver {
            picker.remove(pickerObserver)
        }
    }

    private func tearDownStream() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        isCapturing = false
    }

    fileprivate func pickerCancelled() {
        status = "Capture cancelled"
    }

    fileprivate func pickerFailed(_ error: Error) {
        status = "Picker failed"
        errorMessage = error.localizedDescription
    }

    fileprivate func receivedAudio(
        _ metadata: AudioBufferMetadata,
        transport: TransportSnapshot
    ) {
        audioBufferCount &+= 1
        status = "Receiving audio"
        latestFormat = metadata.formatDescription
        latestFrameCount = metadata.frameCount
        latestPTS = metadata.presentationTimestamp
        latestDuration = metadata.duration
        latestRMSLevel = metadata.rmsDescription
        latestPeakLevel = metadata.peakDescription
        packetsSent = transport.packetsSent
        queueDrops = transport.queueDrops
        conversionDrops = transport.conversionDrops
        transportState = transport.state
        captureHostRate = String(format: "%.0f frames/s", transport.captureHostRate)
        captureMediaRate = String(format: "%.0f frames/s", transport.captureMediaRate)
        maxCallbackGap = String(format: "%.1f ms", transport.maxCallbackGapMS)
        maxPTSError = String(format: "%.1f ms", transport.maxPTSErrorMS)
        packetRate = String(format: "%.1f packets/s", transport.packetRate)
        maxQueueDepth = transport.maxQueueDepth
        pacingUnderruns = transport.pacingUnderruns
        captureDiscontinuities = transport.captureDiscontinuities
        staleCaptureDrops = transport.staleCaptureDrops
        captureIngressDrops = transport.captureIngressDrops
    }
}

extension CaptureManager: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }
        let callbackTimestampNS = DispatchTime.now().uptimeNanoseconds
        transportPipeline.submit(
            sampleBuffer,
            callbackTimestampNS: callbackTimestampNS
        ) { [weak self] metadata, transport in
#if DEBUG
            USBMetricLogger.record(metadata: metadata, transport: transport)
#endif
            Task { @MainActor [weak self] in
                self?.receivedAudio(metadata, transport: transport)
            }
        }
    }
}

extension CaptureManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isCapturing = false
            self?.status = "Capture stopped"
            self?.errorMessage = error.localizedDescription
        }
    }
}

struct AudioBufferMetadata: Sendable {
    let sampleRate: Double
    let channelCount: UInt32
    let formatID: String
    let formatFlags: UInt32
    let frameCount: Int
    let presentationTimestampSeconds: Double
    let durationSeconds: Double
    let rmsDBFS: Double?
    let peakDBFS: Double?

    init(sampleBuffer: CMSampleBuffer) {
        let basicDescription: AudioStreamBasicDescription?
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
           let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
            basicDescription = pointer.pointee
        } else {
            basicDescription = nil
        }

        sampleRate = basicDescription?.mSampleRate ?? 0
        channelCount = basicDescription?.mChannelsPerFrame ?? 0
        formatID = Self.fourCharacterCode(basicDescription?.mFormatID ?? 0)
        formatFlags = basicDescription?.mFormatFlags ?? 0
        frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        presentationTimestampSeconds = CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        durationSeconds = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        let levels = Self.measureLevels(
            in: sampleBuffer,
            format: basicDescription
        )
        rmsDBFS = levels?.rmsDBFS
        peakDBFS = levels?.peakDBFS
    }

    var formatDescription: String {
        "\(sampleRate.formatted()) Hz, \(channelCount) ch, \(formatID), flags 0x\(String(formatFlags, radix: 16))"
    }

    var presentationTimestamp: String {
        Self.formatTime(presentationTimestampSeconds)
    }

    var duration: String {
        Self.formatTime(durationSeconds)
    }

    var rmsDescription: String {
        Self.formatLevel(rmsDBFS)
    }

    var peakDescription: String {
        Self.formatLevel(peakDBFS)
    }

    private static func formatTime(_ seconds: Double) -> String {
        seconds.isFinite ? String(format: "%.6f s", seconds) : "invalid"
    }

    private static func formatLevel(_ level: Double?) -> String {
        guard let level else { return "unsupported format" }
        return level.isFinite ? String(format: "%.1f dBFS", level) : "−∞ dBFS"
    }

    private static func measureLevels(
        in sampleBuffer: CMSampleBuffer,
        format: AudioStreamBasicDescription?
    ) -> (rmsDBFS: Double, peakDBFS: Double)? {
        guard let format, format.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        var requiredSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard requiredSize >= MemoryLayout<AudioBufferList>.size else { return nil }

        return withUnsafeTemporaryAllocation(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ) { storage in
            guard let baseAddress = storage.baseAddress else { return nil }
            let audioBufferList = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            var retainedBlockBuffer: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList,
                bufferListSize: requiredSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &retainedBlockBuffer
            )
            guard status == noErr else { return nil }

            var sumOfSquares = 0.0
            var peak = 0.0
            var sampleCount = 0
            let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0

            for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                guard let data = buffer.mData else { continue }
                let byteCount = Int(buffer.mDataByteSize)

                if isFloat && format.mBitsPerChannel == 32 {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for index in 0..<(byteCount / MemoryLayout<Float>.size) {
                        let value = Double(samples[index])
                        guard value.isFinite else { continue }
                        sumOfSquares += value * value
                        peak = max(peak, abs(value))
                        sampleCount += 1
                    }
                } else if isFloat && format.mBitsPerChannel == 64 {
                    let samples = data.assumingMemoryBound(to: Double.self)
                    for index in 0..<(byteCount / MemoryLayout<Double>.size) {
                        let value = samples[index]
                        guard value.isFinite else { continue }
                        sumOfSquares += value * value
                        peak = max(peak, abs(value))
                        sampleCount += 1
                    }
                } else if isSignedInteger && format.mBitsPerChannel == 16 {
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    for index in 0..<(byteCount / MemoryLayout<Int16>.size) {
                        let value = Double(samples[index]) / 32_768.0
                        sumOfSquares += value * value
                        peak = max(peak, abs(value))
                        sampleCount += 1
                    }
                } else if isSignedInteger && format.mBitsPerChannel == 32 {
                    let samples = data.assumingMemoryBound(to: Int32.self)
                    for index in 0..<(byteCount / MemoryLayout<Int32>.size) {
                        let value = Double(samples[index]) / 2_147_483_648.0
                        sumOfSquares += value * value
                        peak = max(peak, abs(value))
                        sampleCount += 1
                    }
                } else {
                    return nil
                }
            }

            guard sampleCount > 0 else { return nil }
            let rms = sqrt(sumOfSquares / Double(sampleCount))
            return (Self.decibels(rms), Self.decibels(peak))
        }
    }

    private static func decibels(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return String(bytes: bytes, encoding: .ascii) ?? "unknown"
        }
        return String(format: "0x%08x", value)
    }
}

private final class CapturePickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private weak var manager: CaptureManager?

    init(manager: CaptureManager) {
        self.manager = manager
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            await self?.manager?.startCapture(with: filter)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            self?.manager?.pickerCancelled()
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.manager?.pickerFailed(error)
        }
    }
}
