import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureManager
    @StateObject private var receiver = ReverseAudioReceiver()
    @State private var devicePendingForget: TrustedSoundMuxDevice?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.indigo.opacity(0.28),
                        Color.blue.opacity(0.10),
                        Color(uiColor: .systemBackground),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if let pairing = receiver.pendingPairing {
                            pairingCard(pairing)
                        }
                        receiverCard
                        pairedDevicesCard
                        outputCard
                        diagnosticsCard
                        advancedCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task { receiver.startIfNeeded() }
            .alert(item: $devicePendingForget) { device in
                Alert(
                    title: Text("Forget \(device.name)?"),
                    message: Text(
                        "You will need to compare and approve a new code before this device can reconnect."
                    ),
                    primaryButton: .destructive(Text("Forget Device")) {
                        receiver.forgetTrustedSender(id: device.id)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(
                        colors: [.indigo, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("SoundMux")
                    .font(.title.bold())
                Text("Receive audio")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 16)
    }

    private var receiverCard: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 56, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(statusColor)
                    .contentTransition(.symbolEffect(.replace))

                VStack(spacing: 5) {
                    Text(statusTitle)
                        .font(.title2.bold())
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            HStack(spacing: 26) {
                transportButton(
                    title: "Previous",
                    symbol: "backward.end.fill",
                    command: .previous
                )
                transportButton(
                    title: "Play or pause",
                    symbol: "playpause.fill",
                    command: .playPause,
                    prominent: true
                )
                transportButton(
                    title: "Next",
                    symbol: "forward.end.fill",
                    command: .next
                )
            }

            Button {
                receiver.isListening ? receiver.stop() : receiver.start()
            } label: {
                Label(
                    receiver.isListening ? "Disconnect" : "Make This iPhone Available",
                    systemImage: receiver.isListening ? "stop.fill" : "antenna.radiowaves.left.and.right"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.isListening ? .secondary : .blue)

            if let error = receiver.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.32), lineWidth: 1)
        }
    }

    private func pairingCard(_ pairing: PendingSoundMuxPairing) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: deviceSymbol(for: pairing.platform))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair a new device")
                        .font(.headline)
                    Text(pairing.senderName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Encrypted", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 9) {
                Text("Make sure this code also appears on your Mac")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    ForEach(Array(pairing.code.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit))
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 38, height: 48)
                            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Pairing code \(pairing.code)")
            }

            HStack(spacing: 10) {
                Button("Not Now", role: .cancel) { receiver.rejectPairing() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Codes Match") { receiver.approvePairing() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            Text("Once paired, this device can reconnect without asking again.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.blue.opacity(0.30), lineWidth: 1)
        }
    }

    private var pairedDevicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Paired devices", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                Spacer()
                Text(receiver.trustedSenderCount.formatted())
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.primary.opacity(0.06), in: Capsule())
            }

            if receiver.trustedDevices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No paired devices yet")
                            .font(.subheadline.weight(.semibold))
                        Text("Connect from the Mac app to pair securely.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            } else {
                ForEach(receiver.trustedDevices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.blue)
                            .frame(width: 38, height: 38)
                            .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.subheadline.weight(.semibold))
                            Label(
                                receiver.activeSenderName == device.name ? "Connected now" : "Remembered",
                                systemImage: receiver.activeSenderName == device.name
                                    ? "circle.fill" : "lock.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                receiver.activeSenderName == device.name ? .green : .secondary
                            )
                        }
                        Spacer()
                        Button(role: .destructive) {
                            devicePendingForget = device
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Forget \(device.name)")
                    }
                    .padding(12)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Playback", systemImage: "speaker.wave.2.fill")
                    .font(.headline)
                Spacer()
                SoundMuxRoutePicker()
                    .frame(width: 38, height: 32)
            }

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $receiver.outputVolume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Network buffer")
                        .font(.subheadline.weight(.medium))
                    Text(receiver.isListening ? "Disconnect to change" : "Lower is faster; higher is steadier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Latency", selection: $receiver.targetLatencyMs) {
                    Text("Low · 40 ms").tag(40.0)
                    Text("Balanced · 60 ms").tag(60.0)
                    Text("Stable · 100 ms").tag(100.0)
                    Text("Max · 160 ms").tag(160.0)
                }
                .labelsHidden()
                .disabled(receiver.isListening)
            }
        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connection details", systemImage: "chart.bar.xaxis")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                metric("Packets", receiver.packetsReceived.formatted())
                metric("Buffered", receiver.bufferedAudio)
                metric("Recovered", receiver.fecRecovered.formatted())
                metric("Lost", receiver.packetsLost.formatted())
                metric("Concealed", receiver.concealedPackets.formatted())
                metric("Underruns", receiver.audioUnderruns.formatted())
            }

            HStack {
                Text("Receiver name")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("This iPhone", text: $receiver.deviceName)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 180)
                    .disabled(receiver.isListening)
            }
            .font(.subheadline)

            HStack {
                Text("UDP listen port")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Port", text: $receiver.listenPort)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .disabled(receiver.isListening)
            }
            .font(.subheadline)

        }
        .padding(18)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var advancedCard: some View {
        NavigationLink {
            ExperimentalSenderView()
                .environmentObject(capture)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 38, height: 38)
                    .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Experimental reverse mode")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Send iPhone audio to a Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func transportButton(
        title: String,
        symbol: String,
        command: RemoteMediaCommand,
        prominent: Bool = false
    ) -> some View {
        Button { receiver.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 24 : 20, weight: .semibold))
                .frame(width: prominent ? 64 : 50, height: prominent ? 64 : 50)
                .background(
                    prominent ? Color.blue : Color.primary.opacity(0.08),
                    in: Circle()
                )
                .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!receiver.isListening)
        .opacity(receiver.isListening ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusSymbol: String {
        switch receiver.state {
        case "Playing": "waveform.circle.fill"
        case "Buffering": "hourglass.circle.fill"
        case "Connected": "checkmark.circle.fill"
        case "Listening": "antenna.radiowaves.left.and.right.circle.fill"
        case "Stopped": "pause.circle.fill"
        default: "dot.radiowaves.left.and.right"
        }
    }

    private func deviceSymbol(for platform: String) -> String {
        switch platform.lowercased() {
        case "macos": "desktopcomputer"
        case "windows": "pc"
        case "ios": "iphone"
        default: "laptopcomputer"
        }
    }

    private var statusColor: Color {
        switch receiver.state {
        case "Playing": .green
        case "Buffering": .orange
        case "Connected": .green
        case "Listening": .blue
        case "Stopped": .secondary
        default: .indigo
        }
    }

    private var statusTitle: String {
        switch receiver.state {
        case "Playing": "Playing sender audio"
        case "Buffering": "Getting audio ready"
        case "Connected": "Connected to \(receiver.activeSenderName ?? "sender")"
        case "Listening": "Ready for your Mac"
        case "Stopped": "Receiver is off"
        default: receiver.state
        }
    }

    private var statusDetail: String {
        switch receiver.state {
        case "Playing": "Controls below operate the active media app on your Mac."
        case "Buffering": "Connected—playback will begin in a moment."
        case "Connected": "Ready. Start playback on the sending device."
        case "Listening": "SoundMux Sender will discover this iPhone automatically."
        case "Stopped": "Turn the receiver on to appear in the Mac app."
        default: "Preparing the receiver…"
        }
    }
}

