import AppKit
import SwiftUI

/// Orbit's brightness and volume HUD, on the screen that changed — instead of macOS's.
@MainActor
final class DisplayOSD {
    static let shared = DisplayOSD()

    enum Kind { case brightness, volume, muted, keyboard }

    @MainActor @Observable
    final class Model {
        var kind: Kind = .brightness
        var value: Double = 0
        /// The output device's name, for volume.
        var caption: String?
    }

    private let model = Model()
    private var panel: FloatingPanel?
    private var hideWork: DispatchWorkItem?
    private var shown = false
    /// Bumped on every show, so a fade-out that finishes late doesn't hide a newer HUD.
    private var generation = 0

    private init() {}

    func show(_ kind: Kind, value: Double, caption: String? = nil, on display: CGDirectDisplayID) {
        if NotchCenter.shared.showHUD(kind, value: value, caption: caption, on: display) { return }
        model.kind = kind
        model.caption = caption
        withAnimation(.spring(duration: 0.18, bounce: 0)) { model.value = value }

        let panel = self.panel ?? make()
        let screen = NSScreen.screens.first { $0.displayID == display } ?? NSScreen.active
        let size = CGSize(width: 232, height: caption == nil ? 64 : 80)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + screen.frame.height * 0.14,
                           width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        generation += 1
        // Never made key or main: ordering it in mustn't touch Orbit's window or the app in front.
        if !shown {
            shown = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in self?.fadeOut(token) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func fadeOut(_ token: Int) {
        guard let panel, token == generation else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.generation else { return }
                panel.orderOut(nil)
                self.shown = false
            }
        })
    }

    private func make() -> FloatingPanel {
        let p = FloatingPanel(contentRect: .zero, focusable: false)
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.setContent(OSDView(model: model))
        panel = p
        return p
    }
}

private struct OSDView: View {
    let model: DisplayOSD.Model

    var body: some View {
        VStack(spacing: 6) {
            if let caption = model.caption, !caption.isEmpty {
                Text(caption).font(.orbitMicro.weight(.medium)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            bar
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .orbitGlass(in: RoundedRectangle(cornerRadius: model.caption == nil ? 32 : 26, style: .continuous))
        .padding(6)
        .environment(\.colorScheme, .dark)
    }

    private var bar: some View {
        HStack(spacing: Space.related) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.kind == .muted ? Palette.inkSecondary : Palette.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)
            // Sixteen steps, like the keys.
            HStack(spacing: 2.5) {
                ForEach(0..<16, id: \.self) { i in
                    let filled = Double(i) < (model.value * 16).rounded()
                    Capsule()
                        .fill(filled ? (i == 15 || model.value >= 0.999 ? Palette.accent : Palette.ink) : Palette.ink.opacity(0.14))
                        .frame(width: 7, height: 14)
                }
            }
        }
    }

    private var symbol: String {
        switch model.kind {
        case .brightness: model.value < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .volume: model.value < 0.01 ? "speaker.fill" : model.value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        case .muted: "speaker.slash.fill"
        case .keyboard: model.value < 0.01 ? "light.min" : "light.max"
        }
    }
}
