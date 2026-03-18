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

    // MARK: - Accessibility: live text field updates

    /// The text field element we're typing into, captured when listening starts.
    private var targetElement: AXUIElement?

    /// Cursor position in the text field when we started listening.
    private var insertionPoint: Int = 0

    /// How many characters we've inserted so far (so we can select and replace them).
    private var insertedCount: Int = 0

    /// Fallback panel shown near cursor when no AX text field is detected.
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

        captureTargetElement()

        isListening = true
        confirmedText = ""
        lastSessionText = ""
        currentTranscription = ""
        statusMessage = "Listening..."

        // No AX text field → show fallback panel near cursor
        if targetElement == nil {
            if cursorPanel == nil {
                cursorPanel = CursorPanel(engine: self)
            }
            cursorPanel?.show()
        }

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

                    // Push live update into the text field
                    self.updateTargetText(self.currentTranscription)

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

        // Dismiss fallback panel if it was showing
        cursorPanel?.dismiss()

        if targetElement != nil && insertedCount > 0 {
            // Text is already in the field via AX updates — just move cursor to end
            placeCursor(at: insertionPoint + insertedCount)
            releaseTarget()
        } else if !textToInsert.isEmpty {
            // No AX target — paste via clipboard
            pasteText(textToInsert)
            releaseTarget()
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

    // MARK: - Accessibility: capture & update text field

    private func captureTargetElement() {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success else {
            logger.warning("Could not get focused element")
            targetElement = nil
            return
        }

        let element = focused as! AXUIElement

        // Verify it's a text input
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleValue
        ) == .success, let role = roleValue as? String else {
            logger.warning("Could not get role of focused element")
            targetElement = nil
            return
        }

        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard textRoles.contains(role) else {
            logger.warning("Focused element is not a text field (role: \(role))")
            targetElement = nil
            return
        }

        // Get current cursor position
        var selectedRange: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRange
        ) == .success else {
            logger.warning("Could not get cursor position")
            targetElement = nil
            return
        }

        var range = CFRange()
        AXValueGetValue(selectedRange as! AXValue, .cfRange, &range)

        targetElement = element
        insertionPoint = range.location + range.length // end of selection
        insertedCount = 0

        logger.info("Captured text field (role: \(role)) at cursor position \(self.insertionPoint)")
    }

    /// Select our previously inserted range and replace it with the new text.
    private func updateTargetText(_ text: String) {
        guard let element = targetElement else { return }

        // Select the range we previously inserted
        var selectRange = CFRange(location: insertionPoint, length: insertedCount)
        guard let rangeValue = AXValueCreate(.cfRange, &selectRange) else { return }

        let selectResult = AXUIElementSetAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, rangeValue
        )
        guard selectResult == .success else {
            logger.warning("Failed to set selection range")
            return
        }

        // Replace selection with new text
        let textResult = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard textResult == .success else {
            logger.warning("Failed to set text")
            return
        }

        insertedCount = text.count
    }

    /// Move cursor to a specific position (deselect).
    private func placeCursor(at position: Int) {
        guard let element = targetElement else { return }
        var range = CFRange(location: position, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, rangeValue
            )
        }
    }

    private func releaseTarget() {
        targetElement = nil
        insertionPoint = 0
        insertedCount = 0
    }

    // MARK: - Fallback: Clipboard + Cmd+V

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
