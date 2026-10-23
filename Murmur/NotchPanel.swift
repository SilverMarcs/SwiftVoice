import AppKit
import SwiftUI

@Observable
@MainActor
final class NotchGeometry {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 38
    var hasNotch = false
    var presented = false

    func update(for screen: NSScreen) {
        hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
            notchHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 22
            notchHeight = 28
        }
    }
}

final class NotchPanel: NSPanel {
    private static let size = CGSize(width: 1200, height: 80)
    private let geometry = NotchGeometry()

    init(engine: DictationController) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = .screenSaver
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        alphaValue = 0
        contentView = NSHostingView(rootView: NotchPanelView(engine: engine, geometry: geometry))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        geometry.update(for: screen)
        setFrame(NSRect(x: screen.frame.midX - Self.size.width / 2,
                        y: screen.frame.maxY - Self.size.height,
                        width: Self.size.width, height: Self.size.height), display: false)
        orderFrontRegardless()
        withAnimation(.smooth(duration: 0.3)) { geometry.presented = true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }
        withAnimation(.smooth(duration: 0.3)) { geometry.presented = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.geometry.presented else { return }
                self.orderOut(nil)
            }
        }
    }
}

struct NotchPanelView: View {
    let engine: DictationController
    let geometry: NotchGeometry

    private var width: CGFloat { geometry.hasNotch ? geometry.notchWidth + 52 : 40 }
    private var leadingPadding: CGFloat { geometry.hasNotch ? 12 : (width - 12) / 2 }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if !engine.isRecording {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                        .shadow(color: .red.opacity(0.5), radius: 3)
                }
            }
            .frame(width: 12, height: 12)
            .padding(.leading, leadingPadding)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: geometry.notchHeight)
        .background(.black)
        .mask {
            NotchShape(topCornerRadius: 4, bottomCornerRadius: 10)
                .frame(width: geometry.presented ? width : geometry.notchWidth, height: geometry.notchHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .accessibilityLabel(engine.isRecording ? "Recording dictation" : "Processing dictation")
    }
}
