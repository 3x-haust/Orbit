import AppKit

/// macOS's own menu bar icons, switched off where System Settings › Menu Bar keeps them, so hiding
/// takes them away as completely as an app's icon:
/// - Control Center's (Wi-Fi, Sound, Battery, Bluetooth, Focus…): its per-module setting
///   (`com.apple.controlcenter`, this Mac only; bit 2 shows the icon, bit 8 hides it)
/// - Siri: `com.apple.Siri` `StatusMenuVisible`; VPN and other classic menu extras: their entry in
///   SystemUIServer's `menuExtras` (SystemUIServer restarts to pick either up)
/// - Spotlight: Control Center's `showSpotlight` flag in its group container
/// - the input menu: `com.apple.TextInputMenu` `visible`
/// Control Center and the input menu pick changes up at once. The value from before Orbit's first
/// change is kept to put back exactly.
@MainActor
enum MenuBarSystemSwitches {
    enum Switch: Hashable {
        case module(String)
        case flag(String)
        case textInput
        case siri
        /// A SystemUIServer menu extra, by its bundle's path.
        case menuExtra(String)

        var key: String {
            switch self {
            case .module(let m): "module:\(m)"
            case .flag(let f): "flag:\(f)"
            case .textInput: "textInput"
            case .siri: "siri"
            case .menuExtra(let path): "extra:\(path)"
            }
        }

        init?(key: String) {
            if key == "textInput" { self = .textInput; return }
            if key == "siri" { self = .siri; return }
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            switch parts[0] {
            case "module": self = .module(parts[1])
            case "flag": self = .flag(parts[1])
            case "extra": self = .menuExtra(parts[1])
            default: return nil
            }
        }

        /// SystemUIServer only reads these when it starts.
        var needsRestart: Bool {
            switch self {
            case .siri, .menuExtra: true
            default: false
            }
        }
    }

    /// `com.apple.menuextra.<name>` → Control Center's module.
    private static let modules: [String: String] = [
        "sound": "Sound", "volume": "Sound", "wifi": "WiFi", "battery": "Battery", "bluetooth": "Bluetooth",
        "focusmode": "FocusModes", "focusmodes": "FocusModes", "focus": "FocusModes", "display": "Display",
        "displays": "Display", "nowplaying": "NowPlaying", "airdrop": "AirDrop", "screenmirroring": "ScreenMirroring",
        "stagemanager": "StageManager", "keyboardbrightness": "KeyboardBrightness", "userswitcher": "UserSwitcher",
        "user": "UserSwitcher", "hearing": "Hearing", "accessibilityshortcuts": "AccessibilityShortcuts",
        "musicrecognition": "MusicRecognition", "voicecontrol": "VoiceControl", "timer": "Timer",
    ]

