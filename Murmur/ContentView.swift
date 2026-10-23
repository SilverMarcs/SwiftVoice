import SwiftUI

struct ContentView: View {
    let engine: DictationController

    var body: some View {
        Text(engine.statusMessage)
            .disabled(true)

        if engine.isPreparingModel {
            Button("Cancel Model Loading", action: engine.cancelModelPreparation)
        } else if !engine.isModelReady {
            Button("Retry Model Loading", action: engine.prepareModel)
        }

        Divider()

        Button("Quit Murmur") {
            engine.shutdown()
            NSApp.terminate(nil)
        }
        .onAppear { engine.refreshShortcut() }
    }
}
