import AudioToolbox
import CoreMedia
import Foundation
import Network

struct TransportSnapshot: Sendable {
    let packetsSent: UInt64
    let queueDrops: UInt64
    let conversionDrops: UInt64
    let state: String
    let captureHostRate: Double
    let captureMediaRate: Double
    let maxCallbackGapMS: Double
    let maxPTSErrorMS: Double
    let packetRate: Double
    let currentQueueDepth: Int
    let maxQueueDepth: Int
    let pacingUnderruns: UInt64
    let sendFailures: UInt64
    let maxSendGapMS: Double
    let sendGapEvents: UInt64
    let captureDiscontinuities: UInt64
    let staleCaptureDrops: UInt64
    let captureIngressDrops: UInt64
}

final class AudioTransportPipeline: @unchecked Sendable {
    private final class QueuedCapture: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let callbackTimestampNS: UInt64
        let completion: @Sendable (AudioBufferMetadata, TransportSnapshot) -> Void

        init(
            sampleBuffer: CMSampleBuffer,
            callbackTimestampNS: UInt64,
            completion: @escaping @Sendable (AudioBufferMetadata, TransportSnapshot) -> Void
        ) {
            self.sampleBuffer = sampleBuffer
            self.callbackTimestampNS = callbackTimestampNS
            self.completion = completion
        }
    }

    private let sender = UDPAudioSender(capacity: 256)
    private var packetizer = AudioPacketizer()
    private let processingQueue = DispatchQueue(
        label: "com.skandavyas.multipoint.audio-processing",
        qos: .userInteractive
    )
    private let ingressLock = NSLock()
    private var queuedCaptures: [QueuedCapture] = []
    private var processingScheduled = false
    private let statsLock = NSLock()
    private var conversionDrops: UInt64 = 0
    private var totalFrames: UInt64 = 0
    private var firstFrameCount: UInt64 = 0
    private var firstHostTimeNS: UInt64?
    private var lastHostTimeNS: UInt64?
    private var firstPTSSeconds: Double?
    private var lastPTSEndSeconds: Double?
    private var maxCallbackGapNS: UInt64 = 0
    private var maxPTSErrorSeconds: Double = 0
    private var minimumCaptureOffsetSeconds: Double?
    private var recoveringFromDiscontinuity = false
    private var freshCaptureSinceNS: UInt64?
    private var freshCapturePTSSeconds: Double?
    private var captureDiscontinuities: UInt64 = 0
    private var staleCaptureDrops: UInt64 = 0
    private var captureIngressDrops: UInt64 = 0

    // Short gaps belong to normal jitter/FEC recovery. Longer capture gaps
    // mean ScreenCaptureKit has stopped delivering real-time audio.
    private static let discontinuityThresholdNS: UInt64 = 250_000_000
    private static let maximumCaptureAgeSeconds = 0.150
    // Resume only after PTS and host time have advanced together long enough
    // to prove that ScreenCaptureKit's post-stall catch-up burst has ended.
    private static let recoveryStablePeriodNS: UInt64 = 500_000_000
    private static let recoveryTimelineToleranceSeconds = 0.040
    private static let maximumQueuedCaptures = 8

    func start(host: String, port: UInt16) {
        processingQueue.sync {
            ingressLock.withLock {
                queuedCaptures.removeAll(keepingCapacity: true)
                processingScheduled = false
            }
            packetizer.reset()
            statsLock.withLock {
                conversionDrops = 0
                totalFrames = 0
                firstFrameCount = 0
                firstHostTimeNS = nil
                lastHostTimeNS = nil
                firstPTSSeconds = nil
                lastPTSEndSeconds = nil
                maxCallbackGapNS = 0
                maxPTSErrorSeconds = 0
                minimumCaptureOffsetSeconds = nil
                recoveringFromDiscontinuity = false
                freshCaptureSinceNS = nil
                freshCapturePTSSeconds = nil
                captureDiscontinuities = 0
                staleCaptureDrops = 0
                captureIngressDrops = 0
            }
            sender.start(host: host, port: port)
        }
    }

    func stop() {
        ingressLock.withLock {
            queuedCaptures.removeAll(keepingCapacity: true)
        }
        processingQueue.sync {
            sender.stop()
            packetizer.reset()
        }
    }

    // The ScreenCaptureKit callback retains and enqueues the buffer, then
    // returns. Conversion, metering, FEC, and network queueing happen only on
    // processingQueue so capture delivery never waits for transport work.
    func submit(
        _ sampleBuffer: CMSampleBuffer,
        callbackTimestampNS: UInt64,
        completion: @escaping @Sendable (AudioBufferMetadata, TransportSnapshot) -> Void
    ) {
        let capture = QueuedCapture(
            sampleBuffer: sampleBuffer,
            callbackTimestampNS: callbackTimestampNS,
            completion: completion
        )
        var droppedCapture = false
        let shouldSchedule = ingressLock.withLock {
            if queuedCaptures.count == Self.maximumQueuedCaptures {
                queuedCaptures.removeFirst()
                droppedCapture = true
            }
            queuedCaptures.append(capture)
            if processingScheduled { return false }
            processingScheduled = true
            return true
        }
        if droppedCapture {
            statsLock.withLock { captureIngressDrops &+= 1 }
        }
        if shouldSchedule {
            processingQueue.async { [weak self] in self?.drainCaptures() }
        }
    }

    private func drainCaptures() {
        while let capture = ingressLock.withLock({ () -> QueuedCapture? in
            guard !queuedCaptures.isEmpty else {
                processingScheduled = false
                return nil
            }
            return queuedCaptures.removeFirst()
        }) {
            let metadata = AudioBufferMetadata(sampleBuffer: capture.sampleBuffer)
            let transport = consume(
                capture.sampleBuffer,
                callbackTimestampNS: capture.callbackTimestampNS
            )
            capture.completion(metadata, transport)
        }
    }

    private func consume(
        _ sampleBuffer: CMSampleBuffer,
        callbackTimestampNS timestamp: UInt64
    ) -> TransportSnapshot {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        let frameCount = UInt64(CMSampleBufferGetNumSamples(sampleBuffer))
        var discardTransport = false
        var resumeWithNewStream = false
        var dropAsStale = false
        statsLock.withLock {
            var callbackDiscontinuity = false
            if firstHostTimeNS == nil {
                firstHostTimeNS = timestamp
                firstFrameCount = frameCount
            }
            if let lastHostTimeNS {
                let callbackGap = timestamp - lastHostTimeNS
                maxCallbackGapNS = max(maxCallbackGapNS, callbackGap)
                callbackDiscontinuity = callbackGap > Self.discontinuityThresholdNS
            }
            if firstPTSSeconds == nil, pts.isFinite {
                firstPTSSeconds = pts
            }
            var ptsDiscontinuity = false
            if let expectedPTS = lastPTSEndSeconds, pts.isFinite {
                let ptsError = abs(pts - expectedPTS)
                maxPTSErrorSeconds = max(maxPTSErrorSeconds, ptsError)
                ptsDiscontinuity = ptsError > Self.maximumCaptureAgeSeconds
            }

            var captureAgeSeconds = 0.0
            var captureOffsetSeconds: Double?
            if pts.isFinite {
                let hostSeconds = Double(timestamp) / 1_000_000_000
                let offset = hostSeconds - pts
                captureOffsetSeconds = offset
                if let minimumCaptureOffsetSeconds {
                    if offset < minimumCaptureOffsetSeconds {
                        self.minimumCaptureOffsetSeconds = offset
                    }
                    captureAgeSeconds = max(0, offset - minimumCaptureOffsetSeconds)
                } else {
                    minimumCaptureOffsetSeconds = offset
                }
            }

            let captureIsUnstable = callbackDiscontinuity || ptsDiscontinuity ||
                captureAgeSeconds > Self.maximumCaptureAgeSeconds
            if captureIsUnstable && !recoveringFromDiscontinuity {
                recoveringFromDiscontinuity = true
                freshCaptureSinceNS = nil
                freshCapturePTSSeconds = nil
                captureDiscontinuities &+= 1
                discardTransport = true
                // ScreenCaptureKit may permanently omit media time during the
                // stall. Rebase this epoch so a live-but-shifted PTS timeline
                // can pass the clean-window check instead of staying stale
                // forever relative to the previous epoch.
                minimumCaptureOffsetSeconds = captureOffsetSeconds
            }
            if recoveringFromDiscontinuity {
                if captureIsUnstable {
                    freshCaptureSinceNS = nil
                    freshCapturePTSSeconds = nil
                } else if pts.isFinite {
                    if freshCaptureSinceNS == nil || freshCapturePTSSeconds == nil {
                        freshCaptureSinceNS = timestamp
                        freshCapturePTSSeconds = pts
                    }
                    if let freshCaptureSinceNS, let freshCapturePTSSeconds {
                        let hostProgress = Double(timestamp - freshCaptureSinceNS) /
                            1_000_000_000
                        let mediaProgress = pts - freshCapturePTSSeconds
                        let timelineError = abs(mediaProgress - hostProgress)
                        if mediaProgress < 0 || timelineError >
                            Self.recoveryTimelineToleranceSeconds {
                            // PTS is still catching up faster than buffers are
                            // arriving. Start a new candidate stability window.
                            self.freshCaptureSinceNS = timestamp
                            self.freshCapturePTSSeconds = pts
                        } else if timestamp - freshCaptureSinceNS >=
                            Self.recoveryStablePeriodNS {
                            recoveringFromDiscontinuity = false
                            self.freshCaptureSinceNS = nil
                            self.freshCapturePTSSeconds = nil
                            resumeWithNewStream = true
                        }
                    }
                }
                if recoveringFromDiscontinuity {
                    staleCaptureDrops &+= 1
                    dropAsStale = true
                }
            }

            if pts.isFinite, duration.isFinite {
                lastPTSEndSeconds = pts + duration
            }
            totalFrames &+= frameCount
            lastHostTimeNS = timestamp
        }

        if discardTransport {
            sender.discardQueued()
        }
        if resumeWithNewStream {
            sender.discardQueued()
            packetizer.reset()
        }
        if dropAsStale { return snapshot() }

        guard let samples = PCMExtractor.interleavedFloatStereo48k(from: sampleBuffer) else {
            statsLock.withLock { conversionDrops &+= 1 }
            return snapshot()
        }
        for datagram in packetizer.consume(samples, senderTimestampNS: timestamp) {
            sender.enqueue(datagram)
        }
        return snapshot()
    }

    func snapshot() -> TransportSnapshot {
        let network = sender.snapshot()
        let diagnostics = statsLock.withLock {
            let hostElapsed: Double
            if let firstHostTimeNS, let lastHostTimeNS, lastHostTimeNS > firstHostTimeNS {
                hostElapsed = Double(lastHostTimeNS - firstHostTimeNS) / 1_000_000_000
            } else {
                hostElapsed = 0
            }
            let framesAfterFirst = totalFrames >= firstFrameCount
                ? totalFrames - firstFrameCount
                : 0
            let hostRate = hostElapsed > 0 ? Double(framesAfterFirst) / hostElapsed : 0

            let mediaElapsed: Double
            if let firstPTSSeconds, let lastPTSEndSeconds,
               lastPTSEndSeconds > firstPTSSeconds {
                mediaElapsed = lastPTSEndSeconds - firstPTSSeconds
            } else {
                mediaElapsed = 0
            }
            let mediaRate = mediaElapsed > 0 ? Double(totalFrames) / mediaElapsed : 0
            let packetRate = hostElapsed > 0 ? Double(network.packetsSent) / hostElapsed : 0
            return (
                conversionDrops,
                hostRate,
                mediaRate,
                Double(maxCallbackGapNS) / 1_000_000,
                maxPTSErrorSeconds * 1_000,
                packetRate,
                network.currentQueueDepth,
                network.maxQueueDepth,
                network.pacingUnderruns,
                network.sendFailures,
                network.maxSendGapMS,
                network.sendGapEvents,
                captureDiscontinuities,
                staleCaptureDrops,
                captureIngressDrops
            )
        }
        return TransportSnapshot(
            packetsSent: network.packetsSent,
            queueDrops: network.queueDrops,
            conversionDrops: diagnostics.0,
            state: network.state,
            captureHostRate: diagnostics.1,
            captureMediaRate: diagnostics.2,
            maxCallbackGapMS: diagnostics.3,
            maxPTSErrorMS: diagnostics.4,
            packetRate: diagnostics.5,
            currentQueueDepth: diagnostics.6,
            maxQueueDepth: diagnostics.7,
            pacingUnderruns: diagnostics.8,
            sendFailures: diagnostics.9,
            maxSendGapMS: diagnostics.10,
            sendGapEvents: diagnostics.11,
            captureDiscontinuities: diagnostics.12,
            staleCaptureDrops: diagnostics.13,
            captureIngressDrops: diagnostics.14
        )
    }
}

