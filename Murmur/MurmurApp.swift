import SwiftUI

@main
struct MurmurApp: App {
    @State private var engine = DictationController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(engine: engine)
        } label: {
            Image(systemName: "waveform")
        }
        .menuBarExtraStyle(.menu)
    }
}
