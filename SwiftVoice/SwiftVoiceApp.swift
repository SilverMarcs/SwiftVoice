import SwiftUI

@main
struct SwiftVoiceApp: App {
    @State private var engine = SpeechEngine()

    var body: some Scene {
        MenuBarExtra {
            Text(engine.statusMessage)

            Button(engine.isListening ? "Stop Listening" : "Start Listening") {
                engine.toggleListening()
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: engine.isListening ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.menu)
    }
}
