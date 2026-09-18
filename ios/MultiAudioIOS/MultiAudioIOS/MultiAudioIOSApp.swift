import SwiftUI

@main
struct MultiAudioIOSApp: App {
    @StateObject private var captureManager = CaptureManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(captureManager)
        }
    }
}

