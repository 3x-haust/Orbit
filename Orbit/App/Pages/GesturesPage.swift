import SwiftUI
import UniformTypeIdentifiers

struct GesturesPage: View {
    @Bindable private var gestures = Gestures.shared
    private var permissions: Permissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Gestures", subtitle: "Trackpad gestures, mouse buttons and keys that run anything — in every app or only the ones you pick.") {
                Toggle("", isOn: $gestures.enabled.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
            }

            if !permissions.accessibility {
                GestureNotice(symbol: "lock.shield", title: "Mouse buttons and keys need Accessibility",
                              detail: "Trackpad gestures work without it.", action: ("Allow…", { permissions.requestAccessibility() }))
            }

            TrackpadStage(gestures: gestures)

            let overlaps = gestures.rules.compactMap { rule -> (TrackpadGesture, String)? in
                guard rule.enabled, case .trackpad(let g) = rule.trigger, let system = Gestures.systemOverlap(g) else { return nil }
                return (g, system)
            }
            if !overlaps.isEmpty {
                OverlapBanner(overlaps: overlaps)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ForEach(GestureTrigger.Kind.allCases, id: \.self) { kind in
                RuleGroup(kind: kind, gestures: gestures)
            }

            SettingsGroup(footer: "Rules for one app win over rules for every app. Mouse buttons and keys are only taken from the app when a rule uses them.") {
                SettingsRow(title: "Show what ran", subtitle: "A short note each time a gesture runs something.", symbol: "text.bubble") {
                    Toggle("", isOn: $gestures.showWhatRan).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Recommended set", subtitle: "TipTap for tabs, a three-finger tap for middle click, side buttons for back and forward, and more — added switched off.", symbol: "sparkles") {
                    Button("Add") { withAnimation(.spring(duration: 0.35)) { gestures.addRecommended() } }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .animation(.spring(duration: 0.35), value: gestures.rules)
        .onAppear { gestures.metering = true }
        .onDisappear {
            gestures.metering = false
            gestures.record(nil)
        }
    }
}

// MARK: - Live trackpad

/// The trackpad from above: your fingers as dots, and what was recognized.
private struct TrackpadStage: View {
    let gestures: Gestures

    var body: some View {
        let recording = gestures.recording == .trackpad
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let recent = gestures.last.flatMap { context.date.timeIntervalSince($0.at) < 1.6 ? $0 : nil }
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                VStack(spacing: 16) {
                    pad(lit: recent != nil, recording: recording)
                    caption(recent: recent, recording: recording)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .frame(height: 290)
        .environment(\.colorScheme, .dark)
    }

    private func pad(lit: Bool, recording: Bool) -> some View {
        let size = CGSize(width: 300, height: 188)
        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.2))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(lit || recording ? Palette.accent : .white.opacity(0.1), lineWidth: lit || recording ? 2 : 1))
                .shadow(color: lit ? Palette.accent.opacity(0.35) : .black.opacity(0.4), radius: lit ? 18 : 14, y: lit ? 0 : 8)
            if recording {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(0.5), lineWidth: 6)
                    .phaseAnimator([0.2, 0.9]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.8) }
            }
            if let g = gestures.last?.trigger, lit, case .trackpad(let gesture) = g, let d = gesture.direction, !gesture.isTipTap {
                Image(systemName: Self.arrow(d)).font(.system(size: 44, weight: .semibold)).foregroundStyle(Palette.accent.opacity(0.35))
                    .transition(.scale.combined(with: .opacity))
            }
            ForEach(Array(gestures.fingers.enumerated()), id: \.offset) { _, p in
                Circle()
                    .fill(.white)
                    .frame(width: 26, height: 26)
                    .shadow(color: (lit ? Palette.accent : .white).opacity(0.6), radius: 8)
                    .position(x: p.x * size.width, y: (1 - p.y) * size.height)
            }
            if !gestures.trackpadAvailable {
                Image(systemName: "rectangle.slash").font(.system(size: 30)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.08), value: gestures.fingers)
        .animation(.spring(duration: 0.3), value: lit)
    }

    private func caption(recent: (trigger: GestureTrigger, ran: GestureAction?, at: Date)?, recording: Bool) -> some View {
        let text: String
        if !gestures.trackpadAvailable {
            text = "This Mac’s trackpad can’t be read, so only mouse buttons and keys work.".loc
        } else if recording {
            text = "Do the gesture now".loc
        } else if let recent {
            if let ran = recent.ran { text = "%@ → %@".loc(recent.trigger.title, ran.title) }
            else { text = "%@ — nothing set for it".loc(recent.trigger.title) }
        } else {
            text = "Put three fingers on the trackpad to try it".loc
        }
        return Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .contentTransition(.opacity)
            .animation(.spring(duration: 0.3), value: text)
    }

    static func arrow(_ d: TrackpadGesture.Direction) -> String {
        switch d {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        }
    }
}

