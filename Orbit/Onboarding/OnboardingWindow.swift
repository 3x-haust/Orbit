import AppKit
import SwiftUI
import KeyboardShortcuts

@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: OnboardingView(close: { OnboardingWindow.close() }).orbitTint())
            host.sizingOptions = [] // fixed-size window; avoids constraint update loops on page changes
            host.safeAreaRegions = [] // no titlebar safe-area feedback into layout (constraint-loop crash)
            w.contentView = FloatingPanel.container(for: host) // a hosting view as the content view can loop "Update Constraints" and abort
            w.center()
            window = w
        }
        window?.bringToFront()
    }

    static func close() {
        Pref.defaults.set(true, forKey: Pref.onboarded)
        window?.close()
    }
}

private struct OnboardingView: View {
    let close: () -> Void
    @State private var page = 0
    private let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: WelcomePage()
                case 1: OnboardingRingPage()
                case 2: OnboardingShortcutsPage()
                default: PermissionsPage()
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Capsule().fill(i == page ? Palette.ink : Palette.ink.opacity(0.18))
                            .frame(width: i == page ? 18 : 6, height: 6)
                    }
                }
                .animation(Motion.reflow, value: page)
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation(Motion.panelEnter) { page -= 1 } }
                        .controlSize(.large)
                }
                Button(page == pages - 1 ? "Start Using Orbit" : "Continue") {
                    if page == pages - 1 { close() } else { withAnimation(Motion.panelEnter) { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(Space.group)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Palette.canvas.ignoresSafeArea()
        )
        .onAppear { Permissions.shared.watch(true) }
        .onDisappear { Permissions.shared.watch(false) }
    }
}

private struct WelcomePage: View {
    @State private var spin = false

    var body: some View {
        VStack(spacing: Space.standard) {
            Image(nsImage: Brand.logo)
                .resizable()
                .frame(width: 148, height: 148)
                .rotationEffect(.degrees(spin ? 0 : -8))
                .scaleEffect(spin ? 1 : 0.9)
                .animation(.spring(duration: 0.8, bounce: 0.35), value: spin)
            Text("Welcome to Orbit").font(.system(size: 30, weight: .bold))
            Text("Every Mac utility,\nall in one.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: Space.group) {
                feature("viewfinder", "Capture", Tint.capture)
                feature("doc.on.clipboard", "Clipboard", Tint.clipboard)
                feature("command", "Launcher", Tint.launcher)
                feature("rectangle.split.2x1", "Windows", Tint.window)
                feature("text.viewfinder", "Text", Tint.text)
            }
            .padding(.top, Space.compact)
        }
        .onAppear { spin = true }
    }

    private func feature(_ symbol: String, _ title: String, _ tint: Color) -> some View {
        VStack(spacing: 6) {
            IconTile(symbol: symbol, tint: tint, size: 40)
            Text(title.loc).font(.orbitCaption).foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingRingPage: View {
    @State private var highlighted = 0

    var body: some View {
        HStack(spacing: Space.section) {
            DemoRing(highlighted: highlighted)
            VStack(alignment: .leading, spacing: Space.standard) {
                Text("Meet the Ring").font(.system(size: 26, weight: .bold))
                Text("Your tools orbit the pointer. Open the Ring, move toward what you want, and it happens.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                step("1", "Hold %@ or the middle mouse button".loc(KeyboardShortcuts.getShortcut(for: .ring)?.description ?? "⌃⌥Space"))
                step("2", "Move toward an action — flick past it or let go")
                step("3", "Or tap once and rest on an action until it fills")
            }
            .frame(width: 300)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.spring(duration: 0.25, bounce: 0.3)) { highlighted = (highlighted + 1) % 8 }
            }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.compact + 2) {
            Text(n).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Palette.ink))
                .foregroundStyle(Palette.canvas)
            Text(text.loc).font(.orbitBody)
        }
    }
}

private struct DemoRing: View {
    let highlighted: Int
    let slots = OrbitRing.loadSlots()

    var body: some View {
        ZStack {
            Circle().fill(Palette.canvas).frame(width: 250, height: 250)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            ForEach(Array(slots.enumerated()), id: \.offset) { i, a in
                let angle = Double(i) * .pi / 4
                let on = i == highlighted
                Image(systemName: a.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(on ? Palette.accent : Palette.surface))
                    .overlay(Circle().strokeBorder(on ? .clear : Palette.hairline, lineWidth: 1))
                    .foregroundStyle(on ? Color.white : Palette.ink)
                    .scaleEffect(on ? 1.15 : 1)
                    .shadow(color: on ? Palette.accent.opacity(0.45) : .clear, radius: 10)
                    .offset(x: sin(angle) * 88, y: -cos(angle) * 88)
            }
            Circle().fill(Palette.accent).frame(width: 9, height: 9)
                .offset(x: sin(Double(highlighted) * .pi / 4) * 118, y: -cos(Double(highlighted) * .pi / 4) * 118)
            VStack(spacing: 2) {
                Text(slots[highlighted].shortTitle).font(.system(size: 12, weight: .semibold))
                Text(slots[highlighted].groupTitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 76)
            .background(Circle().fill(Palette.surface).overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1)))
        }
        .frame(width: 280, height: 280)
    }
}

private struct OnboardingShortcutsPage: View {
    let rows: [(String, String, KeyboardShortcuts.Name)] = [
        ("command", "Launcher", .launcher),
        ("doc.on.clipboard", "Clipboard history", .clipboard),
        ("viewfinder", "Capture area", .captureArea),
        ("text.viewfinder", "Copy text from screen", .captureText),
        ("rectangle.lefthalf.filled", "Window to left half", .winLeft),
        ("arrow.up.left.and.arrow.down.right", "Maximize window", .winMaximize),
    ]

    var body: some View {
        VStack(spacing: Space.group) {
            VStack(spacing: Space.compact) {
                Text("Keyboard first").font(.system(size: 26, weight: .bold))
                Text("Everything also has a shortcut. Change any of them in Settings.").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Divider().padding(.leading, 48) }
                    HStack(spacing: Space.related) {
                        Image(systemName: row.0).frame(width: 24).foregroundStyle(.secondary)
                        Text(row.1.loc).font(.orbitBody)
                        Spacer()
                        Text(KeyboardShortcuts.getShortcut(for: row.2)?.description ?? "—")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.raised))
                    }
                    .padding(.horizontal, Space.standard)
                    .frame(height: 42)
                }
            }
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Palette.surface))
            .frame(width: 440)
        }
    }
}

private struct PermissionsPage: View {
    var body: some View {
        VStack(spacing: Space.group) {
            VStack(spacing: Space.compact) {
                Text("Your Mac, your rules").font(.system(size: 26, weight: .bold))
                Text("Everything stays on this Mac. Allow only what you’ll use — you can do it later, too.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PermissionList().frame(width: 520)
        }
    }
}
