import AppKit
import KeyboardShortcuts

/// ⌃⌥⇧⌘ as stored in a rule. Left and right count the same.
struct KeyMods: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8
    static let control = KeyMods(rawValue: 1)
    static let option = KeyMods(rawValue: 2)
    static let shift = KeyMods(rawValue: 4)
    static let command = KeyMods(rawValue: 8)

    init(rawValue: UInt8) { self.rawValue = rawValue }

    init(_ flags: CGEventFlags) {
        var m: KeyMods = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        self = m
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        return f
    }

    var nsFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.control) { f.insert(.control) }
        if contains(.option) { f.insert(.option) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.command) { f.insert(.command) }
        return f
    }

    /// In macOS's order, ⌃⌥⇧⌘.
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key and the modifiers held with it.
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt16
    var mods: KeyMods

    @MainActor var label: String {
        KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: Int(keyCode)), modifiers: mods.nsFlags).label
    }
}

/// What a gesture runs: anything a hot corner can (the Ring, Orbit's actions, macOS's), plus keys,
/// apps, links, Shortcuts and scripts.
enum GestureAction: Codable, Hashable, Sendable {
    case none
    /// A `HotCorners.Target`, by its raw value.
    case target(String)
    case preset(Preset)
    case keys(KeyCombo)
    case openApp(String)
    case open(String)
    case shortcut(String)
    case shell(String)
    case appleScript(String)
    case middleClick

    /// Shortcuts most apps share, ready to pick.
    enum Preset: String, Codable, CaseIterable, Sendable {
        case back, forward, closeTab, newTab, reopenTab, nextTab, previousTab

        var title: String {
            switch self {
            case .back: "Back"
            case .forward: "Forward"
            case .closeTab: "Close Tab"
            case .newTab: "New Tab"
            case .reopenTab: "Reopen Closed Tab"
            case .nextTab: "Next Tab"
            case .previousTab: "Previous Tab"
            }
        }

        var symbol: String {
            switch self {
            case .back: "chevron.backward"
            case .forward: "chevron.forward"
            case .closeTab: "xmark.square"
            case .newTab: "plus.square.on.square"
            case .reopenTab: "arrow.uturn.backward.square"
            case .nextTab: "arrow.right.square"
            case .previousTab: "arrow.left.square"
            }
        }

        var combo: KeyCombo {
            switch self {
            case .back: KeyCombo(keyCode: 33, mods: .command)                 // ⌘[
            case .forward: KeyCombo(keyCode: 30, mods: .command)              // ⌘]
            case .closeTab: KeyCombo(keyCode: 13, mods: .command)             // ⌘W
            case .newTab: KeyCombo(keyCode: 17, mods: .command)               // ⌘T
            case .reopenTab: KeyCombo(keyCode: 17, mods: [.command, .shift])  // ⇧⌘T
            case .nextTab: KeyCombo(keyCode: 48, mods: .control)              // ⌃Tab
            case .previousTab: KeyCombo(keyCode: 48, mods: [.control, .shift]) // ⌃⇧Tab
            }
        }
    }

    @MainActor var title: String {
        switch self {
        case .none: "Nothing".loc
        case .target(let raw): HotCorners.Target(raw).title
        case .preset(let p): p.title.loc
        case .keys(let c): "Press %@".loc(c.label)
        case .openApp(let id): "Open %@".loc(Self.appName(id))
        case .open(let s): "Open %@".loc(Self.short(s))
        case .shortcut(let name): "Run “%@”".loc(name)
        case .shell: "Run Shell Script".loc
        case .appleScript: "Run AppleScript".loc
        case .middleClick: "Middle Click".loc
        }
    }

    var symbol: String {
        switch self {
        case .none: "minus"
        case .target(let raw): HotCorners.Target(raw).symbol
        case .preset(let p): p.symbol
        case .keys: "keyboard"
        case .openApp: "app"
        case .open(let s): s.contains("://") ? "link" : "doc"
        case .shortcut: "square.2.layers.3d"
        case .shell: "terminal"
        case .appleScript: "applescript"
        case .middleClick: "computermouse"
        }
    }

    /// For the log: what kind of action, never a script's text.
    var kind: String {
        switch self {
        case .none: "none"
        case .target(let raw): raw
        case .preset(let p): "preset.\(p.rawValue)"
        case .keys: "keys"
        case .openApp(let id): "app.\(id)"
        case .open(let s): s.contains("://") ? "url" : "file"
        case .shortcut: "shortcut"
        case .shell: "shell"
        case .appleScript: "applescript"
        case .middleClick: "middleClick"
        }
    }

    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func short(_ s: String) -> String {
        if let url = URL(string: s), let host = url.host, s.contains("://") { return host }
        return (s as NSString).lastPathComponent
    }

    // MARK: Running

    /// Marks the keys and clicks Orbit sends, so its own taps let them through.
    static let sentMarker: Int64 = 0x0B18

    @MainActor func run() {
        switch self {
        case .none: break
        case .target(let raw): HotCorners.shared.run(HotCorners.Target(raw))
        case .preset(let p): Self.press(p.combo)
        case .keys(let c): Self.press(c)
        case .openApp(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                Toast.show("App not found", symbol: "questionmark.app")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .open(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("://"), let url = URL(string: trimmed) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
            }
        case .shortcut(let name): Self.launch("/usr/bin/shortcuts", ["run", name], what: "shortcut")
        case .shell(let script): Self.launch("/bin/zsh", ["-lc", script], what: "shell")
        case .appleScript(let script): Self.launch("/usr/bin/osascript", ["-e", script], what: "applescript")
        case .middleClick: Self.middleClick()
        }
    }

    private static func press(_ c: KeyCombo) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: c.keyCode, keyDown: down) else { continue }
            e.flags = c.mods.cgFlags
            e.setIntegerValueField(.eventSourceUserData, value: sentMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    private static func middleClick() {
        let src = CGEventSource(stateID: .hidSystemState)
        let at = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at, mouseButton: .center) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            // The Ring's tap lets its own replayed clicks through; this is one of those.
            e.setIntegerValueField(.eventSourceUserData, value: MouseTrigger.replayMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Runs a tool in the background; the log gets how it ended, not what it said.
    private static func launch(_ tool: String, _ args: [String], what: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            GestureLog.write("\(what) ended with status \(proc.terminationStatus)")
            if proc.terminationStatus != 0 {
                DispatchQueue.main.async { MainActor.assumeIsolated { Toast.show("The gesture’s script failed", symbol: "exclamationmark.triangle") } }
            }
        }
        do { try p.run() } catch {
            GestureLog.write("\(what) couldn't start: \(error.localizedDescription)")
        }
    }
}

/// The user's shortcuts from the Shortcuts app, by name, for the action menu. Asked once a minute at
/// most: every rule's menu wants the list.
enum ShortcutsLibrary {
    @MainActor private static var cache: (names: [String], at: Date)?

    @MainActor static func names() async -> [String] {
        if let cache, Date().timeIntervalSince(cache.at) < 60 { return cache.names }
        let names = await load()
        cache = (names, Date())
        return names
    }

    private static func load() async -> [String] {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["list"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { done.resume(returning: []); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                done.resume(returning: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            }
        }
    }
}
