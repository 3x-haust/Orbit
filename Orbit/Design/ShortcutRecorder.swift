import AppKit
import KeyboardShortcuts
import SwiftUI

/// Orbit's shortcut field. At rest it shows the keys as keycaps; click it and it listens — no text
/// caret — showing the modifiers as you hold them. Esc cancels, ⌫ clears, a click elsewhere cancels.
/// While it listens every Orbit hotkey is off, so pressing one records it instead of running it.
/// Keys another Orbit action uses move over here; keys macOS itself uses are refused with a note.
struct ShortcutRecorder: View {
    let name: KeyboardShortcuts.Name
    var compact = false

    @State private var shortcut: KeyboardShortcuts.Shortcut?
    @State private var listening = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var hovering = false
    @State private var note: String?
    @State private var shake = 0
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) { label }
                .buttonStyle(.plain)
                .modifier(Shake(amount: CGFloat(shake)))
                .animation(.spring(duration: 0.35, bounce: 0.3), value: shake)
            if shortcut != nil, hovering || listening {
                Button { set(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 18, height: 18).background(Circle().fill(Palette.raised))
                }
                .buttonStyle(.plain)
                .help("Clear shortcut".loc)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .animation(.spring(duration: 0.25), value: listening)
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: name) }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutRecorder.changed)) { _ in
            shortcut = KeyboardShortcuts.getShortcut(for: name)
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutRecorder.began)) { note in
            // Only one field listens at a time.
            if listening, (note.object as? String) != name.rawValue { stop() }
        }
        .popover(isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } }), arrowEdge: .bottom) {
            Text(note ?? "").font(.system(size: 11)).foregroundStyle(Palette.ink).padding(10).frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var label: some View {
        let height: CGFloat = compact ? 24 : 28
        HStack(spacing: 4) {
            if listening {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                    .phaseAnimator([0.35, 1]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.6) }
                if held.isEmpty {
                    Text("Press keys…".loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                } else {
                    ShortcutKeys(text: Self.symbols(held))
                }
                Text("esc").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 4).frame(height: 14)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            } else if let shortcut {
                ShortcutKeys(text: shortcut.description)
            } else {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                Text("Set shortcut".loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, shortcut != nil && !listening ? 4 : 10)
        .frame(minWidth: compact ? 70 : 92, minHeight: height)
        .background(Capsule().fill(listening ? Palette.accent.opacity(0.1) : (hovering ? Palette.raised : Palette.raised.opacity(shortcut == nil ? 1 : 0))))
        .overlay(Capsule().strokeBorder(listening ? Palette.accent : .clear, lineWidth: 1.5))
        .contentShape(Capsule())
        .help(listening ? "Press the keys · esc cancels · ⌫ clears".loc : "Click to change".loc)
    }

    // MARK: Listening

    private func toggle() { listening ? stop() : start() }

    private func start() {
        NotificationCenter.default.post(name: Self.began, object: name.rawValue)
        note = nil
        held = []
        listening = true
        KeyboardShortcuts.isEnabled = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { event in
            handle(event)
        }
    }

    private func stop() {
        guard listening || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        held = []
        KeyboardShortcuts.isEnabled = true
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.type {
        case .flagsChanged:
            withAnimation(.spring(duration: 0.2)) { held = mods }
            return nil
        case .leftMouseDown, .rightMouseDown:
            // A click on the field itself toggles through its button; anywhere else cancels.
            if !hovering { stop() }
            return event
        case .keyDown:
            if mods.isEmpty, event.keyCode == 53 { stop(); return nil }                    // esc
            if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117 { set(nil); stop(); return nil } // ⌫ ⌦
            guard let s = KeyboardShortcuts.Shortcut(event: event) else { reject(nil); return nil }
            let fKey = (122...127).contains(Int(event.keyCode)) || [96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 118, 120].contains(Int(event.keyCode))
            // A shortcut needs ⌘, ⌥ or ⌃ (⇧ alone would eat capital letters) — F-keys may go bare.
            guard fKey || !mods.intersection([.command, .option, .control]).isEmpty else {
                reject("Add ⌘, ⌥ or ⌃ to the key.".loc)
                return nil
            }
            if let system = SystemHotKey.enabled().first(where: { $0.shortcut == s }) {
                reject("macOS uses %@ for “%@”. Turn it off under Overlapping Apps, or pick other keys.".loc(s.description, system.title))
                return nil
            }
            set(s)
            stop()
            return nil
        default:
            return event
        }
    }

    private func reject(_ message: String?) {
        shake += 1
        NSSound.beep()
        if let message { note = message }
    }

    private func set(_ s: KeyboardShortcuts.Shortcut?) {
        if let s {
            // Whichever Orbit shortcut had these keys gives them up.
            for other in Self.allNames where other != name && KeyboardShortcuts.getShortcut(for: other) == s {
                KeyboardShortcuts.setShortcut(nil, for: other)
                Toast.show("Moved from another action".loc, symbol: "keyboard", detail: s.description)
            }
        }
        KeyboardShortcuts.setShortcut(s, for: name)
        shortcut = s
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    static let changed = Notification.Name("orbit.shortcutRecorder.changed")
    static let began = Notification.Name("orbit.shortcutRecorder.began")

    @MainActor static var allNames: [KeyboardShortcuts.Name] {
        [.ring] + OrbitAction.allCases.compactMap(\.shortcutName)
    }

    private static func symbols(_ m: NSEvent.ModifierFlags) -> String {
        (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 4), y: 0))
    }
}