// MARK: - Rules

private struct RuleGroup: View {
    let kind: GestureTrigger.Kind
    let gestures: Gestures

    private var title: String {
        switch kind {
        case .trackpad: "Trackpad"
        case .mouse: "Mouse"
        case .keyboard: "Keyboard"
        }
    }

    var body: some View {
        let rules = gestures.rules.filter { $0.trigger.kind == kind }
        SettingsGroup(title: title) {
            ForEach(rules) { rule in
                RuleRow(rule: rule, gestures: gestures)
                RowDivider()
            }
            AddRow(kind: kind, gestures: gestures, empty: rules.isEmpty)
        }
    }
}

private struct AddRow: View {
    let kind: GestureTrigger.Kind
    let gestures: Gestures
    let empty: Bool

    var body: some View {
        let recording = gestures.recording == kind
        HStack(spacing: Space.related) {
            Image(systemName: recording ? "record.circle" : "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(recording ? Palette.accent : Palette.ink)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(recording ? Palette.accent.opacity(0.14) : Palette.raised))
                .symbolEffect(.pulse, isActive: recording)
            VStack(alignment: .leading, spacing: 2) {
                Text(recording ? recordingTitle.loc : addTitle.loc).font(.orbitBody).foregroundStyle(Palette.ink)
                Text(hint.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.standard)
            if kind == .trackpad, !recording {
                Menu {
                    ForEach(TrackpadGesture.allCases, id: \.self) { g in
                        Button(GestureTrigger.title(g)) { withAnimation(.spring(duration: 0.35)) { gestures.add(GestureRule(trigger: .trackpad(g))) } }
                    }
                } label: {
                    Text("Choose".loc)
                }
                .menuStyle(.button)
                .buttonStyle(PillButtonStyle(prominent: false))
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Button(recording ? "Cancel" : "Try It") { gestures.record(recording ? nil : kind) }
                .buttonStyle(PillButtonStyle(prominent: !recording && empty))
                .disabled(kind == .trackpad && !gestures.trackpadAvailable)
        }
        .padding(.horizontal, Space.standard)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
        .animation(.spring(duration: 0.3), value: recording)
    }

    private var addTitle: String {
        switch kind {
        case .trackpad: "Add a trackpad gesture"
        case .mouse: "Add a mouse button"
        case .keyboard: "Add keys"
        }
    }

    private var recordingTitle: String {
        switch kind {
        case .trackpad: "Do the gesture on the trackpad…"
        case .mouse: "Press a mouse button…"
        case .keyboard: "Press the keys…"
        }
    }

    private var hint: String {
        switch kind {
        case .trackpad: "Taps with three to five fingers, swipes with three or four, or TipTap: rest one finger and tap beside it."
        case .mouse: "The fourth button and up, alone or with ⌃⌥⇧⌘. The middle button opens the Ring."
        case .keyboard: "A combo with ⌃, ⌥ or ⌘ (or an F-key), or double-tap a modifier like ⌘⌘. esc cancels."
        }
    }
}

private struct RuleRow: View {
    let rule: GestureRule
    let gestures: Gestures
    @State private var hovering = false

    var body: some View {
        let isNew = gestures.recorded == rule.id
        let firedNow = gestures.last.map { $0.trigger == rule.trigger && $0.ran == rule.action && Date().timeIntervalSince($0.at) < 1.5 } ?? false
        HStack(spacing: Space.related) {
            TriggerGlyph(trigger: rule.trigger, lit: firedNow)
            VStack(alignment: .leading, spacing: 3) {
                TriggerTitle(trigger: rule.trigger)
                Text(subtitle).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(rule.enabled ? 1 : 0.55)
            Spacer(minLength: Space.compact)
            if hovering {
                Button { withAnimation(.spring(duration: 0.3)) { gestures.remove(rule.id) } } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary)
                .help("Delete".loc)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
            AppScopeMenu(rule: rule, gestures: gestures)
            GestureActionMenu(rule: rule, gestures: gestures)
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                var r = rule
                r.enabled = on
                withAnimation(.spring(duration: 0.3)) { gestures.update(r) }
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, Space.standard)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(isNew ? Palette.accent.opacity(0.08) : Palette.ink.opacity(hovering ? 0.025 : 0))
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu {
            Button("Delete", role: .destructive) { gestures.remove(rule.id) }
        }
    }

    private var subtitle: String {
        let scope = rule.apps.isEmpty ? "All apps".loc : rule.apps.map(GestureAction.appName).joined(separator: ", ")
        if rule.action == .none { return "Pick what it does".loc }
        return scope
    }
}

/// A tile for the trigger: a small pad with the fingers and the direction, a mouse, or a key.
private struct TriggerGlyph: View {
    let trigger: GestureTrigger
    var lit = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(lit ? Palette.accent.opacity(0.18) : Palette.raised)
            content.foregroundStyle(lit ? Palette.accent : Palette.ink)
        }
        .frame(width: 34, height: 28)
        .animation(.spring(duration: 0.3), value: lit)
    }

    @ViewBuilder private var content: some View {
        switch trigger {
        case .trackpad(let g):
            if g.isTipTap {
                HStack(spacing: 3) {
                    if g == .tipTapLeft { Circle().strokeBorder(lineWidth: 1.2).frame(width: 6, height: 6) }
                    Circle().frame(width: 6, height: 6)
                    if g == .tipTapRight { Circle().strokeBorder(lineWidth: 1.2).frame(width: 6, height: 6) }
                }
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 2) { ForEach(0..<g.fingers, id: \.self) { _ in Circle().frame(width: 4, height: 4) } }
                    if let d = g.direction {
                        Image(systemName: TrackpadStage.arrow(d)).font(.system(size: 8, weight: .bold))
                    } else {
                        Image(systemName: "hand.tap.fill").font(.system(size: 7, weight: .bold))
                    }
                }
            }
        case .mouse(let button, _):
            HStack(spacing: 1) {
                Image(systemName: "computermouse").font(.system(size: 11, weight: .medium))
                Text("\(button + 1)").font(.system(size: 9, weight: .bold, design: .rounded))
            }
        case .keys, .doubleTap:
            Image(systemName: "keyboard").font(.system(size: 12, weight: .medium))
        }
    }
}

