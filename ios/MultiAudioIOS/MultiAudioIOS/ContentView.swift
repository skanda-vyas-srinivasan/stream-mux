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
            .navigationTitle("multipoint")
        }
    }
}
