import AppKit
import ApplicationServices
import AVFoundation
import Speech

@Observable
@MainActor
final class SpeechEngine {
    var isListening = false
    var currentTranscription = ""
    var statusMessage = "Ready — double-tap Right ⌥ to toggle"

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var confirmedText = ""
    private var volatileText = ""

    private var notchPanel: NotchPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private let dictationKeyBlocker = DictationKeyBlocker()

    private var lastRightOptionTap: Date = .distantPast
    private let doubleTapInterval: TimeInterval = 0.4

    init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupMonitors()
            self.promptAccessibilityIfNeeded()
            self.dictationKeyBlocker.onPress = { [weak self] in
                Task { @MainActor in self?.toggleListening() }
            }
            self.dictationKeyBlocker.install()
            // Pre-warm the notch panel so the first show() doesn't pay the
            // NSHostingView/SwiftUI initial-layout cost on the animation hot path.
            self.notchPanel = NotchPanel(engine: self)
        }
    }

    /// macOS does not auto-prompt for Accessibility; without it our synthetic ⌘V is silently dropped.
    @discardableResult
    private func promptAccessibilityIfNeeded() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Hotkey monitors

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

        notchPanel?.show()

        do {
            try await beginRecognition()
            statusMessage = "Listening…"
        } catch {
            print("[SpeechEngine] start failed: \(error.localizedDescription)")
            statusMessage = error.localizedDescription
            isListening = false
            let panel = notchPanel
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { panel?.dismiss() }
        }
    }

    private func beginRecognition() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw err("Microphone access denied")
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
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
                        self.currentTranscription = self.combinedText()
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

        try engine.start()
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
        statusMessage = "Ready — double-tap Right ⌥ to toggle"
        notchPanel?.dismiss()

        if !textToInsert.isEmpty { pasteText(textToInsert) }

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

    // MARK: - Paste via Cmd+V

    private func pasteText(_ text: String) {
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