private final class AudioPacketizer {
    private var engine: MPSenderEngineRef?

    init() {
        engine = MPSenderEngineCreate(UInt64.random(in: 1...UInt64.max))
    }

    deinit {
        MPSenderEngineDestroy(engine)
    }

    func reset() {
        guard let engine else { return }
        _ = MPSenderEngineReset(
            engine,
            UInt64.random(in: 1...UInt64.max)
        )
    }

    func consume(
        _ samples: [Float],
        senderTimestampNS: UInt64
    ) -> [Data] {
        guard let engine, !samples.isEmpty else { return [] }
        let packetSamples = Int(MPAudioSamplesPerPacket)
        // The C++ engine may begin with one partial packet and may release five
        // delayed parity datagrams whenever a ten-packet FEC group completes.
        let maximumAudioPackets = samples.count / packetSamples + 2
        let maximumParityPackets =
            ((maximumAudioPackets + Int(MPAudioFECDataShards) - 1) /
                Int(MPAudioFECDataShards)) * Int(MPAudioFECParityShards)
        let capacity = maximumAudioPackets + maximumParityPackets
        var output = Data(count: capacity * Int(MPAudioDatagramSize))
        var datagramCount = 0
        let encoded = samples.withUnsafeBufferPointer { samplesBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                MPSenderEnginePush(
                    engine,
                    samplesBuffer.baseAddress,
                    samples.count,
                    senderTimestampNS,
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                    outputBuffer.count,
                    &datagramCount
                )
            }
        }
        guard encoded else { return [] }

