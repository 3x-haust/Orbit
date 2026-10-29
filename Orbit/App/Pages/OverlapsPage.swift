import AppKit
import SwiftUI

/// Apps and shortcuts that do Orbit's jobs too — quit them, remove them, or settle the shortcut.
struct OverlapsPage: View {
    @Bindable private var overlaps = Overlaps.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Overlapping Apps", subtitle: "Other apps doing Orbit’s jobs fight it for the same keys and icons.") {
                Button { withAnimation(.spring(duration: 0.3)) { overlaps.refresh() } } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }

            if overlaps.count == 0 {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 22)).foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing overlaps").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                        Text("No other app or macOS shortcut is in Orbit’s way.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                }
                .padding(18).card()
            }

            if !overlaps.apps.isEmpty {
                SettingsGroup(title: "Apps", footer: "Removing uses Orbit’s uninstaller, so the app’s leftover files go too. Everything goes to the Trash.") {
                    ForEach(Array(overlaps.apps.enumerated()), id: \.element.id) { i, app in
                        if i > 0 { RowDivider() }
                        AppRow(app: app, quit: { overlaps.quit(app) }, remove: { overlaps.remove(app) })
                    }
                }
                if overlaps.apps.contains(where: \.running) {
                    Button("Quit All Running") { withAnimation { overlaps.quitAll() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
            }

            if !overlaps.shortcuts.isEmpty {
                SettingsGroup(title: "Shortcuts", footer: "Turning a macOS shortcut off changes System Settings › Keyboard › Keyboard Shortcuts; you can turn it back on here.") {
                    ForEach(Array(overlaps.shortcuts.enumerated()), id: \.element.id) { i, clash in
                        if i > 0 { RowDivider() }
                        ShortcutRow(clash: clash) {
                            SystemHotKey.setEnabled(clash.system.id, false)
                            withAnimation { overlaps.refresh() }
                        }
                    }
                }
            }

            if !overlaps.replaced.isEmpty {
                SettingsGroup(title: "macOS shortcuts Orbit replaces", footer: "Orbit does these jobs too. Turn macOS’s off to free the keys, or hand the keys to Orbit.") {
                    ForEach(Array(overlaps.replaced.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { RowDivider() }
                        SettingsRow(title: r.keys + "  " + r.system.title,
                                    subtitle: r.orbit.map { "Orbit: %@".loc($0.title) }, symbol: "command") {
                            HStack(spacing: 8) {
                                if r.orbit != nil {
                                    Button("Use for Orbit") { withAnimation { r.handOver() } }
                                        .buttonStyle(PillButtonStyle(prominent: true))
                                }
                                Button("Turn Off") {
                                    SystemHotKey.setEnabled(r.system.id, false)
                                    withAnimation { overlaps.refresh() }
                                }
                                .buttonStyle(PillButtonStyle(prominent: false))
                            }
                        }
                    }
                }
                if overlaps.replaced.count > 1 {
                    Button("Turn Off All in macOS") { withAnimation { overlaps.turnOffAllReplaced() } }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            let restorable = Pref.defaults.array(forKey: Pref.disabledSystemShortcuts) as? [Int] ?? []
            if !restorable.isEmpty {
                SettingsGroup(title: "macOS shortcuts Orbit turned off") {
                    ForEach(Array(restorable.enumerated()), id: \.element) { i, id in
                        if i > 0 { RowDivider() }
                        SettingsRow(title: SystemHotKey(id: id, keyCode: 0, modifiers: 0).title, symbol: "keyboard") {
                            Button("Turn Back On") {
                                SystemHotKey.setEnabled(id, true)
                                withAnimation { overlaps.refresh() }
                            }
                            .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                }
            }
        }
        .onAppear { overlaps.refresh() }
        .animation(.spring(duration: 0.3), value: overlaps.apps.map(\.running))
    }
}

private struct AppRow: View {
    let app: Overlaps.FoundApp
    let quit: () -> Void
    let remove: () -> Void

    var body: some View {
        SettingsRow(title: app.known.name, subtitle: subtitle, icon: NSWorkspace.shared.icon(forFile: app.url.path)) {
            HStack(spacing: 8) {
                if app.running {
                    Text("Running").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Palette.accent.opacity(0.14)))
                    Button("Quit", action: quit).buttonStyle(PillButtonStyle(prominent: false))
                }
                Button("Remove…", action: remove).buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    private var subtitle: String {
        let job = "Orbit’s %@ does this".loc(app.known.replacedBy.title)
        guard let clash = app.known.clash else { return job }
        return job + " · " + "Clashes: %@".loc(clash)
    }
}

private struct ShortcutRow: View {
    let clash: ShortcutClash
    let turnOffSystem: () -> Void

    var body: some View {
        SettingsRow(title: clash.keys + "  " + clash.orbitTitle,
                    subtitle: "Also macOS: %@".loc(clash.system.title), symbol: "exclamationmark.triangle") {
            HStack(spacing: 8) {
                Button("Turn Off in macOS", action: turnOffSystem).buttonStyle(PillButtonStyle(prominent: true))
                Button("Change Orbit’s") { MainWindow.show(.shortcuts) }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }
}
