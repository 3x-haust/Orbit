import AppKit
import SwiftUI

/// Every screen's brightness (and a monitor's volume) in one small panel, under the menu bar.
@MainActor
final class DisplaysPanel {
    static let shared = DisplaysPanel()

    private var panel: FloatingPanel?
    private let width: CGFloat = 340

    private init() {}

    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        let manager = DisplayManager.shared
        manager.refresh()
        let panel = self.panel ?? make()
        let screen = NSScreen.active
        let rows = max(manager.displays.count, 1)
        let height = CGFloat(96 + rows * 92 + (manager.displays.contains(where: \.hasVolume) ? 44 : 0))
        let frame = NSRect(x: screen.visibleFrame.maxX - width - 10, y: screen.visibleFrame.maxY - height - 6, width: width, height: height)
        panel.present(at: frame)
    }

    func hide() { panel?.dismiss() }

    private func make() -> FloatingPanel {
        let p = FloatingPanel(contentRect: .zero, focusable: true)
        p.onResignKey = { [weak self] in self?.hide() }
        p.setContent(QuickDisplaysView { [weak self] in self?.hide() })
        panel = p
        return p
    }
}

private struct QuickDisplaysView: View {
    @Bindable private var manager = DisplayManager.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack {
                Text("Displays".loc).font(.orbitSection).foregroundStyle(Palette.ink)
                Spacer()
                Button { close(); MainWindow.show(.displays) } label: {
                    Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                }
                .buttonStyle(.plain)
                .hoverHint("Displays settings".loc)
            }
            ForEach(manager.displays) { d in
                DisplayQuickRow(display: d)
            }
            if manager.displays.isEmpty {
                Text("No screens found.".loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            BrightnessPresetChips()
        }
        .padding(Space.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).fill(Palette.canvas.opacity(0.92)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
    }
}

/// Name, method, and the brightness slider (plus volume when the monitor has speakers).
struct DisplayQuickRow: View {
    let display: ManagedDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: Space.compact) {
            HStack(spacing: Space.compact) {
                Image(systemName: display.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                Text(display.name).font(.orbitBodyEmphasized).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer()
                Text(display.kind.label.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
            }
            LevelSlider(symbolLow: "sun.min", symbolHigh: "sun.max.fill",
                        value: Binding(get: { display.brightness }, set: { DisplayManager.shared.setBrightnessShowingHUD(display, $0) }))
                .disabled(!display.enabled)
            if display.hasVolume {
                LevelSlider(symbolLow: display.muted ? "speaker.slash.fill" : "speaker.fill", symbolHigh: "speaker.wave.3.fill",
                            value: Binding(get: { display.muted ? 0 : display.volume }, set: { DisplayManager.shared.setVolume(display, $0) }),
                            onLowTap: { DisplayManager.shared.setMuted(display, !display.muted) })
                    .disabled(!display.enabled)
            }
        }
    }
}

/// An icon on each end and the percentage; tapping the low icon can mute.
struct LevelSlider: View {
    let symbolLow: String
    let symbolHigh: String
    @Binding var value: Double
    var onLowTap: (() -> Void)?

    var body: some View {
        HStack(spacing: Space.compact) {
            Button { onLowTap?() } label: {
                Image(systemName: symbolLow).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary).frame(width: 16)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(onLowTap != nil)
            Slider(value: $value, in: 0...1)
                .tint(Palette.accent)
            Image(systemName: symbolHigh).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary).frame(width: 16)
            Text("\(Int((value * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// One tap for a level on every screen: the fixed few, then the user's own.
struct BrightnessPresetChips: View {
    @Bindable private var manager = DisplayManager.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.tight) {
                Chip(title: "Bright", symbol: "sun.max.fill", isOn: false) { manager.setAll(1) }
                Chip(title: "Comfort", symbol: "sun.haze", isOn: false) { manager.setAll(0.6) }
                Chip(title: "Dim", symbol: "moon", isOn: false) { manager.setAll(0.2) }
                ForEach(manager.presets) { p in
                    Chip(title: p.name, symbol: "bookmark", isOn: false) { manager.applyPreset(p) }
                        .contextMenu { Button("Delete Preset", role: .destructive) { manager.removePreset(p) } }
                }
            }
        }
    }
}