        let datagramSize = Int(MPAudioDatagramSize)
        return (0..<datagramCount).map { index in
            let start = index * datagramSize
            return output.subdata(in: start..<(start + datagramSize))
        }
    }
}

private final class UDPAudioSender: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var slots: [Data?]
    private var head = 0
    private var tail = 0
    private var count = 0
    private var packetsSent: UInt64 = 0
    private var queueDrops: UInt64 = 0
    private var maxQueueDepth = 0
    private var pacingUnderruns: UInt64 = 0
    private var sendFailures: UInt64 = 0
    private var lastSendTimeNS: UInt64?
    private var maxSendGapNS: UInt64 = 0
    private var sendGapEvents: UInt64 = 0
    private var drainScheduled = false
    private var state = "Stopped"
    private var connection: NWConnection?

    init(capacity: Int) {
        slots = Array(repeating: nil, count: capacity)
        queue = DispatchQueue(label: "com.skandavyas.multipoint.udp-sender", qos: .userInteractive)
    }

    func start(host: String, port: UInt16) {
        stop()
        lock.withLock {
            head = 0
            tail = 0
            count = 0
            packetsSent = 0
            queueDrops = 0
            maxQueueDepth = 0
            pacingUnderruns = 0
            sendFailures = 0
            lastSendTimeNS = nil
            maxSendGapNS = 0
            sendGapEvents = 0
            drainScheduled = false
            state = "Starting"
        }

        let endpointHost = NWEndpoint.Host(host)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            lock.withLock { state = "Failed: invalid UDP port" }
            return
        }
        let newConnection = NWConnection(
            host: endpointHost,
            port: endpointPort,
            using: .udp
        )
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
            guard let self, let newConnection,
                  self.connection === newConnection else { return }
            self.lock.withLock {
                switch newState {
                case .setup:
                    self.state = "Starting"
                case .preparing:
                    self.state = "Preparing route"
                case .ready:
                    self.state = "Ready"
                case .waiting(let error):
                    self.state = "Waiting: \(error)"
                case .failed(let error):
                    self.state = "Failed: \(error)"
                case .cancelled:
                    self.state = "Stopped"
                @unknown default:
                    self.state = "Unknown network state"
                }
            }
        }
        queue.sync {
            connection = newConnection
            newConnection.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
        }
        lock.withLock {
            drainScheduled = false
            state = "Stopped"
        }
    }

    func enqueue(_ datagram: Data) {
        let shouldSchedule = lock.withLock {
            if count == slots.count {
                // Evict the oldest packet, not the live packet that just
                // arrived. This bounds latency during a transport stall.
                slots[head] = nil
                head = (head + 1) % slots.count
                count -= 1
                queueDrops &+= 1
            }
            slots[tail] = datagram
            tail = (tail + 1) % slots.count
            count += 1
            maxQueueDepth = max(maxQueueDepth, count)
            if drainScheduled { return false }
            drainScheduled = true
            return true
        }
        if shouldSchedule {
            queue.async { [weak self] in self?.drainAvailablePackets() }
        }
    }

    func discardQueued() {
        lock.withLock {
            queueDrops &+= UInt64(count)
            for index in slots.indices { slots[index] = nil }
            head = 0
            tail = 0
            count = 0
        }
    }

    func snapshot() -> (
        packetsSent: UInt64,
        queueDrops: UInt64,
        state: String,
        currentQueueDepth: Int,
        maxQueueDepth: Int,
        pacingUnderruns: UInt64,
        sendFailures: UInt64,
        maxSendGapMS: Double,
        sendGapEvents: UInt64
    ) {
        lock.withLock {
            (
                packetsSent,
                queueDrops,
                state,
                count,
                maxQueueDepth,
                pacingUnderruns,
                sendFailures,
                Double(maxSendGapNS) / 1_000_000,
                sendGapEvents
            )
        }
    }

    private func drainAvailablePackets() {
        guard let connection else {
            lock.withLock { drainScheduled = false }
            return
        }
        guard let datagram = dequeueForDrain() else {
            lock.withLock { drainScheduled = false }
            return
        }

        connection.send(content: datagram, completion: .contentProcessed {
            [weak self, weak connection] error in
            guard let self, let connection,
                  self.connection === connection else { return }
            if let error {
                self.lock.withLock {
                    self.sendFailures &+= 1
                    self.drainScheduled = false
                    self.state = "Send failed: \(error)"
                }
                return
            }

            self.lock.withLock {
                let now = DispatchTime.now().uptimeNanoseconds
                if let lastSendTimeNS = self.lastSendTimeNS {
                    let gap = now - lastSendTimeNS
                    self.maxSendGapNS = max(self.maxSendGapNS, gap)
                    if gap >= 10_000_000 { self.sendGapEvents &+= 1 }
                }
                self.lastSendTimeNS = now
                self.packetsSent &+= 1
                self.state = "Ready"
            }
            self.drainAvailablePackets()
        })
    }

    private func dequeueForDrain() -> Data? {
        lock.withLock {
            guard count > 0 else { return nil }
            let datagram = slots[head]
            slots[head] = nil
            head = (head + 1) % slots.count
            count -= 1
            return datagram
        }
    }
}

