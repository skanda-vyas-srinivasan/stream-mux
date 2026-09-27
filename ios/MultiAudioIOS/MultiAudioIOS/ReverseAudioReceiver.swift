import AVFAudio
import Foundation
import Network
import Security
import UIKit

private let soundMuxCryptoKeyBytes = 32
private let soundMuxCryptoNonceBytes = 16
private let soundMuxCryptoProofBytes = 32

private struct SoundMuxDeviceKey {
    let secret: Data
    let publicKey: Data

    static func loadOrCreate(deviceID: String) throws -> SoundMuxDeviceKey {
        let service = "com.skandavyas.soundmux.device-key"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let secret = result as? Data,
           secret.count == soundMuxCryptoKeyBytes,
           let publicKey = publicKey(for: secret) {
            return .init(secret: secret, publicKey: publicKey)
        }
        guard status == errSecItemNotFound else {
            throw ReceiverError.cryptoUnavailable
        }

        var secret = Data(count: soundMuxCryptoKeyBytes)
        var publicKey = Data(count: soundMuxCryptoKeyBytes)
        let generated = secret.withUnsafeMutableBytes { secretBytes in
            publicKey.withUnsafeMutableBytes { publicBytes in
                MPCryptoGenerateDeviceKey(
                    secretBytes.bindMemory(to: UInt8.self).baseAddress,
                    publicBytes.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        guard generated else { throw ReceiverError.cryptoUnavailable }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: secret,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw ReceiverError.cryptoUnavailable
        }
        return .init(secret: secret, publicKey: publicKey)
    }

    private static func publicKey(for secret: Data) -> Data? {
        var output = Data(count: soundMuxCryptoKeyBytes)
        let success = secret.withUnsafeBytes { secretBytes in
            output.withUnsafeMutableBytes { outputBytes in
                MPCryptoPublicKey(
                    secretBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return success ? output : nil
    }
}

private struct SoundMuxSessionSecrets {
    let senderKey: Data
    let receiverKey: Data
    let senderNonce: Data
    let receiverNonce: Data
    let proof: Data

    static func derive(
        localSecret: Data,
        remotePublic: Data,
        senderPublic: Data,
        receiverPublic: Data,
        clientNonce: Data,
        serverNonce: Data
    ) -> SoundMuxSessionSecrets? {
        var senderKey = Data(count: soundMuxCryptoKeyBytes)
        var receiverKey = Data(count: soundMuxCryptoKeyBytes)
        var senderNonce = Data(count: soundMuxCryptoNonceBytes)
        var receiverNonce = Data(count: soundMuxCryptoNonceBytes)
        var proof = Data(count: soundMuxCryptoProofBytes)
        let inputs = [localSecret, remotePublic, senderPublic, receiverPublic,
                      clientNonce, serverNonce]
        guard inputs.allSatisfy({ !$0.isEmpty }) else { return nil }
        let success = localSecret.withUnsafeBytes { local in
            remotePublic.withUnsafeBytes { remote in
                senderPublic.withUnsafeBytes { sender in
                    receiverPublic.withUnsafeBytes { receiver in
                        clientNonce.withUnsafeBytes { client in
                            serverNonce.withUnsafeBytes { server in
                                senderKey.withUnsafeMutableBytes { senderKeyBytes in
                                    receiverKey.withUnsafeMutableBytes { receiverKeyBytes in
                                        senderNonce.withUnsafeMutableBytes { senderNonceBytes in
                                            receiverNonce.withUnsafeMutableBytes { receiverNonceBytes in
                                                proof.withUnsafeMutableBytes { proofBytes in
                                                    MPCryptoDeriveSession(
                                                        local.bindMemory(to: UInt8.self).baseAddress,
                                                        remote.bindMemory(to: UInt8.self).baseAddress,
                                                        sender.bindMemory(to: UInt8.self).baseAddress,
                                                        receiver.bindMemory(to: UInt8.self).baseAddress,
                                                        client.bindMemory(to: UInt8.self).baseAddress,
                                                        server.bindMemory(to: UInt8.self).baseAddress,
                                                        senderKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                                                        receiverKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                                                        senderNonceBytes.bindMemory(to: UInt8.self).baseAddress,
                                                        receiverNonceBytes.bindMemory(to: UInt8.self).baseAddress,
                                                        proofBytes.bindMemory(to: UInt8.self).baseAddress
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard success else { return nil }
        return .init(
            senderKey: senderKey,
            receiverKey: receiverKey,
            senderNonce: senderNonce,
            receiverNonce: receiverNonce,
            proof: proof
        )
    }
}

private final class SoundMuxCipher: @unchecked Sendable {
    enum OpenResult { case notEncrypted, invalid, plaintext(Data) }
    private var reference: MPSessionCipherRef?

    init?(key: Data, nonce: Data) {
        reference = key.withUnsafeBytes { keyBytes in
            nonce.withUnsafeBytes { nonceBytes in
                MPSessionCipherCreate(
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    nonceBytes.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        if reference == nil { return nil }
    }

    deinit { MPSessionCipherDestroy(reference) }

    func seal(_ plaintext: Data) -> Data? {
        guard let reference else { return nil }
        let outputCapacity = plaintext.count + Int(MPCryptoEnvelopeOverhead)
        var output = Data(count: outputCapacity)
        var outputSize = 0
        let success = plaintext.withUnsafeBytes { plaintextBytes in
            output.withUnsafeMutableBytes { outputBytes in
                MPSessionCipherEncrypt(
                    reference,
                    plaintextBytes.bindMemory(to: UInt8.self).baseAddress,
                    plaintext.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputCapacity,
                    &outputSize
                )
            }
        }
        guard success else { return nil }
        output.count = outputSize
        return output
    }

    func open(_ datagram: Data) -> OpenResult {
        guard let reference else { return .invalid }
        let outputCapacity = datagram.count
        var output = Data(count: outputCapacity)
        var outputSize = 0
        let result = datagram.withUnsafeBytes { datagramBytes in
            output.withUnsafeMutableBytes { outputBytes in
                MPSessionCipherDecrypt(
                    reference,
                    datagramBytes.bindMemory(to: UInt8.self).baseAddress,
                    datagram.count,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputCapacity,
                    &outputSize
                )
            }
        }
        if result == 0 { return .notEncrypted }
        guard result == 1 else { return .invalid }
        output.count = outputSize
        return .plaintext(output)
    }
}

private extension Data {
    var soundMuxHex: String { map { String(format: "%02x", $0) }.joined() }

    static func soundMuxHex(_ text: String, count: Int) -> Data? {
        var output = Data(count: count)
        let success = output.withUnsafeMutableBytes { bytes in
            text.withCString {
                MPCryptoHexDecode(
                    $0,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    count
                )
            }
        }
        return success ? output : nil
    }

    static func soundMuxRandom(count: Int) -> Data? {
        var output = Data(count: count)
        let success = output.withUnsafeMutableBytes { bytes in
            MPCryptoRandom(bytes.bindMemory(to: UInt8.self).baseAddress, count)
        }
        return success ? output : nil
    }
}

struct PendingSoundMuxPairing: Identifiable, Sendable, Equatable {
    let senderID: String
    let senderName: String
    let platform: String
    let code: String

    var id: String { senderID }
}

struct TrustedSoundMuxDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
}

private struct SoundMuxRelayConfiguration: Sendable {
    let host: String
    let port: UInt16
    let route: String
}

private enum SoundMuxSessionKind: String {
    case hello = "HELLO"
    case pairRequired = "PAIR_REQUIRED"
    case rejected = "REJECTED"
    case welcome = "WELCOME"
    case ping = "PING"
    case pong = "PONG"
    case profile = "PROFILE"
}

private struct SoundMuxSessionMessage {
    let kind: SoundMuxSessionKind
    let fields: [String: String]

    var data: Data {
        var components = ["SOUNDMUX/2", kind.rawValue]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for key in fields.keys.sorted() {
            let value = fields[key] ?? ""
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            components.append("\(key)=\(escaped)")
        }
        return Data(components.joined(separator: "|").utf8)
    }

    static func decode(_ data: Data) -> SoundMuxSessionMessage? {
        guard data.count <= 1_200, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let components = text.split(separator: "|", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components[0] == "SOUNDMUX/2",
              let kind = SoundMuxSessionKind(rawValue: String(components[1])) else {
            return nil
        }
        var fields: [String: String] = [:]
        for component in components.dropFirst(2) {
            guard let equals = component.firstIndex(of: "=") else { return nil }
            let key = String(component[..<equals])
            guard !key.isEmpty, fields[key] == nil else { return nil }
            let encoded = String(component[component.index(after: equals)...])
            guard let value = encoded.removingPercentEncoding else { return nil }
            fields[key] = value
        }
        return .init(kind: kind, fields: fields)
    }
}

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
    let activeSenderName: String?
    let trustedSenderCount: Int
    let trustedSenderNames: [String]
    let trustedDevices: [TrustedSoundMuxDevice]
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
    @Published private(set) var pendingPairing: PendingSoundMuxPairing?
    @Published private(set) var activeSenderName: String?
    @Published private(set) var trustedSenderCount = 0
    @Published private(set) var trustedSenderNames: [String] = []
    @Published private(set) var trustedDevices: [TrustedSoundMuxDevice] = []
    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: "soundMuxDeviceName") }
    }
    @Published var outputVolume: Float {
        didSet {
            let clamped = min(max(outputVolume, 0), 1)
            if clamped != outputVolume {
                outputVolume = clamped
                return
            }
            UserDefaults.standard.set(outputVolume, forKey: "receiverOutputVolume")
            pipeline.setVolume(outputVolume)
        }
    }
    @Published var targetLatencyMs: Double {
        didSet {
            let clamped = min(max(targetLatencyMs, 40), 160)
            if clamped != targetLatencyMs {
                targetLatencyMs = clamped
                return
            }
            UserDefaults.standard.set(targetLatencyMs, forKey: "receiverTargetLatencyMs")
        }
    }
    @Published var useInternetRelay: Bool {
        didSet { UserDefaults.standard.set(useInternetRelay, forKey: "useInternetRelay") }
    }
    @Published var relayHost: String {
        didSet { UserDefaults.standard.set(relayHost, forKey: "relayHost") }
    }
    @Published var relayPort: String {
        didSet { UserDefaults.standard.set(relayPort, forKey: "relayPort") }
    }
    @Published var relayRoute: String {
        didSet { UserDefaults.standard.set(relayRoute, forKey: "relayRoute") }
    }

    private let pipeline = ReverseReceiverPipeline()
    private let deviceID: String

    init() {
        let defaults = UserDefaults.standard
        listenPort = defaults.string(forKey: "reverseListenPort") ?? "48101"
        outputVolume = defaults.object(forKey: "receiverOutputVolume") == nil
            ? 1
            : defaults.float(forKey: "receiverOutputVolume")
        targetLatencyMs = defaults.object(forKey: "receiverTargetLatencyMs") == nil
            ? 60
            : defaults.double(forKey: "receiverTargetLatencyMs")
        useInternetRelay = defaults.bool(forKey: "useInternetRelay")
        relayHost = defaults.string(forKey: "relayHost") ?? ""
        relayPort = defaults.string(forKey: "relayPort") ?? "48200"
        relayRoute = defaults.string(forKey: "relayRoute") ?? ""
        deviceName = defaults.string(forKey: "soundMuxDeviceName")
            ?? UIDevice.current.name
        if let existing = defaults.string(forKey: "soundMuxDeviceID") {
            deviceID = existing
        } else {
            let created = UUID().uuidString
            defaults.set(created, forKey: "soundMuxDeviceID")
            deviceID = created
        }
    }

    func start() {
        guard !isListening else { return }
        guard let port = UInt16(listenPort), port > 0 else {
            errorMessage = "Enter a valid UDP port."
            return
        }
        let advertisedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !advertisedName.isEmpty else {
            errorMessage = "Enter a receiver name."
            return
        }
        var relay: SoundMuxRelayConfiguration?
        if useInternetRelay {
            let host = relayHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let route = relayRoute.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !host.isEmpty, let port = UInt16(relayPort), port > 0,
                  route.count == 32,
                  route.allSatisfy({ $0.isHexDigit }) else {
                errorMessage = "Enter a relay host, UDP port, and 32-character route code."
                return
            }
            relay = .init(host: host, port: port, route: route)
        }
        errorMessage = nil
        do {
            let prebufferFrames = Int(48_000 * targetLatencyMs / 1_000)
            let reorderPackets = max(3, min(24, prebufferFrames / 240))
            try pipeline.start(
                port: port,
                reorderPackets: reorderPackets,
                prebufferFrames: prebufferFrames,
                receiverID: deviceID,
                receiverName: advertisedName,
                volume: outputVolume,
                relay: relay,
                snapshotHandler: { [weak self] snapshot in
                    Task { @MainActor [weak self] in self?.apply(snapshot) }
                },
                pairingHandler: { [weak self] pairing in
                    Task { @MainActor [weak self] in self?.pendingPairing = pairing }
                }
            )
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
        pendingPairing = nil
        activeSenderName = nil
    }

    func send(_ command: RemoteMediaCommand) {
        pipeline.send(command)
    }

    func approvePairing() {
        guard let pendingPairing else { return }
        pipeline.approvePairing(senderID: pendingPairing.senderID)
    }

    func rejectPairing() {
        guard let pendingPairing else { return }
        pipeline.rejectPairing(senderID: pendingPairing.senderID)
    }

    func forgetTrustedSenders() {
        pipeline.forgetTrustedSenders()
    }

    func forgetTrustedSender(id: String) {
        pipeline.forgetTrustedSender(id: id)
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
        activeSenderName = snapshot.activeSenderName
        trustedSenderCount = snapshot.trustedSenderCount
        trustedSenderNames = snapshot.trustedSenderNames
        trustedDevices = snapshot.trustedDevices
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
    private let relayQueue = DispatchQueue(
        label: "com.skandavyas.multipoint.reverse-relay",
        qos: .userInteractive
    )
    private let receiverLock = NSLock()
    private let relayStateLock = NSLock()
    private var receiver: MPReceiverEngineRef?
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: ReceiverPeer] = [:]
    private var activePeer: ReceiverPeer?
    private var relayPeer: ReceiverPeer?
    private var relayChannel: MPRelayChannelRef?
    private var relayRunning = false
    private var relayKeepaliveTimer: DispatchSourceTimer?
    private var pumpTimer: DispatchSourceTimer?
    private var metricsTimer: DispatchSourceTimer?
    private var inactiveObserver: NSObjectProtocol?
    private var resumptionObserver: NSObjectProtocol?
    private var snapshotHandler: (@Sendable (ReverseReceiverSnapshot) -> Void)?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var renderScratch: UnsafeMutablePointer<Float>?
    private var audioInterrupted = false
    private var receiverID = ""
    private var receiverName = "SoundMux receiver"
    private var outputVolume: Float = 1
    private var pairingHandler: (@Sendable (PendingSoundMuxPairing?) -> Void)?
    private var trustedSenders: [String: String] = [:]
    private var trustedSenderNames: [String: String] = [:]
    private var deviceKey: SoundMuxDeviceKey?

    private final class ReceiverPeer: @unchecked Sendable {
        let connection: NWConnection?
        let host: NWEndpoint.Host?
        let isRelay: Bool
        var senderID = ""
        var senderName = "Unknown device"
        var platform = "unknown"
        var senderPublicKey: Data?
        var clientNonce: Data?
        var serverNonce: Data?
        var authorized = false
        var pairingCode: String?
        var controlConnection: NWConnection?
        var inboundCipher: SoundMuxCipher?
        var outboundCipher: SoundMuxCipher?
        var lastSeen = DispatchTime.now().uptimeNanoseconds

        init(connection: NWConnection, host: NWEndpoint.Host) {
            self.connection = connection
            self.host = host
            isRelay = false
        }

        init(relay: Void) {
            connection = nil
            host = nil
            isRelay = true
        }
    }

    func start(
        port: UInt16,
        reorderPackets: Int,
        prebufferFrames: Int,
        receiverID: String,
        receiverName: String,
        volume: Float,
        relay: SoundMuxRelayConfiguration?,
        snapshotHandler: @escaping @Sendable (ReverseReceiverSnapshot) -> Void,
        pairingHandler: @escaping @Sendable (PendingSoundMuxPairing?) -> Void
    ) throws {
        stop()
        guard let receiver = MPReceiverEngineCreate(reorderPackets, prebufferFrames) else {
            throw ReceiverError.initializationFailed
        }
        self.receiver = receiver
        self.receiverID = receiverID
        self.receiverName = receiverName
        self.outputVolume = volume
        self.deviceKey = try SoundMuxDeviceKey.loadOrCreate(deviceID: receiverID)
        self.trustedSenders = UserDefaults.standard.dictionary(
            forKey: "soundMuxTrustedSenders"
        ) as? [String: String] ?? [:]
        self.trustedSenderNames = UserDefaults.standard.dictionary(
            forKey: "soundMuxTrustedSenderNames"
        ) as? [String: String] ?? [:]
        self.snapshotHandler = snapshotHandler
        self.pairingHandler = pairingHandler

        do {
            try startAudio(receiver: receiver)
            try startListener(port: port)
            if let relay { try startRelay(relay) }
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
            metricsTimer?.cancel()
            metricsTimer = nil
            relayKeepaliveTimer?.cancel()
            relayKeepaliveTimer = nil
            listener?.cancel()
            listener = nil
            for peer in peers.values {
                peer.connection?.cancel()
                peer.controlConnection?.cancel()
            }
            peers.removeAll()
            activePeer = nil
            relayPeer = nil
        }
        relayStateLock.withLock { relayRunning = false }
        relayQueue.sync {}
        MPRelayChannelDestroy(relayChannel)
        relayChannel = nil
        playoutQueue.sync {
            pumpTimer?.cancel()
            pumpTimer = nil
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
        pairingHandler = nil
        deviceKey = nil
    }

    func setVolume(_ volume: Float) {
        playoutQueue.async { [weak self] in
            guard let self else { return }
            self.outputVolume = min(max(volume, 0), 1)
            self.engine?.mainMixerNode.outputVolume = self.outputVolume
        }
    }

    func approvePairing(senderID: String) {
        networkQueue.async { [weak self] in self?.finishPairing(senderID: senderID) }
    }

    func rejectPairing(senderID: String) {
        networkQueue.async { [weak self] in
            guard let self,
                  let peer = self.peers.values.first(where: { $0.senderID == senderID }) else {
                return
            }
            self.sendControl(
                .init(kind: .rejected, fields: ["reason": "Pairing declined"]),
                to: peer
            )
            peer.pairingCode = nil
            self.pairingHandler?(nil)
        }
    }

    func forgetTrustedSenders() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.trustedSenders.removeAll()
            self.trustedSenderNames.removeAll()
            UserDefaults.standard.removeObject(forKey: "soundMuxTrustedSenders")
            UserDefaults.standard.removeObject(forKey: "soundMuxTrustedSenderNames")
            for peer in self.peers.values { peer.authorized = false }
            self.activePeer = nil
            self.receiverLock.withLock { MPReceiverEngineRebuffer(self.receiver) }
            self.pairingHandler?(nil)
            self.publish(state: "Listening")
        }
    }

    func forgetTrustedSender(id: String) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.trustedSenders.removeValue(forKey: id)
            self.trustedSenderNames.removeValue(forKey: id)
            UserDefaults.standard.set(
                self.trustedSenders, forKey: "soundMuxTrustedSenders")
            UserDefaults.standard.set(
                self.trustedSenderNames, forKey: "soundMuxTrustedSenderNames")
            for peer in self.peers.values where peer.senderID == id {
                peer.authorized = false
                peer.inboundCipher = nil
                peer.outboundCipher = nil
                if self.activePeer === peer { self.activePeer = nil }
            }
            self.receiverLock.withLock { MPReceiverEngineRebuffer(self.receiver) }
            self.pairingHandler?(nil)
            self.publish(state: "Listening")
        }
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
        newEngine.mainMixerNode.outputVolume = outputVolume
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
        networkQueue.async { [weak self] in self?.publish(state: "Audio interrupted") }
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
            networkQueue.async { [weak self] in self?.publish(state: "Buffering") }
        } catch {
            let message = "Audio resume failed: \(error.localizedDescription)"
            networkQueue.async { [weak self] in self?.publish(state: message) }
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
        let txtRecord = NWTXTRecord([
            "id": receiverID,
            "name": receiverName,
            "platform": "ios",
            "protocol": "3",
            "session": "3",
            "security": "x25519+xchacha20poly1305",
            "public_key": deviceKey?.publicKey.soundMuxHex ?? "",
            "capabilities": "audio,media,airplay,pairing,volume,latency,encryption",
        ])
        newListener.service = NWListener.Service(
            name: "\(receiverName) · SoundMux",
            type: "_soundmux._udp",
            txtRecord: txtRecord
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
            guard case .hostPort(let host, _) = connection.endpoint else {
                connection.cancel()
                return
            }
            let peer = ReceiverPeer(connection: connection, host: host)
            self.peers[ObjectIdentifier(connection)] = peer
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

    private func startRelay(_ configuration: SoundMuxRelayConfiguration) throws {
        let channel = configuration.host.withCString { host in
            configuration.route.withCString { route in
                MPRelayChannelCreate(
                    host, configuration.port, route, Int32(MPRelayRoleReceiver))
            }
        }
        guard let channel, MPRelayChannelAnnounce(channel) else {
            MPRelayChannelDestroy(channel)
            throw ReceiverError.relayUnavailable
        }
        relayChannel = channel
        let peer = ReceiverPeer(relay: ())
        relayPeer = peer
        relayStateLock.withLock { relayRunning = true }

        relayQueue.async { [weak self, weak peer] in
            var buffer = [UInt8](repeating: 0, count: 1_432)
            while let self, self.relayStateLock.withLock({ self.relayRunning }) {
                guard let channel = self.relayChannel else { break }
                var size = 0
                let received = MPRelayChannelReceive(
                    channel, &buffer, buffer.count, &size)
                guard received, size > 0 else { continue }
                let datagram = Data(buffer.prefix(size))
                self.networkQueue.async { [weak self, weak peer] in
                    guard let self, let peer, self.relayPeer === peer else { return }
                    self.process(datagram, from: peer)
                }
            }
        }

        let keepalive = DispatchSource.makeTimerSource(queue: networkQueue)
        keepalive.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10))
        keepalive.setEventHandler { [weak self] in
            guard let channel = self?.relayChannel else { return }
            _ = MPRelayChannelKeepalive(channel)
        }
        keepalive.resume()
        relayKeepaliveTimer = keepalive
    }

    func send(_ command: RemoteMediaCommand) {
        networkQueue.async { [weak self] in
            guard let peer = self?.activePeer,
                  let payload = peer.outboundCipher?.seal(command.payload) else { return }
            self?.sendDatagram(payload, to: peer)
        }
    }

    private func connectControls(for peer: ReceiverPeer, port: UInt16) {
        peer.controlConnection?.cancel()
        guard !peer.isRelay, let host = peer.host else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: host, port: endpointPort, using: .udp)
        peer.controlConnection = connection
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection, peer.controlConnection === connection else {
                return
            }
            if case .failed = state { peer.controlConnection = nil }
            if case .cancelled = state { peer.controlConnection = nil }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                guard let peer = self.peers[ObjectIdentifier(connection)] else { return }
                self.process(data, from: peer)
            }
            if error == nil {
                self.receiveNext(on: connection)
            } else {
                self.remove(connection)
            }
        }
    }

    private func process(_ data: Data, from peer: ReceiverPeer) {
        peer.lastSeen = DispatchTime.now().uptimeNanoseconds
        // HELLO is intentionally plaintext. Accept retransmissions even after
        // authorization so a dropped WELCOME cannot strand the handshake.
        if let message = SoundMuxSessionMessage.decode(data), message.kind == .hello {
            handleSession(message, from: peer)
            return
        }
        if peer.authorized {
            guard case .plaintext(let plaintext) = peer.inboundCipher?.open(data) else {
                return
            }
            if let message = SoundMuxSessionMessage.decode(plaintext) {
                handleSession(message, from: peer)
            } else {
                ingestAudio(plaintext)
            }
        } else if let message = SoundMuxSessionMessage.decode(data) {
            handleSession(message, from: peer)
        }
    }

    private func ingestAudio(_ data: Data) {
        let arrivalNS = DispatchTime.now().uptimeNanoseconds
        receiverLock.withLock {
            guard let receiver else { return }
            var hardResync = false
            data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                _ = MPReceiverEngineIngest(
                    receiver, base, data.count, arrivalNS, &hardResync
                )
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        guard let peer = peers.removeValue(forKey: ObjectIdentifier(connection)) else {
            return
        }
        peer.controlConnection?.cancel()
        if activePeer === peer { activePeer = nil }
    }

    private func handleSession(_ message: SoundMuxSessionMessage, from peer: ReceiverPeer) {
        switch message.kind {
        case .hello:
            guard let senderID = message.fields["device_id"], !senderID.isEmpty,
                  let senderName = message.fields["name"], !senderName.isEmpty,
                  message.fields["session"] == "3",
                  let publicKeyText = message.fields["public_key"],
                  let senderPublicKey = Data.soundMuxHex(
                      publicKeyText, count: soundMuxCryptoKeyBytes),
                  let clientNonceText = message.fields["client_nonce"],
                  let clientNonce = Data.soundMuxHex(
                      clientNonceText, count: soundMuxCryptoNonceBytes),
                  let deviceKey else {
                return
            }
            let replyPort = message.fields["reply_port"].flatMap(UInt16.init) ?? 0
            guard peer.isRelay || replyPort > 0 else { return }
            peer.senderID = senderID
            peer.senderName = senderName
            peer.platform = message.fields["platform"] ?? "unknown"
            if peer.clientNonce != clientNonce || peer.senderPublicKey != senderPublicKey {
                peer.senderPublicKey = senderPublicKey
                peer.clientNonce = clientNonce
                peer.serverNonce = Data.soundMuxRandom(count: soundMuxCryptoNonceBytes)
                peer.pairingCode = nil
                peer.inboundCipher = nil
                peer.outboundCipher = nil
            }
            guard let serverNonce = peer.serverNonce,
                  let secrets = SoundMuxSessionSecrets.derive(
                      localSecret: deviceKey.secret,
                      remotePublic: senderPublicKey,
                      senderPublic: senderPublicKey,
                      receiverPublic: deviceKey.publicKey,
                      clientNonce: clientNonce,
                      serverNonce: serverNonce
                  ),
                  let inbound = SoundMuxCipher(
                      key: secrets.senderKey, nonce: secrets.senderNonce),
                  let outbound = SoundMuxCipher(
                      key: secrets.receiverKey, nonce: secrets.receiverNonce) else {
                return
            }
            peer.inboundCipher = inbound
            peer.outboundCipher = outbound
            if !peer.isRelay { connectControls(for: peer, port: replyPort) }
            let pairRequested = message.fields["pair_requested"] == "1"
            if trustedSenders[senderID] == publicKeyText, !pairRequested {
                authorize(peer, secrets: secrets)
                return
            }
            if peer.pairingCode == nil {
                var code = [CChar](repeating: 0, count: 7)
                let success = senderPublicKey.withUnsafeBytes { senderBytes in
                    deviceKey.publicKey.withUnsafeBytes { receiverBytes in
                        MPCryptoPairingCode(
                            senderBytes.bindMemory(to: UInt8.self).baseAddress,
                            receiverBytes.bindMemory(to: UInt8.self).baseAddress,
                            &code,
                            code.count
                        )
                    }
                }
                guard success else { return }
                peer.pairingCode = String(decoding: code.prefix(6).map(UInt8.init), as: UTF8.self)
            }
            guard let code = peer.pairingCode else { return }
            sendControl(
                .init(kind: .pairRequired, fields: [
                    "receiver_id": receiverID,
                    "receiver_name": receiverName,
                    "platform": "ios",
                    "public_key": deviceKey.publicKey.soundMuxHex,
                    "server_nonce": serverNonce.soundMuxHex,
                    "code": code,
                ]),
                to: peer
            )
            pairingHandler?(.init(
                senderID: senderID,
                senderName: senderName,
                platform: peer.platform,
                code: code
            ))
        case .ping:
            guard peer.authorized else { return }
            let stats = receiverLock.withLock {
                MPReceiverEngineSnapshot(receiver)
            }
            sendSecureControl(
                .init(kind: .pong, fields: [
                    "receiver_id": receiverID,
                    "counter": message.fields["counter"] ?? "0",
                    "received": String(stats.packets_received),
                    "lost": String(stats.packets_lost),
                    "recovered": String(stats.fec_recovered),
                    "underruns": String(stats.audio_underruns),
                    "buffered_frames": String(stats.buffered_frames),
                ]),
                to: peer
            )
        case .profile:
            guard peer.authorized,
                  let latencyText = message.fields["latency_ms"],
                  let latency = UInt32(latencyText),
                  (20...250).contains(latency) else { return }
            let changed = receiverLock.withLock {
                MPReceiverEngineSetTargetLatency(receiver, latency)
            }
            if changed { publish(state: "Buffering") }
        case .pairRequired, .rejected, .welcome, .pong:
            break
        }
    }

    private func finishPairing(senderID: String) {
        guard let peer = peers.values.first(where: {
            $0.senderID == senderID && $0.pairingCode != nil
        }) else { return }
        guard let publicKey = peer.senderPublicKey,
              let publicKeyText = messageKey(publicKey),
              let deviceKey,
              let clientNonce = peer.clientNonce,
              let serverNonce = peer.serverNonce,
              let secrets = SoundMuxSessionSecrets.derive(
                  localSecret: deviceKey.secret,
                  remotePublic: publicKey,
                  senderPublic: publicKey,
                  receiverPublic: deviceKey.publicKey,
                  clientNonce: clientNonce,
                  serverNonce: serverNonce
              ) else { return }
        trustedSenders[senderID] = publicKeyText
        trustedSenderNames[senderID] = peer.senderName
        UserDefaults.standard.set(trustedSenders, forKey: "soundMuxTrustedSenders")
        UserDefaults.standard.set(
            trustedSenderNames,
            forKey: "soundMuxTrustedSenderNames"
        )
        peer.pairingCode = nil
        pairingHandler?(nil)
        authorize(peer, secrets: secrets)
    }

    private func authorize(_ peer: ReceiverPeer, secrets: SoundMuxSessionSecrets) {
        if activePeer !== peer {
            receiverLock.withLock { MPReceiverEngineRebuffer(receiver) }
        }
        peer.authorized = true
        activePeer = peer
        sendControl(
            .init(kind: .welcome, fields: [
                "receiver_id": receiverID,
                "receiver_name": receiverName,
                "platform": "ios",
                "protocol": "3",
                "session": "3",
                "public_key": deviceKey?.publicKey.soundMuxHex ?? "",
                "server_nonce": peer.serverNonce?.soundMuxHex ?? "",
                "proof": secrets.proof.soundMuxHex,
                "heartbeat_ms": "1000",
                "capabilities": "audio,media,airplay,pairing,volume,latency,encryption",
            ]),
            to: peer
        )
        publish(state: "Connected")
    }

    private func sendControl(_ message: SoundMuxSessionMessage, to peer: ReceiverPeer) {
        sendDatagram(message.data, to: peer)
    }

    private func sendSecureControl(_ message: SoundMuxSessionMessage, to peer: ReceiverPeer) {
        guard let encrypted = peer.outboundCipher?.seal(message.data) else { return }
        sendDatagram(encrypted, to: peer)
    }

    private func sendDatagram(_ data: Data, to peer: ReceiverPeer) {
        if peer.isRelay {
            guard let relayChannel else { return }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
                _ = MPRelayChannelSend(relayChannel, base, data.count)
            }
            return
        }
        peer.controlConnection?.send(
            content: data,
            completion: .contentProcessed { _ in }
        )
    }

    private func messageKey(_ data: Data) -> String? {
        data.count == soundMuxCryptoKeyBytes ? data.soundMuxHex : nil
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

        let metrics = DispatchSource.makeTimerSource(queue: networkQueue)
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
        } else if activePeer?.authorized == true {
            currentState = "Connected"
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
            playoutActive: stats.playout_active,
            activeSenderName: activePeer?.authorized == true ? activePeer?.senderName : nil,
            trustedSenderCount: trustedSenders.count,
            trustedSenderNames: trustedSenders.keys.map {
                trustedSenderNames[$0] ?? "Unknown sender"
            }.sorted(),
            trustedDevices: trustedSenders.keys.map {
                TrustedSoundMuxDevice(
                    id: $0,
                    name: trustedSenderNames[$0] ?? "Unknown sender"
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    case cryptoUnavailable
    case relayUnavailable

    var errorDescription: String? {
        switch self {
        case .initializationFailed: "Could not initialize the receiver engine."
        case .invalidPort: "The UDP listen port is invalid."
        case .audioFormatUnavailable: "The 48 kHz stereo playback format is unavailable."
        case .cryptoUnavailable: "Could not create or load this device's secure identity."
        case .relayUnavailable: "The internet relay could not be reached."
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
