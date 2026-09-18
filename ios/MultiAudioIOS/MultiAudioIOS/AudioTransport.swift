import AudioToolbox
import CoreMedia
import Foundation

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
}

final class AudioTransportPipeline: @unchecked Sendable {
    private let sender = UDPAudioSender(capacity: 256)
    private var packetizer = AudioPacketizer()
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

    func start(host: String, port: UInt16) {
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
        }
        sender.start(host: host, port: port)
    }

    func stop() {
        sender.stop()
        packetizer.reset()
    }

    // Called only from CaptureManager's serial sample queue.
    func consume(_ sampleBuffer: CMSampleBuffer) -> TransportSnapshot {
        guard let samples = PCMExtractor.interleavedFloatStereo48k(from: sampleBuffer) else {
            statsLock.withLock { conversionDrops &+= 1 }
            return snapshot()
        }

        let timestamp = DispatchTime.now().uptimeNanoseconds
        let frameCount = UInt64(samples.count / Int(MPAudioChannelCount))
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let duration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        statsLock.withLock {
            if firstHostTimeNS == nil {
                firstHostTimeNS = timestamp
                firstFrameCount = frameCount
            }
            if let lastHostTimeNS {
                maxCallbackGapNS = max(maxCallbackGapNS, timestamp - lastHostTimeNS)
            }
            if firstPTSSeconds == nil, pts.isFinite {
                firstPTSSeconds = pts
            }
            if let expectedPTS = lastPTSEndSeconds, pts.isFinite {
                maxPTSErrorSeconds = max(maxPTSErrorSeconds, abs(pts - expectedPTS))
            }
            if pts.isFinite, duration.isFinite {
                lastPTSEndSeconds = pts + duration
            }
            totalFrames &+= frameCount
            lastHostTimeNS = timestamp
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
                network.sendGapEvents
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
            sendGapEvents: diagnostics.11
        )
    }
}

private struct AudioPacketizer {
    private var pending: [Float] = []
    private var fecGroup: [Data] = []
    private var delayedParity: [Data] = []
    private var sequence: UInt32 = 0
    private var sampleIndex: UInt64 = 0
    private var streamID: UInt64 = UInt64.random(in: 1...UInt64.max)

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        fecGroup.removeAll(keepingCapacity: true)
        delayedParity.removeAll(keepingCapacity: true)
        sequence = 0
        sampleIndex = 0
        streamID = UInt64.random(in: 1...UInt64.max)
    }

    mutating func consume(
        _ samples: [Float],
        senderTimestampNS: UInt64
    ) -> [Data] {
        pending.append(contentsOf: samples)
        // Bound capture-side memory to two seconds. A full network queue is
        // handled separately and never blocks the capture callback.
        let maximumSamples = 48_000 * Int(MPAudioChannelCount) * 2
        if pending.count > maximumSamples {
            pending.removeFirst(pending.count - maximumSamples)
        }

        let packetSamples = Int(MPAudioSamplesPerPacket)
        var datagrams: [Data] = []
        while pending.count >= packetSamples {
            var datagram = Data(count: Int(MPAudioDatagramSize))
            let encodedSize: Int = pending.withUnsafeBufferPointer { samplesBuffer in
                datagram.withUnsafeMutableBytes { outputBuffer in
                    MPAudioPacketEncode(
                        samplesBuffer.baseAddress,
                        packetSamples,
                        streamID,
                        sequence,
                        senderTimestampNS,
                        sampleIndex,
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress,
                        outputBuffer.count
                    )
                }
            }
            guard encodedSize == Int(MPAudioDatagramSize) else { break }
            datagrams.append(datagram)
            fecGroup.append(datagram)
            pending.removeFirst(packetSamples)
            sequence &+= 1
            sampleIndex &+= UInt64(MPAudioFramesPerPacket)

            if fecGroup.count == Int(MPAudioFECDataShards) {
                var newParity: [Data] = []
                newParity.reserveCapacity(Int(MPAudioFECParityShards))
                var contiguousGroup = Data()
                contiguousGroup.reserveCapacity(
                    fecGroup.count * Int(MPAudioDatagramSize)
                )
                for packet in fecGroup { contiguousGroup.append(packet) }
                for parityIndex in 0..<Int(MPAudioFECParityShards) {
                    var parity = Data(count: Int(MPAudioDatagramSize))
                    let paritySize = contiguousGroup.withUnsafeBytes { groupBytes in
                        parity.withUnsafeMutableBytes { outputBytes in
                            MPAudioFECParityEncode(
                                groupBytes.bindMemory(to: UInt8.self).baseAddress,
                                Int(MPAudioDatagramSize),
                                Int(MPAudioFECDataShards),
                                UInt8(parityIndex),
                                outputBytes.bindMemory(to: UInt8.self).baseAddress,
                                outputBytes.count
                            )
                        }
                    }
                    if paritySize == Int(MPAudioDatagramSize) {
                        newParity.append(parity)
                    }
                }
                // Keep parity temporally separated from the audio it protects.
                // A short radio blackout should not erase both copies.
                datagrams.append(contentsOf: delayedParity)
                delayedParity = newParity
                fecGroup.removeAll(keepingCapacity: true)
            }
        }
        return datagrams
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
    private var retryDatagram: Data?
    private var state = "Stopped"
    private var socket: MPUdpSenderRef?

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
            retryDatagram = nil
            state = "Starting"
        }

        socket = host.withCString { MPUdpSenderCreate($0, port) }
        guard socket != nil else {
            lock.withLock { state = "Failed: UDP socket" }
            return
        }
        lock.withLock { state = "Ready" }

    }

    func stop() {
        queue.sync {
            if let socket {
                MPUdpSenderDestroy(socket)
                self.socket = nil
            }
        }
        lock.withLock { state = "Stopped" }
    }

    func enqueue(_ datagram: Data) {
        let shouldSchedule = lock.withLock {
            guard count < slots.count else {
                queueDrops &+= 1
                return false
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
        guard let socket else {
            lock.withLock { drainScheduled = false }
            return
        }
        while true {
            guard let datagram = retryDatagram ?? dequeueForDrain() else { return }
            let sent = datagram.withUnsafeBytes { bytes in
                MPUdpSenderSend(
                    socket,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
            if sent {
                retryDatagram = nil
                lock.withLock {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if let lastSendTimeNS {
                        let gap = now - lastSendTimeNS
                        maxSendGapNS = max(maxSendGapNS, gap)
                        if gap >= 10_000_000 { sendGapEvents &+= 1 }
                    }
                    lastSendTimeNS = now
                    packetsSent &+= 1
                    state = "Ready"
                }
            } else {
                retryDatagram = datagram
                lock.withLock {
                    sendFailures &+= 1
                    state = "Waiting: UDP send buffer full"
                    drainScheduled = false
                }
                return
            }
        }
    }

    private func dequeueForDrain() -> Data? {
        lock.withLock {
            guard count > 0 else {
                drainScheduled = false
                return nil
            }
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
