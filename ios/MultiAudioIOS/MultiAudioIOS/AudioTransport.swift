import AudioToolbox
import CoreMedia
import Foundation
import Network

struct TransportSnapshot: Sendable {
    let packetsSent: UInt64
    let queueDrops: UInt64
    let conversionDrops: UInt64
    let state: String
}

final class AudioTransportPipeline: @unchecked Sendable {
    private let sender = UDPAudioSender(capacity: 256)
    private var packetizer = AudioPacketizer()
    private let statsLock = NSLock()
    private var conversionDrops: UInt64 = 0

    func start(host: String, port: UInt16) {
        packetizer.reset()
        statsLock.withLock { conversionDrops = 0 }
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
        for datagram in packetizer.consume(samples, senderTimestampNS: timestamp) {
            sender.enqueue(datagram)
        }
        return snapshot()
    }

    func snapshot() -> TransportSnapshot {
        let conversion = statsLock.withLock { conversionDrops }
        let network = sender.snapshot()
        return TransportSnapshot(
            packetsSent: network.packetsSent,
            queueDrops: network.queueDrops,
            conversionDrops: conversion,
            state: network.state
        )
    }
}

private struct AudioPacketizer {
    private var pending: [Float] = []
    private var sequence: UInt32 = 0
    private var sampleIndex: UInt64 = 0
    private var streamID: UInt64 = UInt64.random(in: 1...UInt64.max)

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
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
            pending.removeFirst(packetSamples)
            sequence &+= 1
            sampleIndex &+= UInt64(MPAudioFramesPerPacket)
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
    private var state = "Stopped"
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?

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
            state = "Starting"
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            let description: String
            switch newState {
            case .ready: description = "Ready"
            case .waiting(let error): description = "Waiting: \(error.localizedDescription)"
            case .failed(let error): description = "Failed: \(error.localizedDescription)"
            case .cancelled: description = "Stopped"
            case .preparing: description = "Preparing"
            case .setup: description = "Starting"
            @unknown default: description = "Unknown"
            }
            self?.lock.withLock { self?.state = description }
        }
        connection.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(250))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        lock.withLock { state = "Stopped" }
    }

    func enqueue(_ datagram: Data) {
        lock.withLock {
            guard count < slots.count else {
                queueDrops &+= 1
                return
            }
            slots[tail] = datagram
            tail = (tail + 1) % slots.count
            count += 1
        }
    }

    func snapshot() -> (packetsSent: UInt64, queueDrops: UInt64, state: String) {
        lock.withLock { (packetsSent, queueDrops, state) }
    }

    private func drain() {
        guard let connection else { return }
        while let datagram = dequeue() {
            connection.send(content: datagram, completion: .contentProcessed { [weak self] error in
                self?.lock.withLock {
                    if let error {
                        self?.state = "Send failed: \(error.localizedDescription)"
                    } else {
                        self?.packetsSent &+= 1
                    }
                }
            })
        }
    }

    private func dequeue() -> Data? {
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
