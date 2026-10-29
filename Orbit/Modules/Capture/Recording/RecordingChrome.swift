import AppKit
import Observation
import SwiftUI

/// Everything Orbit shows while recording: a red timer in the menu bar, a control pill under the
/// recorded area and a dashed outline around it. None of it is in the video.
@MainActor
final class RecordingChrome {
    /// Windows to keep out of the recording even where Orbit's other windows are kept in.
    private(set) static var windowIDs: Set<CGWindowID> = []

    private var item: NSStatusItem?
    private var pill: FloatingPanel?
    private var outline: NSWindow?
    private var timer: Timer?

    func show(_ target: RecordTarget, mic: Bool) {
        hide()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(stopClicked)
        item.button?.toolTip = "Stop recording".loc
        item.button?.imagePosition = .imageLeading
        item.button?.image = Self.dot
        self.item = item
        updateTitle()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateTitle() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if target.kind == .area { showOutline(around: target.frame) }
        showPill(for: target, mic: mic)
        // A window not on screen yet has no number (-1), and macOS 26's status-item windows report
        // numbers outside CGWindowID's range — converting either with CGWindowID(_:) traps.
        Self.windowIDs = Set([item.button?.window, pill, outline].compactMap { $0.flatMap { CGWindowID(exactly: $0.windowNumber) } })
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        pill?.orderOut(nil)
        pill = nil
        outline?.orderOut(nil)
        outline = nil
        Self.windowIDs = []
    }

    @objc private func stopClicked() { Recorder.shared.stop() }

    private func updateTitle() {
        let elapsed = Recorder.shared.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        item?.button?.attributedTitle = NSAttributedString(string: " " + Self.clock(elapsed), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
        ])
    }

    private func showPill(for target: RecordTarget, mic: Bool) {
        // The pill is 44pt tall; the clear room above it is for the switches' hover labels.
        let size = CGSize(width: mic ? 392 : 358, height: 44 + RecordingControls.hintRoom)
        let visible = target.screen.visibleFrame
        var origin: CGPoint
        if target.kind == .screen {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 28)
        } else {
            // Under the recorded area; inside it along the bottom when there's no room below.
            origin = CGPoint(x: target.frame.midX - size.width / 2, y: target.frame.minY - 44 - 14)
            if origin.y < visible.minY + 6 { origin.y = max(visible.minY + 6, target.frame.minY + 16) }
        }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        let panel = FloatingPanel(contentRect: CGRect(origin: origin, size: size), focusable: true)
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.onEscape = { Recorder.shared.stop(); return true }
        panel.setContent(RecordingControls(recorder: .shared))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        // Shown without taking the keyboard from the app being recorded; clicking it gives it focus (Esc stops).
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        pill = panel
    }

    private func showOutline(around rect: CGRect) {
        let w = NSWindow(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .statusBar
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = DashedOutline()
        w.orderFrontRegardless()
        outline = w
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static let dot: NSImage = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

/// Thin dashed frame just outside the recorded area, white over a dark edge so it reads on anything.
private final class DashedOutline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.stroke(rect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(rect)
    }
}

/// The floating pill: elapsed time, microphone, restart, discard and stop.
private struct RecordingControls: View {
    let recorder: Recorder
    @State private var pulse = false
    static let hintRoom: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.hintRoom).allowsHitTesting(false)
            pill.frame(height: 44)
        }
    }

    private var pill: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text(RecordingChrome.clock(recorder.startedAt.map { Date().timeIntervalSince($0) } ?? 0))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(.leading, 12)
            .frame(minWidth: 78, alignment: .leading)

            Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 20).padding(.horizontal, 2)

            // What goes into the video, switchable while recording. An "off" switch shows slashed in the accent.
            control(recorder.showsCursor ? "cursorarrow" : "cursorarrow.slash",
                    recorder.showsCursor ? "Hide the pointer" : "Show the pointer",
                    tint: recorder.showsCursor ? .white : Palette.accent) { recorder.toggleCursor() }
            control("cursorarrow.click.2", recorder.highlightsClicks ? "Stop highlighting clicks" : "Highlight clicks",
                    tint: recorder.highlightsClicks && recorder.showsCursor ? .white : Palette.accent,
                    off: !recorder.highlightsClicks) { recorder.toggleClicks() }
                .disabled(!recorder.showsCursor)
                .opacity(recorder.showsCursor ? 1 : 0.4)
            control(recorder.systemAudioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    recorder.systemAudioOn ? "Mute app sound" : "Record app sound",
                    tint: recorder.systemAudioOn ? .white : Palette.accent) { recorder.toggleSystemAudio() }
            if recorder.micOn {
                control(recorder.micMuted ? "mic.slash.fill" : "mic.fill", recorder.micMuted ? "Unmute microphone" : "Mute microphone",
                        tint: recorder.micMuted ? Palette.accent : .white) { recorder.toggleMic() }
            }

            Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 20).padding(.horizontal, 2)

            control("arrow.counterclockwise", "Restart") { recorder.restart() }
            control("trash", "Discard") { recorder.discard() }
            Button { recorder.stop() } label: {
                ZStack {
                    Circle().fill(Color.red)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(.white).frame(width: 10, height: 10)
                }
                .frame(width: 30, height: 30)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop recording".loc)
            .padding(.trailing, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.86)))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .clipShape(Capsule(style: .continuous))
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
        .onAppear { pulse = true }
    }

    private func control(_ symbol: String, _ help: String, tint: Color = .white, off: Bool = false, action: @escaping () -> Void) -> some View {
        HoverIcon(symbol: symbol, tint: tint, off: off, action: action)
            .hoverHint(help.loc, below: false)
            .accessibilityLabel(help.loc)
    }
}

private struct HoverIcon: View {
    let symbol: String
    let tint: Color
    /// A switch with no slashed symbol of its own gets a stroke through it.
    var off = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .overlay {
                    if off {
                        Capsule().fill(tint).frame(width: 2, height: 19).rotationEffect(.degrees(-45))
                    }
                }
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }
}

// MARK: - Countdown

/// 3-2-1 over the middle of what's about to be recorded. Esc cancels.
@MainActor
enum Countdown {
    @Observable final class Model { var value = 3 }

    static func run(seconds: Int, over target: RecordTarget) async -> Bool {
        let model = Model()
        model.value = seconds
        let side: CGFloat = 200
        let rect = CGRect(x: target.frame.midX - side / 2, y: target.frame.midY - side / 2, width: side, height: side)
        let panel = FloatingPanel(contentRect: rect, focusable: true)
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        var cancelled = false
        panel.onEscape = { cancelled = true; return true }
        panel.setContent(CountdownView(model: model))
        // Key without activating Orbit, so the app being recorded keeps looking active.
        panel.present(at: rect)
        for n in stride(from: seconds, through: 1, by: -1) {
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.value = n }
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if cancelled { break }
            }
            if cancelled { break }
        }
        panel.orderOut(nil)
        // Let the window server drop the countdown before the first frame is taken.
        try? await Task.sleep(for: .milliseconds(80))
        return !cancelled
    }
}

private struct CountdownView: View {
    let model: Countdown.Model

    var body: some View {
        VStack(spacing: 6) {
            Text("\(model.value)")
                .font(.system(size: 92, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
            Text("Esc to cancel").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(width: 180, height: 180)
        .background(Circle().fill(Color.black.opacity(0.62)))
        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
