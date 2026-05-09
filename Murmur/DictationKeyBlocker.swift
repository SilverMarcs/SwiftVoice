import AppKit
import ApplicationServices

/// Swallows the bare-F5 "Dictation" key at the HID event tap so macOS' built-in
/// dictation overlay never fires. On default macOS keyboards bare F5 arrives as
/// keycode 176 (a remapped media-style code), distinct from real F5 (keycode 96)
/// which is what fn+F5 produces — so swallowing 176 leaves real F5 untouched.
final class DictationKeyBlocker {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    var onPress: (() -> Void)?

    private static let dictationKeyCode: Int64 = 176

    func install() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let blocker = Unmanaged<DictationKeyBlocker>.fromOpaque(refcon).takeUnretainedValue()
                return blocker.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
    }

    func uninstall() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.dictationKeyCode {
                if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let cb = onPress
                    DispatchQueue.main.async { cb?() }
                }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
