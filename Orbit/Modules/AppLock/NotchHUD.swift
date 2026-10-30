import AVFoundation
import AppKit
import Observation
import SwiftUI

/// What the notch HUD shows. Kept free of the rest of Orbit so it can be rendered on its own.
@MainActor @Observable
final class NotchHUDModel {
    enum Phase: Equatable {
        case scanning
        case matched
        case failed
        /// A one-line notice, e.g. after the Mac was unlocked.
        case message
    }

    var phase: Phase = .scanning
    /// 0…1: how many of the ring's ticks are lit.
    var progress: Double = 0
    var label = ""
    /// The small app-lock look: a face glyph and a label, no camera picture.
    var compact = false
    var session: AVCaptureSession?
    var buttons = false
    var expanded = false
    var shakes = 0
    /// Size of the screen's notch, or a sliver at the top of the menu bar when there's none.
    var notch = CGSize(width: 185, height: 32)
    var hasNotch = true
    var systemAuthTitle = "Touch ID / Password"
    var cancelTitle = "Cancel"
    var onSystemAuth: (() -> Void)?
    var onCancel: (() -> Void)?
    /// An optional third pill, e.g. "Allow Camera".
    var extraTitle: String?
    var onExtra: (() -> Void)?

    var expandedSize: CGSize {
        // Wide enough for the label and the pills as they really measure (Korean runs longer than
        // English), up to what the HUD's canvas can hold.
        let labelFont = NSFont.systemFont(ofSize: phase == .message ? 12 : 11, weight: phase == .message ? .semibold : .medium)
        let labelWidth = Self.measure(label, labelFont) + (phase == .message ? 28 + 21 : 24) + 8
        let pillFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let pills = buttons ? [extraTitle, systemAuthTitle, cancelTitle].compactMap { $0 }.map { Self.measure($0, pillFont) + 22 } : []
        let pillsWidth = pills.isEmpty ? 0 : pills.reduce(0, +) + CGFloat(pills.count - 1) * 6 + 24
        let width = min(340, max(notch.width + 2 * Self.shoulder + 24, compact ? 196 : 200, labelWidth, pillsWidth))
        let body: CGFloat = phase == .message ? 44 : (compact ? 90 : 140)
        return CGSize(width: width, height: notch.height + body + (buttons ? 36 : 0))
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The inward curves where the shape meets the bezel. The shape is this much wider than the
    /// notch on each side, so at its smallest its body is exactly the notch.
    static let shoulder: CGFloat = 8

    var collapsedSize: CGSize {
        CGSize(width: notch.width + 2 * Self.shoulder, height: hasNotch ? notch.height : 0)
    }
}

/// A black panel that grows out of the notch like a Dynamic Island: a ring of ticks around the
/// camera picture that light up as your face matches, then a green check.
struct NotchHUDView: View {
    let model: NotchHUDModel
    static let green = Color(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255)