private struct SoundMuxRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = .systemBlue
        picker.tintColor = .systemBlue
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct ExperimentalSenderView: View {
    @EnvironmentObject private var capture: CaptureManager

    var body: some View {
        Form {
            Section("Destination") {
                TextField("Mac IP address", text: $capture.receiverHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("UDP port", text: $capture.receiverPort)
                    .keyboardType(.numberPad)
                LabeledContent("Network", value: capture.transportState)
            }

            Section("Capture") {
                LabeledContent("Status", value: capture.status)
                LabeledContent("Audio buffers", value: capture.audioBufferCount.formatted())
                LabeledContent("Packets sent", value: capture.packetsSent.formatted())
                LabeledContent("Queue drops", value: capture.queueDrops.formatted())
                LabeledContent("Conversion drops", value: capture.conversionDrops.formatted())
                if let format = capture.latestFormat {
                    LabeledContent("Format", value: format)
                    LabeledContent("RMS level", value: capture.latestRMSLevel)
                    LabeledContent("Peak level", value: capture.latestPeakLevel)
                }
            }

            Section {
                if capture.isCapturing {
                    Button("Stop Capture", role: .destructive) {
                        Task { await capture.stopCapture() }
                    }
                } else {
                    Button("Start Experimental Stream") {
                        capture.startStreaming()
                    }
                }
            } footer: {
                Text("This direction still uses Apple's display-sharing audio picker.")
            }

            if let error = capture.errorMessage {
                Section("Error") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("iPhone → Mac")
    }
}
