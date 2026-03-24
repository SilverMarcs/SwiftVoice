import Speech
import AVFoundation
import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SwiftVoice", category: "SpeechEngine")

@Observable
final class SpeechEngine {
    var isListening = false
    var currentTranscription = ""
    var statusMessage = "Ready — double-tap Right ⌥ to toggle"

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Text locked in from previous segments / sessions. Never goes backwards.
    private var confirmedText = ""

    /// The last partial text the recognizer gave us in this session.
    private var lastSessionText = ""

    /// Incremented on each new session so stale callbacks from cancelled tasks are ignored.
    private var sessionID = 0

    // MARK: - Floating transcription panel

    private var cursorPanel: CursorPanel?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?

    private var lastRightOptionTap: Date = .distantPast
    private let doubleTapInterval: TimeInterval = 0.4

    init() {
        speechRecognizer = SFSpeechRecognizer()
        // Defer monitor setup so it doesn't interfere with MenuBarExtra initialization
        DispatchQueue.main.async { [weak self] in
            self?.setupMonitors()
        }
    }

    // MARK: - Event Monitors

    private func setupMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.handleEvent(event) }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor in self?.handleEvent(event) }
            return event
        }

        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isListening == true { self?.stopAndCommit() }
            }
        }
    }

    private func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
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
            if isListening { stopAndCommit() }
        default:
            break
        }
    }

    // MARK: - Toggle

    func toggleListening() {
        if isListening {
            stopAndCommit()
        } else {
            Task { await startListening() }
        }
    }

    // MARK: - Start

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
        confirmedText = ""
        lastSessionText = ""
        currentTranscription = ""
        statusMessage = "Listening..."

        if cursorPanel == nil {
            cursorPanel = CursorPanel(engine: self)
        }
        cursorPanel?.show()

        await startRecognitionSession()
    }

    private func startRecognitionSession() async {
        guard let speechRecognizer else { return }

        sessionID += 1
        let mySession = sessionID

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
                guard let self, self.isListening, self.sessionID == mySession else { return }

                if let result {
                    let sessionText = result.bestTranscription.formattedString

                    // Detect intra-session reset: recognizer silently replaced all text
                    if self.lastSessionText.count > 10
                        && sessionText.count < self.lastSessionText.count / 2 {
                        logger.info("[\(mySession)] reset detected: '\(sessionText)' replaced '\(self.lastSessionText)'")
                        if self.confirmedText.isEmpty {
                            self.confirmedText = self.lastSessionText
                        } else {
                            self.confirmedText += " " + self.lastSessionText
                        }
                    }
                    self.lastSessionText = sessionText

                    // Build full transcription: confirmed prefix + current session
                    if self.confirmedText.isEmpty {
                        self.currentTranscription = sessionText
                    } else {
                        self.currentTranscription = self.confirmedText + " " + sessionText
                    }

                    if result.isFinal {
                        self.confirmedText = self.currentTranscription
                        self.lastSessionText = ""
                        self.cleanupSession()
                        await self.startRecognitionSession()
                    }
                }

                if let error {
                    logger.warning("[\(mySession)] error: \(error.localizedDescription)")
                    self.confirmedText = self.currentTranscription
                    self.lastSessionText = ""
                    self.cleanupSession()
                    await self.startRecognitionSession()
                }
            }
        }
    }

    // MARK: - Stop & Commit

    func stopAndCommit() {
        let textToInsert = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

        cleanupSession()
        isListening = false
        confirmedText = ""
        lastSessionText = ""
        currentTranscription = ""
        statusMessage = "Ready — double-tap Right ⌥ to toggle"

        // Dismiss floating transcription panel
        cursorPanel?.dismiss()

        if !textToInsert.isEmpty {
            pasteText(textToInsert)
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

    // MARK: - Commit: Clipboard + Cmd+V

    private func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        // Set clipboard to transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Send Cmd+V
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        // Restore original clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pasteboard.clearContents()
            if let previousContents, !previousContents.isEmpty {
                for (type, data) in previousContents {
                    pasteboard.setData(data, forType: type)
                }
            }
        }
    }
}
