import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchGeometry: ObservableObject {
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 38
    @Published var hasNotch: Bool = false
    /// Animated reveal: false collapses the mask to the hardware notch; true expands horizontally.
    @Published var presented: Bool = false
    /// Animated text panel: false hides; true grows the mask downward.
    @Published var textShown: Bool = false

    func update(for screen: NSScreen) {
        hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
            notchHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 140
            notchHeight = 32
        }
    }
}

/// Mimics DynamicNotchKit's reveal: a black rectangle clipped by a NotchShape mask.
/// The mask's frame is animated (notch dimensions ↔ compact dimensions ↔ expanded with text).
final class NotchPanel: NSPanel {
    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 200

    private let notchGeometry = NotchGeometry()
    private var hideTask: DispatchWorkItem?

    init(engine: SpeechEngine) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
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
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        alphaValue = 0

        let hostingView = NSHostingView(rootView: NotchPanelView(engine: engine, geometry: notchGeometry))
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        hideTask?.cancel()
        hideTask = nil

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        notchGeometry.update(for: screen)

        let screenFrame = screen.frame
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.origin.y + screenFrame.height - Self.panelHeight
        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: false)

        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
        }

        // Slightly slower than collapse — gives the reveal a more relaxed feel.
        DispatchQueue.main.async { [notchGeometry] in
            withAnimation(.smooth(duration: 0.55)) {
                notchGeometry.presented = true
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard isVisible else { return }

        // Collapse mask back to hardware-notch dimensions and hide text in one synchronized animation.
        withAnimation(.smooth(duration: 0.4)) {
            notchGeometry.presented = false
            notchGeometry.textShown = false
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.orderOut(nil)
            }
        }
        hideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - Shape

struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 6, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

// MARK: - SwiftUI View

struct NotchPanelView: View {
    let engine: SpeechEngine
    @ObservedObject var geometry: NotchGeometry
    @State private var dotPulse = false

    private let compactExtension: CGFloat = 26 // Just enough room for the dot + padding.
    private let expandedExtension: CGFloat = 80 // Wider when transcription is showing.
    private let textExpandedHeight: CGFloat = 70
    private let compactTopCorner: CGFloat = 4
    private let compactBottomCorner: CGFloat = 10
    private let expandedTopCorner: CGFloat = 6
    private let expandedBottomCorner: CGFloat = 14
    private let dotSize: CGFloat = 6

    private var topCornerRadius: CGFloat {
        geometry.textShown ? expandedTopCorner : compactTopCorner
    }

    private var bottomCornerRadius: CGFloat {
        geometry.textShown ? expandedBottomCorner : compactBottomCorner
    }

    /// Mask width when listening but no text yet — minimal pill around the dot.
    private var compactWidth: CGFloat {
        geometry.hasNotch ? geometry.notchWidth + 2 * compactExtension : 110
    }

    /// Mask width when transcription is showing — wider to give text breathing room.
    private var expandedWidth: CGFloat {
        geometry.hasNotch ? geometry.notchWidth + 2 * expandedExtension : 240
    }

    /// Width of the inner content stack — always sized to the largest possible width;
    /// the mask hides the excess in compact states.
    private var contentWidth: CGFloat { expandedWidth }

    /// Mask width: collapses to hardware-notch width when not presented; widens with text.
    private var maskWidth: CGFloat {
        guard geometry.presented else { return geometry.notchWidth }
        return geometry.textShown ? expandedWidth : compactWidth
    }

    /// Mask height: grows downward when text is shown.
    private var maskHeight: CGFloat {
        geometry.notchHeight + (geometry.textShown ? textExpandedHeight : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .frame(width: contentWidth, height: geometry.notchHeight)

            transcriptionPanel
                .frame(width: contentWidth, height: geometry.textShown ? textExpandedHeight : 0)
                .clipped()
        }
        .background {
            // Generous overshoot guard so bouncy animations don't expose transparency at the edges.
            Rectangle().fill(.black).padding(-50)
        }
        .mask {
            NotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
                .frame(width: maskWidth, height: maskHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onChange(of: engine.isListening) {
            if engine.isListening {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            } else {
                dotPulse = false
            }
        }
        .onChange(of: engine.currentTranscription) {
            let hasText = !engine.currentTranscription.isEmpty
            if hasText, geometry.presented, !geometry.textShown {
                // Combined horizontal + vertical expansion in one motion.
                withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
                    geometry.textShown = true
                }
            }
        }
    }

    private var statusBar: some View {
        // Manual nudge: the dot's center sits `dotInsetFromNotch` pt to the left of
        // the hardware notch (smaller than half the compact extension), so it visually
        // reads as closer to the notch.
        let dotInsetFromNotch: CGFloat = 9
        let leadingPadding = expandedExtension - dotInsetFromNotch - dotSize / 2
        return HStack(spacing: 0) {
            Circle()
                .fill(Color.red)
                .frame(width: dotSize, height: dotSize)
                .shadow(color: .yellow.opacity(dotPulse ? 0.8 : 0.2), radius: dotPulse ? 6 : 2)
                .padding(.leading, leadingPadding)
            Spacer(minLength: 0)
        }
    }

    private var transcriptionPanel: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(engine.currentTranscription)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .id("bottom")
            }
            .onChange(of: engine.currentTranscription) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .transaction { $0.disablesAnimations = true }
    }
}