    var body: some View {
        let size = model.expanded ? model.expandedSize : model.collapsedSize
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Grows out of the notch like Glance: the shape first, the content once there's room.
                NotchShape(topRadius: NotchHUDModel.shoulder, bottomRadius: model.expanded ? 24 : 8)
                    .fill(.black)
                    .shadow(color: .black.opacity(model.hasNotch ? 0 : 0.35), radius: 10, y: 4)
                if model.expanded {
                    content
                        .padding(.top, model.notch.height + (model.phase == .message ? 6 : 10))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.82, anchor: .top))
                                .animation(.spring(duration: 0.34, bounce: 0.2).delay(0.12)),
                            removal: .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                                .animation(.easeIn(duration: 0.12))))
                }
            }
            .frame(width: size.width, height: size.height)
            .modifier(Shake(animatableData: CGFloat(model.shakes)))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        if model.phase == .message {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Self.green)
                Text(model.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.horizontal, 14)
        } else {
            VStack(spacing: model.compact ? 8 : 10) {
                TickRing(progress: model.progress, phase: model.phase, compact: model.compact) {
                    center
                }
                .frame(width: model.compact ? 52 : 100, height: model.compact ? 52 : 100)
                // A small beat as the ticks go green.
                .scaleEffect(model.phase == .matched ? 1.06 : 1)
                .animation(.spring(duration: 0.32, bounce: 0.55), value: model.phase)

                Text(model.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 12)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: model.label)

                if model.buttons {
                    HStack(spacing: 6) {
                        if let extra = model.extraTitle {
                            HUDPill(title: extra, prominent: true) { model.onExtra?() }
                            HUDPill(title: model.systemAuthTitle, prominent: false) { model.onSystemAuth?() }
                        } else {
                            HUDPill(title: model.systemAuthTitle, prominent: true) { model.onSystemAuth?() }
                        }
                        HUDPill(title: model.cancelTitle, prominent: false) { model.onCancel?() }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder private var center: some View {
        let side: CGFloat = model.compact ? 24 : 64
        ZStack {
            if model.phase == .matched {
                Circle().fill(Self.green)
                    .frame(width: model.compact ? 26 : 44, height: model.compact ? 26 : 44)
                    .overlay(Image(systemName: "checkmark").font(.system(size: model.compact ? 12 : 20, weight: .bold)).foregroundStyle(.white))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else if !model.compact, let session = model.session {
                CameraPreview(session: session)
                    .frame(width: side, height: side)
                    .clipShape(Circle())
                    .opacity(model.phase == .failed ? 0.45 : 1)
                    .transition(.opacity)
            } else {
                Image(systemName: "faceid")
                    .font(.system(size: model.compact ? 18 : 34, weight: .regular))
                    .foregroundStyle(.white.opacity(model.phase == .failed ? 0.45 : 0.9))
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.45), value: model.phase)
    }
}

/// About forty short radial ticks; the first `progress` of them lit, all green on a match.
private struct TickRing<Center: View>: View {
    let progress: Double
    let phase: NotchHUDModel.Phase
    let compact: Bool
    @ViewBuilder var center: Center

    private let count = 40

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let length: CGFloat = compact ? 4 : 9
            ZStack {
                center
                ForEach(0..<count, id: \.self) { i in
                    let lit = phase == .matched || (phase == .scanning && Double(i) < progress * Double(count))
                    Capsule()
                        .fill(color(lit: lit))
                        .frame(width: compact ? 1.6 : 2.4, height: length)
                        .offset(y: -side / 2 + length / 2)
                        .rotationEffect(.degrees(Double(i) / Double(count) * 360))
                        .animation(.easeOut(duration: 0.18).delay(Double(i) * (phase == .matched ? 0.004 : 0.008)), value: lit)
                }
            }
            .frame(width: side, height: side)
            .animation(.easeOut(duration: 0.3), value: phase)
        }
    }

    private func color(lit: Bool) -> Color {
        if phase == .matched { return NotchHUDView.green }
        if phase == .failed { return .white.opacity(0.1) }
        return lit ? .white.opacity(0.95) : .white.opacity(0.2)
    }
}

private struct HUDPill: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize()
                .foregroundStyle(prominent ? .black : .white)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(prominent ? .white : .white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

/// Flush with the top of the screen, little inward curves where it meets the menu bar, rounded below.
struct NotchShape: Shape {
    var topRadius: CGFloat = 6
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// A gentle side-to-side shake each time `animatableData` steps by one.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(animatableData * .pi * 4), y: 0))
    }
}

/// Live, mirrored camera picture.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Panel

/// The window behind the HUD: fixed size at the top center of a screen, transparent around the shape.
@MainActor
final class NotchHUD {
    static let shared = NotchHUD()
    let model = NotchHUDModel()
    private var generation = 0
    private static let canvas = CGSize(width: 360, height: 280)

    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero, focusable: false)
        // Over the menu bar and its status items, so the shape reads as part of the notch.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior.insert(.stationary)
        p.hasShadow = false
        p.setContent(NotchHUDView(model: model))
        return p
    }()

    var isShowing: Bool { panel.isVisible && model.expanded }

    /// Opens (or re-uses) the HUD with a fresh state.
    func show(on screen: NSScreen?, label: String, compact: Bool, phase: NotchHUDModel.Phase = .scanning,
              buttons: Bool = false, onSystemAuth: (() -> Void)? = nil, onCancel: (() -> Void)? = nil,
              extra: (title: String, action: () -> Void)? = nil) {
        generation += 1
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let wasOpen = panel.isVisible && model.expanded
        model.systemAuthTitle = "Touch ID / Password".loc
        model.cancelTitle = "Cancel".loc
        model.onSystemAuth = onSystemAuth
        model.onCancel = onCancel
        model.onExtra = extra?.action
        model.session = nil
        model.progress = 0
        if !wasOpen {
            model.expanded = false
            measure(screen)
            model.phase = phase
            model.compact = compact
            model.label = label
            model.buttons = buttons
            model.extraTitle = extra?.title
        }
        let canvas = Self.canvas
        panel.setFrame(NSRect(x: screen.frame.midX - canvas.width / 2, y: screen.frame.maxY - canvas.height,
                              width: canvas.width, height: canvas.height), display: true)
        panel.ignoresMouseEvents = !buttons
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let spring = Motion.adaptive(.spring(duration: 0.46, bounce: 0.24))
        if wasOpen {
            withAnimation(spring) {
                model.phase = phase
                model.compact = compact
                model.label = label
                model.buttons = buttons
                model.extraTitle = extra?.title
            }
        } else {
            DispatchQueue.main.async { withAnimation(spring) { self.model.expanded = true } }
        }
    }

    /// Over the lock screen too, until it folds away or the Mac unlocks.
    func liftOverLockScreen() {
        panel.canBecomeVisibleWithoutLogin = true
        LockScreenLayer.shared?.lift(panel)
    }

    func lowerFromLockScreen() {
        LockScreenLayer.shared?.lower(panel)
    }

    func setProgress(_ value: Double) {
        guard model.phase == .scanning else { return }
        model.progress = value
    }

    func setLabel(_ label: String) {
        guard model.label != label else { return }
        model.label = label
    }

    func matched(label: String, collapseAfter delay: TimeInterval = 0.6) {
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
            model.phase = .matched
            model.progress = 1
            model.label = label
            model.buttons = false
            model.extraTitle = nil
        }
        panel.ignoresMouseEvents = true
        collapse(after: delay)
    }

    func failed(label: String, buttons: Bool = true) {
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            model.phase = .failed
            model.label = label
            model.buttons = buttons
        }
        withAnimation(.linear(duration: 0.45)) { model.shakes += 1 }
        panel.ignoresMouseEvents = !buttons
    }

    /// A short notice, e.g. "Unlocked with your face", then folds away.
    func message(_ label: String, on screen: NSScreen?, for seconds: TimeInterval = 1.8) {
        show(on: screen, label: label, compact: true, phase: .message)
        collapse(after: seconds)
    }

    func collapse(after delay: TimeInterval = 0) {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.generation else { return }
            // Content fades first (its removal transition), then the shape folds back into the notch.
            withAnimation(Motion.adaptive(.spring(duration: 0.38, bounce: 0))) { self.model.expanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard token == self.generation, !self.model.expanded else { return }
                self.lowerFromLockScreen()
                self.panel.orderOut(nil)
                self.model.session = nil
            }
        }
    }

    /// The notch's size from the screen's camera housing, or a slim drop point on screens without one.
    private func measure(_ screen: NSScreen) {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            model.notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            model.hasNotch = true
        } else {
            model.notch = CGSize(width: 150, height: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
            model.hasNotch = false
        }
    }
}
