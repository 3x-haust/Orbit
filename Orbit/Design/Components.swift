import SwiftUI
import AppKit

/// AppKit visual effect material, used for floating shells. Switches to opaque under Reduce Transparency.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The shell used by the launcher and clipboard shelf: material, hairline border, soft shadow.
struct PanelShell: ViewModifier {
    var radius: CGFloat = Radius.panel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                // Nearly opaque canvas over a material: crisp black/white, with just a hint of depth.
                ZStack {
                    if !reduceTransparency { VisualEffect(material: .popover) }
                    Palette.canvas.opacity(reduceTransparency ? 1 : 0.92)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: scheme == .dark ? 1 : 0.5)
            }
    }
}

extension View {
    func panelShell(radius: CGFloat = Radius.panel) -> some View { modifier(PanelShell(radius: radius)) }
}

/// A single keycap glyph, e.g. ⌘ or K.
struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: Radius.keycap, style: .continuous)
                    .fill(Palette.raised)
            )
    }
}

/// "Paste ↩"-style footer hint.
struct ShortcutHint: View {
    let title: String
    let keys: [String]
    var emphasized = false

    var body: some View {
        HStack(spacing: Space.tight + 2) {
            Text(title.loc)
                .font(emphasized ? .orbitBodyEmphasized : .orbitCaption)
                .foregroundStyle(emphasized ? .primary : .secondary)
            HStack(spacing: Space.micro) {
                ForEach(keys, id: \.self) { KeyCap(label: $0) }
            }
        }
    }
}

/// Rounded square glyph tile: ink fill with an inverted glyph (black-on-white in dark mode, white-on-black in light).
struct IconTile: View {
    let symbol: String
    var tint: Color = Palette.ink
    var size: CGFloat = 24
    var highlighted = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(highlighted ? Color.white : Palette.canvas)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(highlighted ? Palette.accent : tint)
            )
    }
}

/// Toolbar-style icon button with a 28pt hit target and hover feedback.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = Size.iconTarget
    var isActive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(isActive ? Palette.canvas : Palette.ink)
                .background(
                    RoundedRectangle(cornerRadius: Radius.smallControl, style: .continuous)
                        .fill(isActive ? Palette.ink : Palette.ink.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled() // the active tool is already marked; a blue ring on top reads as a second selection
        .help(help.loc)
        .accessibilityLabel(help)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }
}

/// A quick label that appears next to a control on hover — sooner and easier to read than a system
/// tooltip, which also only shows while the app is frontmost.
struct HoverHint: ViewModifier {
    let text: String
    var below = true
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                if inside {
                    pending = Task {
                        try? await Task.sleep(for: .milliseconds(320))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.14)) { shown = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { shown = false }
                }
            }
            .overlay(alignment: below ? .bottom : .top) {
                if shown, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.88)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                        .fixedSize()
                        .offset(y: below ? 32 : -32)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
    }
}

extension View {
    func hoverHint(_ text: String, below: Bool = true) -> some View { modifier(HoverHint(text: text, below: below)) }
}

/// Filter chip used in clipboard and launcher scopes.
struct Chip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.tight) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title.loc).font(.orbitCaption.weight(isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(isOn ? Palette.canvas : Palette.inkSecondary)
            .background(Capsule().fill(isOn ? Palette.ink : Palette.raised))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

extension Date {
    var orbitRelative: String {
        let s = -timeIntervalSinceNow
        if s < 60 { return "Just now".loc }
        if s < 3600 { return "%ldm ago".loc(Int(s / 60)) }
        if s < 86400 { return "%ldh ago".loc(Int(s / 3600)) }
        if s < 86400 * 7 { return "%ldd ago".loc(Int(s / 86400)) }
        return formatted(date: .abbreviated, time: .omitted)
    }
}
