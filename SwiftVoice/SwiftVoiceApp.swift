import SwiftUI

@main
struct SwiftVoiceApp: App {
    @State private var engine = SpeechEngine()

    var body: some Scene {
        MenuBarExtra {
            Text(engine.statusMessage)

            Divider()

            Button("Quit Murmur") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: "waveform")
        }
        .menuBarExtraStyle(.menu)
    }
}
