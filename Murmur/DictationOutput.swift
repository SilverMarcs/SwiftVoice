import AppKit
import ApplicationServices

/// Pastes a completed recording only into the original focused target.
@MainActor
final class DictationOutput {
    static let eventMarker: Int64 = 0x4D55524D5552
    private let pid: pid_t?
    private let element: AXUIElement?
    private let window: AXUIElement?
    private var insertionAllowed = true

    init() {
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        element = Self.focusedElement()
        window = pid.flatMap(Self.focusedWindow)
    }

    func disableInsertion() { insertionAllowed = false }

    /// Return true when the transcript was left on the clipboard instead of inserted.
    func finish(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        if pasteViaClipboard(text) { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func insertionTargetMatches() -> Bool {
        guard let pid, pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let element, let focused = Self.focusedElement(), !Self.isSecure(element) else { return false }
        if let window {
            guard let focusedWindow = Self.focusedWindow(pid), CFEqual(window, focusedWindow) else { return false }
        }
        return CFEqual(element, focused)
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func pasteViaClipboard(_ text: String) -> Bool {
        guard window != nil, insertionAllowed, insertionTargetMatches(), let pid,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else { return false }
        let pasteboard = NSPasteboard.general
        let previous: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let changeCount = pasteboard.changeCount
        // Clipboard providers can take time to read. Check focus again immediately before posting.
        guard insertionAllowed, insertionTargetMatches() else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
            event.postToPid(pid)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            // A later user copy or another dictation owns the clipboard once its change count differs.
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            if !previous.isEmpty { pasteboard.writeObjects(previous) }
        }
        return true
    }

    private static func isSecure(_ axElement: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        return AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subrole) == .success
            && subrole as? String == "AXSecureTextField"
    }
}
