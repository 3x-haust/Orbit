import KeyboardShortcuts
import SwiftUI

/// A titled card of rows — the building block of every app page.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.compact) {
            if let title {
                Text(title.loc.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.leading, Space.tight)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .overlay { if let title { SearchGlow(id: "group:" + title, radius: 14, inset: 0) } }
            if let footer {
                Text(footer.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).padding(.horizontal, Space.tight)
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var icon: NSImage?
    @ViewBuilder var accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.related) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
            }
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.orbitBody).foregroundStyle(Palette.ink)
                if let subtitle { Text(subtitle.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary) }
            }
            // Wraps onto more lines when the accessory needs the room, never "…".
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.standard)
            accessory
        }
        .padding(.horizontal, Space.standard)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
        .background(Palette.ink.opacity(hovering ? 0.025 : 0))
        .overlay { SearchGlow(id: "row:" + title, radius: 11, inset: 3) }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        // Settings search scrolls here by title.
        .id("row:" + title)
    }
}

/// The orange glow on a row or card that settings search just led to.
private struct SearchGlow: View {
    let id: String
    let radius: CGFloat
    let inset: CGFloat

    var body: some View {
        let on = MainWindow.shared.router.focus.contains(id)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Palette.accent.opacity(on ? 0.10 : 0))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Palette.accent.opacity(on ? 0.85 : 0), lineWidth: 1.5))
            .shadow(color: Palette.accent.opacity(on ? 0.45 : 0), radius: 10)
            .padding(inset)
            .allowsHitTesting(false)
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, Space.standard) }
}

/// Large page header with an optional trailing control.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.loc).font(.system(size: 28, weight: .bold)).foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle.loc).font(.system(size: 14)).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Primary pill button: ink fill, inverted label. The accent stays reserved for state.
struct PillButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 32)
            .foregroundStyle(prominent ? Palette.canvas : Palette.ink)
            .background(Capsule().fill(prominent ? Palette.ink : Palette.raised))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            // A disabled pill is clearly dimmed, so it never looks tappable.
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .animation(.spring(duration: 0.18, bounce: 0.3), value: configuration.isPressed)
    }
}

/// Keycaps for a shortcut string like "⌃⌥Space".
extension KeyboardShortcuts.Shortcut {
    /// What the keys read as. KeyboardShortcuts names the space bar "빈칸" in Korean; macOS and
    /// everyone else say 스페이스.
    @MainActor var label: String {
        guard key == .space else { return description }
        return String(description.prefix { "⌃⌥⇧⌘".contains($0) }) + "Space".loc
    }
}

struct ShortcutKeys: View {
    let text: String?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.split(text ?? "—").enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, k.count > 1 ? 6 : 0)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.raised))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
    }

    static func split(_ s: String) -> [String] {
        let modifiers = Set("⌃⌥⇧⌘")
        var keys: [String] = []
        var rest = ""
        for ch in s {
            if modifiers.contains(ch), rest.isEmpty { keys.append(String(ch)) } else { rest.append(ch) }
        }
        if !rest.isEmpty { keys.append(rest) }
        return keys
    }
}
