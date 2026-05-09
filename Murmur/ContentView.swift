import SwiftUI

struct ContentView: View {
    @Environment(SpeechEngine.self) private var engine

    var body: some View {
        Text(engine.statusMessage)
            .disabled(true)

        Button(engine.isListening ? "Stop Listening" : "Start Listening") {
            engine.toggleListening()
        }

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
