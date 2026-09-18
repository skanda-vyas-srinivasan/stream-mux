#if DEBUG
import Foundation
import OSLog

/// Debug-only observability for physical-device tests. This reads immutable
/// snapshots after capture/transport processing and never controls audio flow.
/// Release builds omit this type and its call site entirely.
enum USBMetricLogger {
    private static let logger = Logger(
        subsystem: "com.skandavyas.multipoint.ios",
        category: "USBMetrics"
    )
    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastLogTime: TimeInterval = 0

    static func record(metadata: AudioBufferMetadata, transport: TransportSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldLog = lock.withLock { () -> Bool in
            guard lastLogTime == 0 || now - lastLogTime >= 1 else { return false }
            lastLogTime = now
            return true
        }
        guard shouldLog else { return }

        let message = "MULTIPOINT_METRICS capture_frames=\(metadata.frameCount) duration_ms=\(metadata.durationSeconds * 1000) sample_rate=\(metadata.sampleRate) channels=\(metadata.channelCount) pts=\(metadata.presentationTimestampSeconds) rms_dbfs=\(metadata.rmsDBFS ?? -.infinity) packets_sent=\(transport.packetsSent) packet_rate=\(transport.packetRate) max_callback_gap_ms=\(transport.maxCallbackGapMS) max_pts_error_ms=\(transport.maxPTSErrorMS) max_send_gap_ms=\(transport.maxSendGapMS) send_gap_events=\(transport.sendGapEvents) send_queue=\(transport.currentQueueDepth) max_send_queue=\(transport.maxQueueDepth) pacer_underruns=\(transport.pacingUnderruns) send_failures=\(transport.sendFailures) queue_drops=\(transport.queueDrops) conversion_drops=\(transport.conversionDrops) network=\(transport.state)"
        logger.info("\(message, privacy: .public)")
        print(message)
    }
}
#endif
