import Speech
import AVFoundation
import AppKit

@Observable
final class SpeechEngine {
    var isListening = false
    var currentTranscription = ""
    var statusMessage = "Ready — double-tap Right ⌥ to toggle"

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var insertedLength = 0

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?

    // Double-tap detection
    private var lastRightOptionTap: Date = .distantPast
    private let doubleTapInterval: TimeInterval = 0.4

    init() {
        speechRecognizer = SFSpeechRecognizer()
        setupMonitors()
    }

    // MARK: - Event Monitors

    private func setupMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in
                self?.handleEvent(event)
            }
            return event
        }

        // Stop listening on app switch
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isListening == true {
                    self?.stopListening()
                }
            }
        }
    }

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            // Right Option key released (keyCode 61)
            if event.keyCode == 61 && !event.modifierFlags.contains(.option) {
                let now = Date()
                if now.timeIntervalSince(lastRightOptionTap) < doubleTapInterval {
                    lastRightOptionTap = .distantPast
                    toggleListening()
                } else {
                    lastRightOptionTap = now
                }
            }

        case .keyDown:
            // Enter stops listening
            if event.keyCode == 36 && isListening {
                stopListening()
            }

        default:
            break
        }
    }

    // MARK: - Toggle

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            Task { await startListening() }
        }
    }

    // MARK: - Start / Stop

    private func startListening() async {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { s in continuation.resume(returning: s) }
        }
        guard status == .authorized else {
            statusMessage = "Speech recognition not authorized"
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            return
        }

        isListening = true
        insertedLength = 0
        currentTranscription = ""
        statusMessage = "Listening..."

        await startRecognitionSession()
    }

    private func startRecognitionSession() async {
        guard let speechRecognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        nonisolated(unsafe) let req = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }

        do {
            try engine.start()
        } catch {
            statusMessage = "Audio error: \(error.localizedDescription)"
            isListening = false
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.currentTranscription = text

                    if text.count > self.insertedLength {
                        let start = text.index(text.startIndex, offsetBy: self.insertedLength)
                        self.typeText(String(text[start...]))
                        self.insertedLength = text.count
                    }

                    if result.isFinal {
                        self.cleanupSession()
                        self.typeText(" ")
                        self.insertedLength = 0
                        self.currentTranscription = ""
                        await self.startRecognitionSession()
                    }
                }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        self.cleanupSession()
                        self.insertedLength = 0
                        await self.startRecognitionSession()
                    } else {
                        self.statusMessage = "Error: \(error.localizedDescription)"
                        self.stopListening()
                    }
                }
            }
        }
    }

    private func cleanupSession() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        audioEngine = nil
    }

    func stopListening() {
        cleanupSession()
        isListening = false
        insertedLength = 0
        statusMessage = "Ready — double-tap Right ⌥ to toggle"
    }

    // MARK: - Type text via CGEvent

    private func typeText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            var utf16 = Array(String(char).utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
        }
    }
}
