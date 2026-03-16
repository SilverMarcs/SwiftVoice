import AppKit
import SwiftUI

/// Single-line floating panel at bottom-center showing current transcription.
class CursorPanel: NSPanel {
    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 50

    init(engine: SpeechEngine) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: CursorPanelView(engine: engine))
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.origin.y + 20

        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: true)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}

// MARK: - SwiftUI View

struct CursorPanelView: View {
    let engine: SpeechEngine
    @State private var dotPulse = false
    @State private var expanded = false

    private var hasText: Bool {
        !engine.currentTranscription.isEmpty
    }

    private var lastLine: String {
        let text = engine.currentTranscription
        guard !text.isEmpty else { return "" }
        if let range = text.range(of: "\n", options: .backwards) {
            return String(text[range.upperBound...])
        }
        if text.count > 60 {
            return "..." + String(text.suffix(57))
        }
        return text
    }

    private let closedWidth: CGFloat = 140
    private let expandedWidth: CGFloat = 480

    var body: some View {
        HStack(spacing: 8) {
            if !expanded {
                // Compact: red dot + "Listening..."
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .yellow.opacity(dotPulse ? 0.8 : 0.2), radius: dotPulse ? 6 : 2)

                Text("Listening...")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                // Expanded: show transcription text
                Text(lastLine)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: expanded ? expandedWidth : closedWidth)
        .background(.black.opacity(0.88), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: expanded)
        .onChange(of: engine.isListening) {
            if engine.isListening {
                expanded = false
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            } else {
                dotPulse = false
                expanded = false
            }
        }
        .onChange(of: engine.currentTranscription) {
            if hasText && !expanded {
                withAnimation(.easeInOut(duration: 0.3)) {
                    expanded = true
                }
            }
        }
    }
}
