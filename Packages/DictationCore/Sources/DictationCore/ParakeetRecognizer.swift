import FluidAudio
import Foundation

public actor ParakeetRecognizer {
    private var manager: AsrManager?

    public init() {}

    public func load(from directory: URL) async throws {
        await unload()
        #if !arch(arm64)
        throw RecognitionError.message("Parakeet v2 requires an Apple Silicon Mac.")
        #else
        let models = try await AsrModels.loadLocalOnly(from: directory, version: .v2)
        let manager = AsrManager()
        try await manager.initialize(models: models)
        try Task.checkCancellation()
        self.manager = manager
        #endif
    }

    public func unload() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try Task.checkCancellation()
        guard let manager else { throw RecognitionError.message("Parakeet v2 isn't ready.") }
        try await manager.resetDecoderState()
        let input = samples.count < 16_000 ? samples + Array(repeating: 0, count: 16_000 - samples.count) : samples
        let result = try await manager.transcribe(input, source: .microphone)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
