import AVFAudio
import Foundation
import Network

enum RemoteMediaCommand: String, Sendable {
    case previous = "PREVIOUS"
    case playPause = "PLAY_PAUSE"
    case next = "NEXT"

    var payload: Data { Data("SOUNDMUX/1 \(rawValue)".utf8) }
}

struct ReverseReceiverSnapshot: Sendable {
    let state: String
    let rawDatagrams: UInt64
    let packetsReceived: UInt64
    let packetsLost: UInt64
    let fecRecovered: UInt64
    let hardResyncs: UInt64
    let concealedPackets: UInt64
    let audioUnderruns: UInt64
    let bufferedFrames: Int
    let playoutActive: Bool
}

@MainActor
final class ReverseAudioReceiver: ObservableObject {
    @Published var listenPort: String {
        didSet { UserDefaults.standard.set(listenPort, forKey: "reverseListenPort") }
    }
    @Published private(set) var isListening = false
    @Published private(set) var state = "Stopped"
    @Published private(set) var datagrams: UInt64 = 0
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsLost: UInt64 = 0
    @Published private(set) var fecRecovered: UInt64 = 0
    @Published private(set) var hardResyncs: UInt64 = 0
    @Published private(set) var concealedPackets: UInt64 = 0
    @Published private(set) var audioUnderruns: UInt64 = 0
    @Published private(set) var bufferedAudio = "0 ms"
    @Published private(set) var errorMessage: String?

    private let pipeline = ReverseReceiverPipeline()

    init() {
        listenPort = UserDefaults.standard.string(forKey: "reverseListenPort") ?? "48101"
    }

    func start() {
        guard !isListening else { return }
        guard let port = UInt16(listenPort), port > 0 else {
            errorMessage = "Enter a valid UDP port."
            return
        }
        errorMessage = nil
        do {
            try pipeline.start(port: port) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.apply(snapshot)
                }
            }
            isListening = true
            state = "Starting"
        } catch {
            pipeline.stop()
            isListening = false
            state = "Failed"
            errorMessage = error.localizedDescription
        }
    }

    func startIfNeeded() {
        if !isListening { start() }
    }

    func stop() {
        pipeline.stop()
        isListening = false
        state = "Stopped"
    }

    func send(_ command: RemoteMediaCommand) {
        pipeline.send(command)
    }

    private func apply(_ snapshot: ReverseReceiverSnapshot) {
        state = snapshot.state
        datagrams = snapshot.rawDatagrams
        packetsReceived = snapshot.packetsReceived
        packetsLost = snapshot.packetsLost
        fecRecovered = snapshot.fecRecovered
        hardResyncs = snapshot.hardResyncs
        concealedPackets = snapshot.concealedPackets
        audioUnderruns = snapshot.audioUnderruns
        bufferedAudio = String(
            format: "%.0f ms",
            Double(snapshot.bufferedFrames) * 1_000 / 48_000
        )
    }
}

private final class ReverseReceiverPipeline: @unchecked Sendable {
    private static let sampleRate = 48_000.0
    private static let channelCount = 2
    private static let maximumRenderFrames = 8_192

    private let networkQueue = DispatchQueue(
        label: "com.skandavyas.multipoint.reverse-network",
        qos: .userInteractive
    )
    private let playoutQueue = DispatchQueue(
        label: "com.skandavyas.multipoint.reverse-playout",
        qos: .userInteractive
    )
    private let receiverLock = NSLock()
    private var receiver: MPReceiverEngineRef?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var controlConnection: NWConnection?
    private var pumpTimer: DispatchSourceTimer?
    private var metricsTimer: DispatchSourceTimer?
    private var inactiveObserver: NSObjectProtocol?
    private var resumptionObserver: NSObjectProtocol?
    private var snapshotHandler: (@Sendable (ReverseReceiverSnapshot) -> Void)?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var renderScratch: UnsafeMutablePointer<Float>?
    private var audioInterrupted = false

