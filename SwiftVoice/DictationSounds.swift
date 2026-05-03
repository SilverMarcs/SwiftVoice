import AppKit

/// Plays the same start/stop chimes that macOS's built-in dictation uses,
/// loaded directly from the system CoreAudio bundle. Prewarmed at init so
/// the first toggle has no decode latency.
@MainActor
final class DictationSounds {
    static let shared = DictationSounds()

    private let begin: NSSound?
    private let end: NSSound?

    private static let beginPath = "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Resources/dt-begin.caf"
    private static let endPath = "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Resources/dt-confirm.caf"

    private init() {
        begin = NSSound(contentsOfFile: Self.beginPath, byReference: true)
        end = NSSound(contentsOfFile: Self.endPath, byReference: true)
    }

    func playBegin() {
        begin?.stop()
        begin?.play()
    }

    func playEnd() {
        end?.stop()
        end?.play()
    }
}