private enum PCMExtractor {
    static func interleavedFloatStereo48k(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let formatPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }
        let format = formatPointer.pointee
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mSampleRate == 48_000,
              format.mChannelsPerFrame == 2
        else { return nil }

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
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        var output = Array(repeating: Float.zero, count: frames * 2)

        let copied = withUnsafeTemporaryAllocation(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ) { storage -> Bool in
            guard let baseAddress = storage.baseAddress else { return false }
            let list = baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            var retainedBlockBuffer: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: list,
                bufferListSize: requiredSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                blockBufferOut: &retainedBlockBuffer
            ) == noErr else { return false }

            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let isSigned = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            if buffers.count == 1, let data = buffers[0].mData {
                if isFloat && format.mBitsPerChannel == 32 {
                    let source = data.assumingMemoryBound(to: Float.self)
                    for index in output.indices { output[index] = source[index] }
                    return true
                }
                if isSigned && format.mBitsPerChannel == 16 {
                    let source = data.assumingMemoryBound(to: Int16.self)
                    for index in output.indices {
                        output[index] = Float(source[index]) / 32_768.0
                    }
                    return true
                }
            }

            guard buffers.count >= 2 else { return false }
            for channel in 0..<2 {
                guard let data = buffers[channel].mData else { return false }
                if isFloat && format.mBitsPerChannel == 32 {
                    let source = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { output[frame * 2 + channel] = source[frame] }
                } else if isSigned && format.mBitsPerChannel == 16 {
                    let source = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frames {
                        output[frame * 2 + channel] = Float(source[frame]) / 32_768.0
                    }
                } else {
                    return false
                }
            }
            return true
        }
        return copied ? output : nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