    func start(
        port: UInt16,
        snapshotHandler: @escaping @Sendable (ReverseReceiverSnapshot) -> Void
    ) throws {
        stop()
        guard let receiver = MPReceiverEngineCreate(12, 2_880) else {
            throw ReceiverError.initializationFailed
        }
        self.receiver = receiver
        self.snapshotHandler = snapshotHandler

        do {
            try startAudio(receiver: receiver)
            try startListener(port: port)
            startTimers()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver) }
        if let resumptionObserver { NotificationCenter.default.removeObserver(resumptionObserver) }
        inactiveObserver = nil
        resumptionObserver = nil
        networkQueue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections { connection.cancel() }
            connections.removeAll()
            controlConnection?.cancel()
            controlConnection = nil
        }
        playoutQueue.sync {
            pumpTimer?.cancel()
            pumpTimer = nil
            metricsTimer?.cancel()
            metricsTimer = nil
            audioInterrupted = false
        }

        engine?.stop()
        if let sourceNode { engine?.detach(sourceNode) }
        sourceNode = nil
        engine = nil
        renderScratch?.deallocate()
        renderScratch = nil

        receiverLock.withLock {
            MPReceiverEngineDestroy(receiver)
            receiver = nil
        }
        snapshotHandler = nil
    }

    private func startAudio(receiver: MPReceiverEngineRef) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setActive(true)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(Self.channelCount),
            interleaved: false
        ) else {
            throw ReceiverError.audioFormatUnavailable
        }

        let scratch = UnsafeMutablePointer<Float>.allocate(
            capacity: Self.maximumRenderFrames * Self.channelCount
        )
        scratch.initialize(
            repeating: 0,
            count: Self.maximumRenderFrames * Self.channelCount
        )
        renderScratch = scratch

        let source = AVAudioSourceNode(format: format) {
            _, _, frameCount, outputData -> OSStatus in
            let frames = Int(frameCount)
            guard frames <= Self.maximumRenderFrames else {
                for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                    if let data = buffer.mData {
                        memset(data, 0, Int(buffer.mDataByteSize))
                    }
                }
                return noErr
            }

            _ = MPReceiverEngineRead(receiver, scratch, frames)
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            if buffers.count == 1, let data = buffers[0].mData {
                data.copyMemory(
                    from: scratch,
                    byteCount: frames * Self.channelCount * MemoryLayout<Float>.size
                )
            } else {
                for channel in 0..<min(buffers.count, Self.channelCount) {
                    guard let data = buffers[channel].mData else { continue }
                    let destination = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        destination[frame] = scratch[frame * Self.channelCount + channel]
                    }
                }
            }
            return noErr
        }

        let newEngine = AVAudioEngine()
        newEngine.attach(source)
        try newEngine.connectNode(source, to: newEngine.mainMixerNode, format: format)
        newEngine.prepare()
        try newEngine.start()
        sourceNode = source
        engine = newEngine
        observeAudioInterruptions(session: session)
    }

    private func observeAudioInterruptions(session: AVAudioSession) {
        inactiveObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.playoutQueue.async { [weak self] in
                self?.handleAudioBecameInactive()
            }
        }

        resumptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard
                let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                    as? AVAudioSession.ResumptionContext,
                context.recommendation == .shouldResume
            else { return }
            self?.playoutQueue.async { [weak self] in
                self?.resumeAudioAfterInterruption()
            }
        }
    }

    private func handleAudioBecameInactive() {
        audioInterrupted = true
        receiverLock.withLock {
            MPReceiverEngineRebuffer(receiver)
        }
        publish(state: "Audio interrupted")
    }

    private func resumeAudioAfterInterruption() {
        // Drop anything accumulated while iOS owned the output, then begin
        // from fresh network audio instead of replaying a stale backlog.
        receiverLock.withLock {
            MPReceiverEngineRebuffer(receiver)
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if let engine, !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            audioInterrupted = false
            publish(state: "Buffering")
        } catch {
            publish(state: "Audio resume failed: \(error.localizedDescription)")
        }
    }

    private func startListener(port: UInt16) throws {
        guard port < UInt16.max else { throw ReceiverError.invalidPort }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ReceiverError.invalidPort
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let newListener = try NWListener(using: parameters, on: endpointPort)
        newListener.service = NWListener.Service(
            name: "SoundMux iPhone",
            type: "_soundmux._udp"
        )
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener, self.listener === newListener else { return }
            self.publish(state: Self.description(for: state))
        }
        newListener.newConnectionHandler = { [weak self, weak newListener] connection in
            guard let self, let newListener, self.listener === newListener else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            if case .hostPort(let host, _) = connection.endpoint {
                self.connectControls(to: host, port: port + 1)
            }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                if case .failed = state { self.remove(connection) }
                if case .cancelled = state { self.remove(connection) }
            }
            connection.start(queue: self.networkQueue)
            self.receiveNext(on: connection)
        }
        networkQueue.sync {
            listener = newListener
            newListener.start(queue: networkQueue)
        }
    }

    func send(_ command: RemoteMediaCommand) {
        networkQueue.async { [weak self] in
            guard let connection = self?.controlConnection else { return }
            connection.send(
                content: command.payload,
                completion: .contentProcessed { _ in }
            )
        }
    }

    private func connectControls(to host: NWEndpoint.Host, port: UInt16) {
        controlConnection?.cancel()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: host, port: endpointPort, using: .udp)
        controlConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.controlConnection === connection else {
                return
            }
            if case .failed = state { self.controlConnection = nil }
            if case .cancelled = state { self.controlConnection = nil }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                let arrivalNS = DispatchTime.now().uptimeNanoseconds
                self.receiverLock.withLock {
                    guard let receiver = self.receiver else { return }
                    var hardResync = false
                    data.withUnsafeBytes { bytes in
                        guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
                            return
                        }
                        _ = MPReceiverEngineIngest(
                            receiver,
                            base,
                            data.count,
                            arrivalNS,
                            &hardResync
                        )
                    }
                }
            }
            if error == nil {
                self.receiveNext(on: connection)
            } else {
                self.remove(connection)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
    }

    private func startTimers() {
        let pump = DispatchSource.makeTimerSource(queue: playoutQueue)
        pump.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        pump.setEventHandler { [weak self] in
            guard let self else { return }
            guard !self.audioInterrupted else { return }
            self.receiverLock.withLock {
                MPReceiverEnginePump(self.receiver)
            }
        }
        pump.resume()
        pumpTimer = pump

        let metrics = DispatchSource.makeTimerSource(queue: playoutQueue)
        metrics.schedule(deadline: .now(), repeating: .seconds(1))
        metrics.setEventHandler { [weak self] in self?.publish() }
        metrics.resume()
        metricsTimer = metrics
    }

    private func publish(state: String? = nil) {
        let stats = receiverLock.withLock { MPReceiverEngineSnapshot(receiver) }
        let currentState: String
        if let state {
            currentState = state
        } else if stats.playout_active {
            currentState = "Playing"
        } else if stats.valid_datagrams > 0 {
            currentState = "Buffering"
        } else {
            currentState = "Listening"
        }
        snapshotHandler?(.init(
            state: currentState,
            rawDatagrams: stats.raw_datagrams,
            packetsReceived: stats.packets_received,
            packetsLost: stats.packets_lost,
            fecRecovered: stats.fec_recovered,
            hardResyncs: stats.hard_resyncs,
            concealedPackets: stats.concealed_packets,
            audioUnderruns: stats.audio_underruns,
            bufferedFrames: stats.buffered_frames,
            playoutActive: stats.playout_active
        ))
    }

    private static func description(for state: NWListener.State) -> String {
        switch state {
        case .setup: "Starting"
        case .waiting(let error): "Waiting: \(error)"
        case .ready: "Listening"
        case .failed(let error): "Failed: \(error)"
        case .cancelled: "Stopped"
        @unknown default: "Unknown"
        }
    }
}

private enum ReceiverError: LocalizedError {
    case initializationFailed
    case invalidPort
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .initializationFailed: "Could not initialize the receiver engine."
        case .invalidPort: "The UDP listen port is invalid."
        case .audioFormatUnavailable: "The 48 kHz stereo playback format is unavailable."
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
