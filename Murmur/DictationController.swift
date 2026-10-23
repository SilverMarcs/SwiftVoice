import AppKit
import ApplicationServices
import AVFoundation
import DictationCore

@Observable
@MainActor
final class DictationController {
    private enum Phase { case preparing, unavailable, ready, starting, recording, processing }
    private var phase: Phase = .unavailable
    private(set) var statusMessage = "Preparing Parakeet v2…"

    var isRecording: Bool { phase == .starting || phase == .recording }
    var isProcessing: Bool { phase == .processing }
    var isPreparingModel: Bool { phase == .preparing }
    var isModelReady: Bool { phase == .ready || isRecording || isProcessing }

    private let recognizer = ParakeetRecognizer()
    private let modelStore = ParakeetModelStore()
    private let microphone = MicrophoneCapture()
    private let shortcut = DictationKeyBlocker()
    private var preparationTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var recordingTask: Task<Void, Never>?
    private var recordingID: UUID?
    private var output: DictationOutput?
    private var notchPanel: NotchPanel?
    private var inputMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    init() {
        notchPanel = NotchPanel(engine: self)
        shortcut.onPress = { [weak self] in self?.toggleListening() }
        installMonitors()
        refreshShortcut()
        prepareModel()
    }

    func refreshShortcut() {
        if AXIsProcessTrusted() {
            shortcut.install()
        } else {
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func prepareModel() {
        guard phase == .unavailable else { return }
        #if !arch(arm64)
        statusMessage = "Parakeet v2 requires an Apple Silicon Mac"
        return
        #endif
        phase = .preparing
        statusMessage = "Verifying Parakeet v2…"
        let id = UUID()
        preparationID = id
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = try await modelStore.install { [weak self] fraction in
                    let percent = Int(fraction * 100)
                    Task { @MainActor [weak self] in
                        guard let self, self.preparationID == id else { return }
                        self.statusMessage = "Downloading Parakeet v2… \(percent)%"
                    }
                }
                try Task.checkCancellation()
                preparationID = nil
                statusMessage = "Loading Parakeet v2…"
                try await recognizer.load(from: directory)
                try Task.checkCancellation()
                phase = .ready
                statusMessage = readyMessage
            } catch {
                await recognizer.unload()
                phase = .unavailable
                statusMessage = Task.isCancelled ? "Model loading cancelled" : "Model error: \(error.localizedDescription)"
            }
            preparationID = nil
            preparationTask = nil
        }
    }

    func cancelModelPreparation() {
        preparationID = nil
        preparationTask?.cancel()
        statusMessage = "Cancelling model loading…"
    }

    func toggleListening() {
        if isRecording {
            stopListening()
        } else if phase == .ready {
            beginRecording()
        }
    }

    private func beginRecording() {
        // Reserve the session before awaiting permissions, so rapid F5 presses cannot start two recordings.
        phase = .starting
        let id = UUID()
        recordingID = id
        output = DictationOutput()
        statusMessage = "Preparing microphone…"
        recordingTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw RecognitionError.message("Allow Microphone access in System Settings to dictate.")
                }
                guard recordingID == id, phase == .starting else { completeRecording(id: id, text: ""); return }
                let stream = try microphone.start()
                phase = .recording
                statusMessage = "Recording — F5 to finish"
                notchPanel?.show()
                DictationSounds.shared.playBegin()
                var audio: [Float] = []
                var hasSpeech = false
                for try await samples in stream {
                    try Task.checkCancellation()
                    audio.append(contentsOf: samples)
                    if !hasSpeech {
                        let energy = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, samples.count))
                        hasSpeech = energy > 0.000004
                    }
                }
                let text = if hasSpeech { try await recognizer.transcribe(audio) } else { "" }
                completeRecording(id: id, text: text)
            } catch {
                guard recordingID == id else { return }
                stopListening()
                completeRecording(id: id, text: "", error: error)
            }
        }
    }

    private func stopListening() {
        guard isRecording else { return }
        let wasCapturing = phase == .recording
        phase = .processing
        statusMessage = "Processing dictation…"
        microphone.stop()
        if wasCapturing { DictationSounds.shared.playEnd() }
    }

    private func completeRecording(id: UUID, text: String, error: Error? = nil) {
        guard recordingID == id else { return }
        microphone.stop()
        notchPanel?.dismiss()
        let copied = output?.finish(text) == true
        output = nil
        recordingID = nil
        recordingTask = nil
        phase = .ready
        if let error { statusMessage = "Dictation error: \(error.localizedDescription)" }
        else { statusMessage = copied ? "Transcript copied to clipboard" : readyMessage }
    }

    private var readyMessage: String { "Ready — Parakeet v2 · F5 to dictate" }

    private func userChangedFocusOrTyped() {
        // Do not paste late results after the user moves focus or starts typing.
        output?.disableInsertion()
        stopListening()
    }

    private func installMonitors() {
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == DictationOutput.eventMarker { return }
            // The dictation key is consumed by our HID tap before this monitor.
            self?.userChangedFocusOrTyped()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.userChangedFocusOrTyped()
                if AXIsProcessTrusted() { self?.shortcut.install() }
            }
        }
    }

    func shutdown() {
        preparationTask?.cancel()
        recordingTask?.cancel()
        microphone.stop()
        shortcut.uninstall()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        inputMonitor = nil
        activationObserver = nil
    }
}