private struct TriggerTitle: View {
    let trigger: GestureTrigger

    var body: some View {
        switch trigger {
        case .trackpad, .mouse:
            Text(trigger.title).font(.orbitBody).foregroundStyle(Palette.ink)
        case .keys(let c):
            ShortcutKeys(text: c.label)
        case .doubleTap(let m):
            HStack(spacing: 6) {
                ShortcutKeys(text: m.symbol)
                ShortcutKeys(text: m.symbol)
                Text("twice".loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
        }
    }
}

// MARK: - App scope

private struct AppScopeMenu: View {
    let rule: GestureRule
    let gestures: Gestures

    var body: some View {
        Menu {
            Button { set([]) } label: {
                if rule.apps.isEmpty { Label("All apps".loc, systemImage: "checkmark") } else { Text("All apps".loc) }
            }
            if !rule.apps.isEmpty {
                Section("Only in".loc) {
                    ForEach(rule.apps, id: \.self) { id in
                        Button { set(rule.apps.filter { $0 != id }) } label: { Label(GestureAction.appName(id), systemImage: "checkmark") }
                    }
                }
            }
            Section("Open apps".loc) {
                ForEach(Self.running().filter { !rule.apps.contains($0.id) }, id: \.id) { app in
                    Button(app.name) { set(rule.apps + [app.id]) }
                }
            }
            Divider()
            Button("Choose App…".loc) {
                if let id = Self.chooseApp(), !rule.apps.contains(id) { set(rule.apps + [id]) }
            }
        } label: {
            HStack(spacing: -6) {
                if rule.apps.isEmpty {
                    Image(systemName: "square.grid.2x2").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 18, height: 18)
                } else {
                    ForEach(rule.apps.prefix(3), id: \.self) { id in
                        if let icon = Self.icon(id) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                    }
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Capsule().fill(Palette.raised))
            .contentShape(Capsule())
            .help(rule.apps.isEmpty ? "All apps".loc : rule.apps.map(GestureAction.appName).joined(separator: ", "))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func set(_ apps: [String]) {
        var r = rule
        r.apps = apps
        withAnimation(.spring(duration: 0.3)) { gestures.update(r) }
    }

    private static func running() -> [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private static func icon(_ id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

// MARK: - Action

/// What a rule runs: the hot corner choices, browser presets, and custom ones that ask for details.
private struct GestureActionMenu: View {
    let rule: GestureRule
    let gestures: Gestures
    @State private var editing: Editor?
    @State private var shortcuts: [String] = []

    enum Editor: Identifiable {
        case keys, open, shell, appleScript
        var id: Self { self }
    }

    private static let groups = ["Media", "Capture", "Clipboard", "Window", "System", "Orbit"]

    var body: some View {
        Menu {
            Button { set(.none) } label: { Label("Nothing".loc, systemImage: "minus") }
            Button { set(.target(HotCorners.Target.ring.raw)) } label: { Label("Orbit Ring".loc, systemImage: "circle.dashed") }
            Section("Browser & tabs".loc) {
                ForEach(GestureAction.Preset.allCases, id: \.self) { p in
                    Button { set(.preset(p)) } label: { Label(p.title.loc, systemImage: p.symbol) }
                }
            }
            Section("macOS".loc) {
                ForEach(HotCorners.System.allCases, id: \.self) { s in
                    Button { set(.target(HotCorners.Target.system(s).raw)) } label: { Label(s.title.loc, systemImage: s.symbol) }
                }
            }
            Section("Orbit".loc) {
                ForEach(Self.groups, id: \.self) { g in
                    Menu(g.loc) {
                        ForEach(OrbitAction.allCases.filter { $0.group == g }, id: \.self) { a in
                            Button { set(.target(HotCorners.Target.command(a).raw)) } label: { Label(a.title, systemImage: a.symbol) }
                        }
                    }
                }
            }
            Section("Your own".loc) {
                Button { editing = .keys } label: { Label("Keyboard Shortcut…".loc, systemImage: "keyboard") }
                Button { if let id = AppScopeMenu.chooseApp() { set(.openApp(id)) } } label: { Label("Open App…".loc, systemImage: "app") }
                Button { editing = .open } label: { Label("Open Link or File…".loc, systemImage: "link") }
                Menu {
                    if shortcuts.isEmpty { Text("No shortcuts found".loc) }
                    ForEach(shortcuts, id: \.self) { name in Button(name) { set(.shortcut(name)) } }
                } label: { Label("Run Shortcut".loc, systemImage: "square.2.layers.3d") }
                Button { editing = .shell } label: { Label("Shell Script…".loc, systemImage: "terminal") }
                Button { editing = .appleScript } label: { Label("AppleScript…".loc, systemImage: "applescript") }
                Button { set(.middleClick) } label: { Label("Middle Click".loc, systemImage: "computermouse") }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: rule.action.symbol).font(.system(size: 11, weight: .semibold))
                Text(rule.action.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.5)
            }
            .foregroundStyle(rule.action == .none ? Palette.accent : Palette.ink)
            .padding(.horizontal, 12).frame(height: 28)
            .frame(maxWidth: 220)
            .background(Capsule().fill(Palette.raised))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .task { shortcuts = await ShortcutsLibrary.names() }
        .popover(item: $editing, arrowEdge: .bottom) { editor in
            ActionEditor(editor: editor, action: rule.action) { action in
                if let action { set(action) }
                editing = nil
            }
        }
    }

    private func set(_ action: GestureAction) {
        var r = rule
        r.action = action
        withAnimation(.spring(duration: 0.3)) { gestures.update(r) }
    }
}

/// The details a custom action needs: keys to press, a link or file, a script.
private struct ActionEditor: View {
    let editor: GestureActionMenu.Editor
    let action: GestureAction
    let done: (GestureAction?) -> Void
    @State private var text = ""
    @State private var combo: KeyCombo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.loc).font(.orbitSection).foregroundStyle(Palette.ink)
            switch editor {
            case .keys:
                KeyCaptureField(combo: $combo)
                Text("The keys are sent to the app in front, as if you pressed them.".loc)
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            case .open:
                HStack {
                    TextField("", text: $text, prompt: Text("https://… or ~/Documents/…"))
                        .textFieldStyle(.plain).font(.orbitBody)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { text = (url.path as NSString).abbreviatingWithTildeInPath }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
            case .shell, .appleScript:
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(width: 380, height: 150)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                Text(editor == .shell ? "Runs with zsh in the background. Its output isn’t shown." .loc : "Runs in the background. macOS may ask once to let Orbit control the app.".loc)
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Save") { done(result) }.buttonStyle(PillButtonStyle()).disabled(result == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            switch action {
            case .open(let s), .shell(let s), .appleScript(let s): text = s
            case .keys(let c): combo = c
            default: break
            }
        }
    }

    private var title: String {
        switch editor {
        case .keys: "Keyboard Shortcut"
        case .open: "Open Link or File"
        case .shell: "Shell Script"
        case .appleScript: "AppleScript"
        }
    }

    private var result: GestureAction? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch editor {
        case .keys: return combo.map { .keys($0) }
        case .open: return t.isEmpty ? nil : .open(t)
        case .shell: return t.isEmpty ? nil : .shell(text)
        case .appleScript: return t.isEmpty ? nil : .appleScript(text)
        }
    }
}

/// Click, then press the keys to send. Any key with or without modifiers; esc alone cancels.
private struct KeyCaptureField: View {
    @Binding var combo: KeyCombo?
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button { listening ? stop() : start() } label: {
            HStack(spacing: 6) {
                if listening {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                        .phaseAnimator([0.35, 1]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.6) }
                    Text("Press keys…".loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                } else if let combo {
                    ShortcutKeys(text: combo.label)
                } else {
                    Text("Click to record".loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 12).frame(minWidth: 140, minHeight: 32)
            .background(Capsule().fill(listening ? Palette.accent.opacity(0.1) : Palette.raised))
            .overlay(Capsule().strokeBorder(listening ? Palette.accent : .clear, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags.isEmpty, event.keyCode == 53 { stop(); return nil }
            var mods: KeyMods = []
            if flags.contains(.control) { mods.insert(.control) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.command) { mods.insert(.command) }
            combo = KeyCombo(keyCode: event.keyCode, mods: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
    }
}

// MARK: - Notices

private struct OverlapBanner: View {
    let overlaps: [(TrackpadGesture, String)]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fingers.spread").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).background(Circle().fill(Palette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS uses some of these gestures too".loc).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                ForEach(overlaps, id: \.0) { g, system in
                    Text("%@ also does %@. Both will happen.".loc(GestureTrigger.title(g), system.loc))
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Trackpad Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
            }
            .buttonStyle(PillButtonStyle(prominent: false))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

private struct GestureNotice: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).background(Circle().fill(Palette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                Text(detail.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.0.loc, action: action.1).buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
