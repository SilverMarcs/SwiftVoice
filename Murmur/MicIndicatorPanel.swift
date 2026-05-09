import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Small floating indicator that appears near the caret while dictation is
/// active, mimicking the native macOS dictation pill.
@MainActor
final class MicIndicatorPanel: NSPanel {
    private static let size = CGSize(width: 28, height: 28)
    /// How long the panel stays hidden after the last write activity before
    /// reappearing at the new caret position.
    private static let idleDelay: TimeInterval = 1.0
    /// Gap below the caret line before the indicator's top edge.
    private static let caretGap: CGFloat = 16

    private let viewState = MicIndicatorState()
    private var idleTimer: Timer?
    private var orderOutTask: DispatchWorkItem?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        contentView = NSHostingView(rootView: MicIndicatorView(state: viewState))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        idleTimer?.invalidate()
        idleTimer = nil
        orderOutTask?.cancel()
        orderOutTask = nil

        let origin = computeOrigin()
        setFrame(NSRect(origin: origin, size: Self.size), display: false)
        if !isVisible {
            orderFrontRegardless()
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
            viewState.visible = true
        }
    }

    /// Mimics native dictation: while text is being written we hide the
    /// indicator; once writing has been idle briefly, we re-show it at the
    /// updated caret position.
    func noteActivity() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            viewState.visible = false
        }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
    }

    func dismiss() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard isVisible else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            viewState.visible = false
        }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.viewState.visible == false else { return }
            self.orderOut(nil)
        }
        orderOutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    /// Anchors the indicator just below the caret's line. Falls back to the
    /// element's bottom edge or the mouse cursor when AX can't locate one.
    private func computeOrigin() -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func toCocoa(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.origin.x,
                y: primaryHeight - rect.origin.y - rect.size.height,
                width: rect.size.width,
                height: rect.size.height
            )
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            let element = focused as! AXUIElement

            // Prefer the caret rect — gives the actual cursor line in tall fields.
            if let range = axSelectedRange(element),
               let caretAX = axBoundsForRange(element, range: CFRange(location: range.location, length: 0)),
               caretAX.size.height > 1 {
                let caret = toCocoa(caretAX)
                return CGPoint(
                    x: caret.minX - Self.size.width / 2,
                    y: caret.minY - Self.size.height - Self.caretGap
                )
            }

            // Fallback: just below element's bottom edge.
            if let elementAX = axRect(of: element) {
                let element = toCocoa(elementAX)
                return CGPoint(
                    x: element.minX - Self.size.width / 2,
                    y: element.minY - Self.size.height - Self.caretGap
                )
            }
        }

        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - Self.size.width / 2, y: mouse.y - Self.size.height - 20)
    }
}

// MARK: - SwiftUI

@MainActor
private final class MicIndicatorState: ObservableObject {
    @Published var visible: Bool = false
}

private struct MicIndicatorView: View {
    @ObservedObject var state: MicIndicatorState

    var body: some View {
        Circle()
            .fill(Color.blue.opacity(0.9))
            .frame(width: 24, height: 24)
            .glassEffect(.regular.tint(.blue), in: Circle())
            .overlay {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .padding(2)
            .scaleEffect(state.visible ? 1.0 : 0.4)
            .opacity(state.visible ? 1.0 : 0.0)
    }
}

// MARK: - AX helpers

@MainActor
private func axRect(of element: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success else {
        return nil
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

@MainActor
private func axSelectedRange(_ element: AXUIElement) -> CFRange? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
          let value = ref else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
    return range
}

@MainActor
private func axBoundsForRange(_ element: AXUIElement, range: CFRange) -> CGRect? {
    var rangeCopy = range
    guard let rangeValue = AXValueCreate(.cfRange, &rangeCopy) else { return nil }
    var resultRef: CFTypeRef?
    let status = AXUIElementCopyParameterizedAttributeValue(
        element,
        kAXBoundsForRangeParameterizedAttribute as CFString,
        rangeValue,
        &resultRef
    )
    guard status == .success, let result = resultRef else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else { return nil }
    return rect
}
