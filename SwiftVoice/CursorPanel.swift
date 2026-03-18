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
        hasShadow = true
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
    @State private var showText = false

    private var hasText: Bool {
        !engine.currentTranscription.isEmpty
    }

    private let closedWidth: CGFloat = 130
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
                Text(engine.currentTranscription)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(showText ? 1 : 0)
                    .animation(.easeIn(duration: 0.2), value: showText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: expanded ? expandedWidth : closedWidth)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: expanded)
        .onChange(of: engine.isListening) {
            if engine.isListening {
                showText = false
                expanded = false
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            } else {
                dotPulse = false
                showText = false
                expanded = false
            }
        }
        .onChange(of: engine.currentTranscription) {
            if hasText && !expanded {
                withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
                    expanded = true
                } completion: {
                    showText = true
                }
            }
        }
    }
}
