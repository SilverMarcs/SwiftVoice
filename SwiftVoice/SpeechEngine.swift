import AppKit
import ApplicationServices
import AVFoundation
import Speech

@Observable
@MainActor
final class SpeechEngine {
    var isListening = false
    var currentTranscription = ""
    var statusMessage = "Ready — press F5 to toggle"

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var confirmedText = ""
    private var volatileText = ""

    private var micPanel: MicIndicatorPanel?
    private var keyDownMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private let dictationKeyBlocker = DictationKeyBlocker()

    /// True when we're streaming text directly into a focused editable
    /// element. Set at the start of each session; if false, we fall back to
    /// clipboard-paste at commit time.
    private var streamingActive = false

    /// What we have typed into the host field since this session began.
    /// Used to compute incremental diffs when the model revises words.
    /// We never delete more than `streamingInserted.count` characters, so
    /// pre-existing text in the field is never touched.
    private var streamingInserted: String = ""

    /// Prewarmed at app start so dictation toggle pays no model/asset cost.
    private var prewarmedLocale: Locale?

    init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupMonitors()
            self.promptAccessibilityIfNeeded()
            self.dictationKeyBlocker.onPress = { [weak self] in
                Task { @MainActor in self?.toggleListening() }
            }
            self.dictationKeyBlocker.install()
            // Pre-warm so the first show() doesn't pay the NSHostingView/SwiftUI
            // initial-layout cost on the animation hot path.
            self.micPanel = MicIndicatorPanel()
            Task { await self.prewarmRecognition() }
        }
    }

    /// Front-loads the slow speech-recognition setup so toggling F5 doesn't
    /// hitch on first use: microphone permission probe, locale lookup, asset
    /// install, audio-format query.
    private func prewarmRecognition() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            return
        }
        prewarmedLocale = locale
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }
        _ = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    /// macOS does not auto-prompt for Accessibility; without it our synthetic ⌘V is silently dropped.
    @discardableResult
    private func promptAccessibilityIfNeeded() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Monitors

    private func setupMonitors() {
        // Any keystroke other than the dictation key (which is swallowed at the
        // HID tap) cancels an in-progress recording — but ignore events that
        // originated from our own process, since streaming dictation injects
        // backspaces and unicode events that would otherwise self-cancel.
        let ourPid = Int64(ProcessInfo.processInfo.processIdentifier)
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if let cgEvent = event.cgEvent {
                let sourcePid = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
                if sourcePid == ourPid { return }
            }
            Task { @MainActor in
                if self?.isListening == true { self?.stopAndCommit() }
            }
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
        if !AXIsProcessTrusted() {
            statusMessage = "Grant Accessibility in System Settings — needed to paste"
            promptAccessibilityIfNeeded()
            return
        }

        confirmedText = ""
        volatileText = ""
        currentTranscription = ""
        isListening = true
        statusMessage = "Preparing…"

        streamingActive = hasEditableFocus()
        streamingInserted = ""
        micPanel?.show()

        do {
            try await beginRecognition()
            statusMessage = "Listening…"
        } catch {
            print("[SpeechEngine] start failed: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
            isListening = false
            streamingActive = false
            let panel = micPanel
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { panel?.dismiss() }
        }
    }

    private func beginRecognition() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw err("Microphone access denied")
        }

        let locale: Locale
        if let cached = prewarmedLocale {
            locale = cached
        } else if let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            locale = resolved
            prewarmedLocale = resolved
        } else {
            throw err("en-US not supported by SpeechTranscriber")
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            statusMessage = "Downloading model…"
            try await request.downloadAndInstall()
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw err("No compatible audio format")
        }

        let (inputSeq, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run {
                        guard let self, self.isListening else { return }
                        if isFinal {
                            self.confirmedText = self.confirmedText.isEmpty
                                ? text
                                : self.confirmedText + " " + text
                            self.volatileText = ""
                        } else {
                            self.volatileText = text
                        }
                        let updated = self.combinedText()
                        let changed = updated != self.currentTranscription
                        self.currentTranscription = updated
                        if self.streamingActive, changed {
                            self.streamUpdate(to: updated)
                            self.micPanel?.noteActivity()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.statusMessage = "Recognition error: \(error.localizedDescription)"
                }
            }
        }

        try await analyzer.start(inputSequence: inputSeq)

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            nonisolated(unsafe) let micBuffer = buffer
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: micBuffer))
                return
            }
            let ratio = analyzerFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(micBuffer.frameLength) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

            var consumed = false
            var convertError: NSError?
            converter.convert(to: outBuffer, error: &convertError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return micBuffer
            }
            if convertError == nil && outBuffer.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: outBuffer))
            }
        }

        // Audio system activation can block briefly; run off-main so the
        // mic indicator's spring-in animation doesn't hitch.
        try await Task.detached { try engine.start() }.value
    }

    // MARK: - Stop & Commit

    func stopAndCommit() {
        let textToInsert = currentTranscription.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capture the live state and reset UI synchronously so paste targets the user's app.
        let engine = audioEngine
        let analyzer = self.analyzer
        let continuation = inputContinuation
        let task = resultsTask

        audioEngine = nil
        self.analyzer = nil
        transcriber = nil
        inputContinuation = nil
        resultsTask = nil

        isListening = false
        currentTranscription = ""
        confirmedText = ""
        volatileText = ""
        statusMessage = "Ready — press F5 to toggle"
        micPanel?.dismiss()

        let wasStreaming = streamingActive
        streamingActive = false
        streamingInserted = ""

        // If we streamed, the text is already in the field — nothing more to do.
        // Otherwise (no editable focus at start), fall back to clipboard paste.
        if !wasStreaming, !textToInsert.isEmpty {
            pasteViaClipboard(textToInsert)
        }

        // Tear down the recognition pipeline off the hot path.
        Task.detached {
            engine?.stop()
            engine?.inputNode.removeTap(onBus: 0)
            continuation?.finish()
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            task?.cancel()
        }
    }

    // MARK: - Helpers

    private func combinedText() -> String {
        if volatileText.isEmpty { return confirmedText }
        if confirmedText.isEmpty { return volatileText }
        return confirmedText + " " + volatileText
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "SpeechEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Streaming insert

    /// Reconciles host-field state with the latest transcription by deleting
    /// the changed tail of what we previously typed and re-typing the new tail.
    /// We never delete past `streamingInserted`, so any pre-existing user text
    /// in the field is left untouched.
    private func streamUpdate(to newText: String) {
        let common = commonPrefixCount(streamingInserted, newText)
        let toDelete = streamingInserted.count - common
        if toDelete > 0 {
            sendBackspaces(count: toDelete)
        }
        if common < newText.count {
            let suffix = String(newText[newText.index(newText.startIndex, offsetBy: common)...])
            typeUnicode(suffix)
        }
        streamingInserted = newText
    }

    private func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var i = a.startIndex
        var j = b.startIndex
        var count = 0
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            a.formIndex(after: &i)
            b.formIndex(after: &j)
        }
        return count
    }

    private func sendBackspaces(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: true)
            down?.flags = []
            down?.post(tap: .cgSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: false)
            up?.flags = []
            up?.post(tap: .cgSessionEventTap)
        }
    }

    private func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // CGEventKeyboardSetUnicodeString is reliable up to ~20 UTF-16 units.
        // Chunk on Character boundaries so we never split a grapheme cluster.
        let maxUnits = 20
        var batch: [UInt16] = []

        func flush() {
            guard !batch.isEmpty else { return }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.flags = []
            batch.withUnsafeBufferPointer { buf in
                down?.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: buf.baseAddress)
            }
            down?.post(tap: .cgSessionEventTap)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.flags = []
            batch.withUnsafeBufferPointer { buf in
                up?.keyboardSetUnicodeString(stringLength: batch.count, unicodeString: buf.baseAddress)
            }
            up?.post(tap: .cgSessionEventTap)
            batch.removeAll(keepingCapacity: true)
        }

        for char in text {
            let units = Array(char.utf16)
            if batch.count + units.count > maxUnits {
                flush()
            }
            batch.append(contentsOf: units)
        }
        flush()
    }

    private func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            if let previousContents, !previousContents.isEmpty {
                for (type, data) in previousContents {
                    pasteboard.setData(data, forType: type)
                }
            }
        }
    }

    private func hasEditableFocus() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return false }
        let axElement = element as! AXUIElement

        // Native AppKit / UIKit-style editable roles.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            switch role {
            case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
                return true
            default:
                break
            }
        }

        // Chromium/Electron and web inputs often report AXGroup/AXWebArea but
        // expose a settable selected-text attribute when an editor is focused.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(axElement, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            // Guard against settable AXValue on non-text controls (sliders, etc.)
            // by requiring the current value to be a string.
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef) == .success,
               valueRef is String {
                return true
            }
        }

        return false
    }
}