    /// How an icon of macOS's is switched off, or nil for the clock and Control Center itself (macOS
    /// keeps those) and anything Orbit doesn't know.
    static func `switch`(identifier: String?, owner: String, name: String) -> Switch? {
        if owner == "com.apple.TextInputMenuAgent" { return .textInput }
        let short = (identifier ?? "").lowercased().replacingOccurrences(of: "com.apple.menuextra.", with: "")
            .replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        if let module = modules[short] { return .module(module) }
        let label = name.lowercased()
        if short == "siri" || label.contains("siri") { return .siri }
        if short == "spotlight" || owner == "com.apple.Spotlight" { return .flag("showSpotlight") }
        if owner == "com.apple.systemuiserver" {
            // VPN.menu and the like: matched by the menu extra's name.
            let extras = (CFPreferencesCopyAppValue("menuExtras" as CFString, systemUI) as? [String]) ?? []
            let wanted = short.isEmpty ? label : short
            if let path = extras.first(where: { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == wanted
                || label.contains((($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) }) {
                return .menuExtra(path)
            }
        }
        return nil
    }

    // MARK: Reading and writing

    private static let controlCenter = "com.apple.controlcenter" as CFString
    private static let textInput = "com.apple.TextInputMenu" as CFString
    private static let siriDomain = "com.apple.Siri" as CFString
    private static let systemUI = "com.apple.systemuiserver" as CFString

    private static var menuExtras: [String] { (CFPreferencesCopyAppValue("menuExtras" as CFString, systemUI) as? [String]) ?? [] }

    /// The setting as it stands (nil: not set, macOS's default).
    private static func current(_ s: Switch) -> Any? {
        switch s {
        case .module(let m):
            CFPreferencesCopyValue(m as CFString, controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        case .flag(let f):
            MenuBarAgentPrefs.value(f)
        case .textInput:
            CFPreferencesCopyAppValue("visible" as CFString, textInput)
        case .siri:
            CFPreferencesCopyAppValue("StatusMenuVisible" as CFString, siriDomain)
        case .menuExtra(let path):
            menuExtras.contains(path)
        }
    }

    private static func write(_ s: Switch, _ value: Any?) -> Bool {
        let v = value as CFPropertyList?
        switch s {
        case .module(let m):
            CFPreferencesSetValue(m as CFString, v, controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            return CFPreferencesSynchronize(controlCenter, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        case .flag(let f):
            return MenuBarAgentPrefs.setValue(f, value)
        case .textInput:
            CFPreferencesSetAppValue("visible" as CFString, v, textInput)
            return CFPreferencesAppSynchronize(textInput)
        case .siri:
            CFPreferencesSetAppValue("StatusMenuVisible" as CFString, v, siriDomain)
            return CFPreferencesAppSynchronize(siriDomain)
        case .menuExtra(let path):
            var extras = menuExtras.filter { $0 != path }
            if value as? Bool ?? false { extras.append(path) }
            CFPreferencesSetAppValue("menuExtras" as CFString, extras as CFArray, systemUI)
            return CFPreferencesAppSynchronize(systemUI)
        }
    }

    /// SystemUIServer comes straight back (launchd) with the new settings.
    static func restartSystemUI() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemuiserver") {
            kill(app.processIdentifier, SIGTERM)
        }
        MenuBarLog.write("system switch: SystemUIServer restarted")
    }

    /// The value that hides it, given what it was.
    private static func hiddenValue(_ s: Switch, from original: Any?) -> Any {
        switch s {
        case .module:
            let bits = (original as? Int) ?? 2
            return (bits & ~2) | 8
        case .flag, .textInput, .siri, .menuExtra:
            return false
        }
    }

    // MARK: Originals

    private static let originalsKey = "menubar.systemOriginals"
    /// Marks "wasn't set at all" in the stored originals.
    private static let unset = "__unset__"

    private static var originals: [String: Any] {
        get { Pref.defaults.dictionary(forKey: originalsKey) ?? [:] }
        set { Pref.defaults.set(newValue, forKey: originalsKey) }
    }

    static var changed: [Switch] { originals.keys.compactMap(Switch.init(key:)) }

    /// Hides or brings back one icon. Returns whether the setting took.
    @discardableResult
    static func set(_ s: Switch, hidden: Bool, restart: Bool = true) -> Bool {
        let ok = write(s, hidden: hidden)
        if ok, restart, s.needsRestart { restartSystemUI() }
        return ok
    }

    private static func write(_ s: Switch, hidden: Bool) -> Bool {
        var stored = originals
        if hidden {
            if stored[s.key] == nil { stored[s.key] = current(s) ?? unset; originals = stored }
            let original = stored[s.key].flatMap { ($0 as? String) == unset ? nil : $0 }
            let ok = write(s, hiddenValue(s, from: original))
            MenuBarLog.write("system switch: \(s.key) off \(ok ? "ok" : "failed")")
            return ok
        }
        guard let original = stored[s.key] else { return true }
        let ok = write(s, (original as? String) == unset ? nil : original)
        MenuBarLog.write("system switch: \(s.key) back \(ok ? "ok" : "failed")")
        // Back as it was: nothing left to put back.
        if ok { stored[s.key] = nil; originals = stored }
        return ok
    }

    /// Makes the settings match: these hidden, every other one Orbit changed put back as it was.
    static func apply(hidden: Set<Switch>) {
        var restart = false
        for s in hidden where !isHidden(s) {
            if write(s, hidden: true), s.needsRestart { restart = true }
        }
        var stored = originals
        for s in changed where !hidden.contains(s) {
            if write(s, hidden: false) {
                stored[s.key] = nil
                if s.needsRestart { restart = true }
            }
        }
        originals = stored
        if restart { restartSystemUI() }
    }

    /// Already switched off by Orbit (so a reconcile doesn't restart SystemUIServer for nothing).
    private static func isHidden(_ s: Switch) -> Bool {
        guard let stored = originals[s.key] else { return false }
        let original = (stored as? String) == unset ? nil : stored
        let now = current(s)
        let want = hiddenValue(s, from: original)
        if case .menuExtra = s { return (now as? Bool) == false }
        return now.map { ($0 as AnyObject).isEqual(want) } ?? false
    }
}
