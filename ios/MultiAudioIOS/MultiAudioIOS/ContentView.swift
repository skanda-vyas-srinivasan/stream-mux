import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureManager

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac receiver") {
                    TextField("Mac IP address", text: $capture.receiverHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("UDP port", text: $capture.receiverPort)
                        .keyboardType(.numberPad)
                    LabeledContent("Network", value: capture.transportState)
                    LabeledContent("Packets sent", value: capture.packetsSent.formatted())
                    LabeledContent("Queue drops", value: capture.queueDrops.formatted())
                    LabeledContent("Conversion drops", value: capture.conversionDrops.formatted())
                    LabeledContent("Packet rate", value: capture.packetRate)
                    LabeledContent("Max send queue", value: capture.maxQueueDepth.formatted())
                    LabeledContent("Pacer underruns", value: capture.pacingUnderruns.formatted())
                }

                Section("Capture") {
                    LabeledContent("Status", value: capture.status)
                    LabeledContent("Audio buffers", value: capture.audioBufferCount.formatted())

                    if let format = capture.latestFormat {
                        LabeledContent("Format", value: format)
                        LabeledContent("Frames", value: capture.latestFrameCount.formatted())
                        LabeledContent("RMS level", value: capture.latestRMSLevel)
                        LabeledContent("Peak level", value: capture.latestPeakLevel)
                        LabeledContent("PTS", value: capture.latestPTS)
                        LabeledContent("Duration", value: capture.latestDuration)
                        LabeledContent("Host capture rate", value: capture.captureHostRate)
                        LabeledContent("Media capture rate", value: capture.captureMediaRate)
                        LabeledContent("Max callback gap", value: capture.maxCallbackGap)
                        LabeledContent("Max PTS error", value: capture.maxPTSError)
                    }
                }

                Section {
                    if capture.isCapturing {
                        Button("Stop Capture", role: .destructive) {
                            Task { await capture.stopCapture() }
                        }
                    } else {
                        Button("Start Streaming") {
                            capture.startStreaming()
                        }
                    }
                } footer: {
                    Text("Start the Mac receiver first, then approve full-display capture in Apple's picker.")
                }

                if let error = capture.errorMessage {
                    Section("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("SoundMux")
            .safeAreaInset(edge: .bottom) {
                Text("Stall recovery build")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }
}
