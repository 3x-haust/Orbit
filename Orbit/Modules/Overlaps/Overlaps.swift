import AppKit
import KeyboardShortcuts

/// Apps and shortcuts that do the same job as Orbit and get in each other's way.
@MainActor @Observable
final class Overlaps {
    static let shared = Overlaps()

    struct KnownApp {
        let bundleID: String
        let name: String
        let replacedBy: Page
        /// Shortcuts or gestures it fights Orbit over, if any.
        var clash: String? = nil
    }

    struct FoundApp: Identifiable {
        let known: KnownApp
        let url: URL
        var running: Bool
        var id: String { known.bundleID }
    }

    /// The tools Orbit replaces, by category. Not Tavi: Orbit's automatic 한/영 is Tavi, and the Tavi
    /// app shares its input method and word list — removing it would take 한/영 away from Orbit too.
    /// Matched by bundle ID first, then by name in the Applications folders (IDs change between versions).
    static let known: [KnownApp] = {
        let menuBar = "Menu bar icons".loc, audio = "App audio".loc
        return [
            // Windows
            .init(bundleID: "com.knollsoft.Rectangle", name: "Rectangle", replacedBy: .windows, clash: "⌃⌥ ← → ↑ ↓ ↩"),
            .init(bundleID: "com.knollsoft.Hookshot", name: "Rectangle Pro", replacedBy: .windows, clash: "⌃⌥ ← → ↑ ↓ ↩"),
            .init(bundleID: "com.crowdcafe.windowmagnet", name: "Magnet", replacedBy: .windows, clash: "⌃⌥ ← → ↑ ↓"),
            .init(bundleID: "com.manytricks.Moom", name: "Moom", replacedBy: .windows),
            .init(bundleID: "com.mizage.Divvy", name: "Divvy", replacedBy: .windows),
            .init(bundleID: "com.divisiblebyzero.Spectacle", name: "Spectacle", replacedBy: .windows, clash: "⌥⌘ ← → ↑ ↓"),
            .init(bundleID: "com.hegenberg.BetterSnapTool", name: "BetterSnapTool", replacedBy: .windows),
            .init(bundleID: "com.MrKai77.Loop", name: "Loop", replacedBy: .windows),
            .init(bundleID: "co.highlyopinionated.swish", name: "Swish", replacedBy: .windows),
            // Gestures
            .init(bundleID: "com.hegenberg.BetterTouchTool", name: "BetterTouchTool", replacedBy: .gestures, clash: "Trackpad gestures".loc),
            .init(bundleID: "art.ginzburg.MiddleClick", name: "MiddleClick", replacedBy: .gestures, clash: "Three-finger tap".loc),
            .init(bundleID: "com.nuebling.mac-mouse-fix", name: "Mac Mouse Fix", replacedBy: .gestures, clash: "Mouse buttons".loc),
            .init(bundleID: "jp.plentycom.app.SteerMouse", name: "SteerMouse", replacedBy: .gestures, clash: "Mouse buttons".loc),
            // Keep awake
            .init(bundleID: "com.if.Amphetamine", name: "Amphetamine", replacedBy: .awake),
            .init(bundleID: "info.marcel-dierkes.KeepingYouAwake", name: "KeepingYouAwake", replacedBy: .awake),
            .init(bundleID: "com.intelliscapesolutions.caffeine", name: "Caffeine", replacedBy: .awake),
            .init(bundleID: "com.sindresorhus.Lungo", name: "Lungo", replacedBy: .awake),
            .init(bundleID: "com.fiplab.theine", name: "Theine", replacedBy: .awake),
            // Clipboard
            .init(bundleID: "org.p0deje.Maccy", name: "Maccy", replacedBy: .clipboard, clash: "⇧⌘C"),
            .init(bundleID: "com.wiheads.paste", name: "Paste", replacedBy: .clipboard, clash: "⇧⌘V"),
            .init(bundleID: "com.generalarcade.flycut", name: "Flycut", replacedBy: .clipboard),
            .init(bundleID: "com.fiplab.copyclip2", name: "CopyClip", replacedBy: .clipboard),
            .init(bundleID: "com.tapbots.Pastebot2Mac", name: "Pastebot", replacedBy: .clipboard),
            .init(bundleID: "com.clipy-app.Clipy", name: "Clipy", replacedBy: .clipboard),
            // Launcher
            .init(bundleID: "com.raycast.macos", name: "Raycast", replacedBy: .home, clash: "⌥Space · " + "Snippets".loc),
            .init(bundleID: "com.runningwithcrayons.Alfred", name: "Alfred", replacedBy: .home, clash: "⌥Space"),
            .init(bundleID: "at.obdev.LaunchBar", name: "LaunchBar", replacedBy: .home),
            // Translate
            .init(bundleID: "com.linguee.DeepLCopyTranslator", name: "DeepL", replacedBy: .translate, clash: "⌘C ⌘C"),
            .init(bundleID: "com.hezongyidev.Bob", name: "Bob", replacedBy: .translate),
            .init(bundleID: "com.izual.Easydict", name: "Easydict", replacedBy: .translate),
            // Menu bar
            .init(bundleID: "com.HyperartFlow.Barbee", name: "Barbee", replacedBy: .menubar, clash: menuBar),
            .init(bundleID: "com.surteesstudios.Bartender", name: "Bartender", replacedBy: .menubar, clash: menuBar),
            .init(bundleID: "com.jordanbaird.Ice", name: "Ice", replacedBy: .menubar, clash: menuBar),
            .init(bundleID: "com.dwarvesv.minimalbar", name: "Hidden Bar", replacedBy: .menubar, clash: menuBar),
            .init(bundleID: "com.mortennn.Dozer", name: "Dozer", replacedBy: .menubar, clash: menuBar),
            .init(bundleID: "net.matthewpalmer.Vanilla", name: "Vanilla", replacedBy: .menubar, clash: menuBar),
            .init(bundleID: "com.mowglii.ItsycalApp", name: "Itsycal", replacedBy: .menubar),
            .init(bundleID: "com.sindresorhus.Dato", name: "Dato", replacedBy: .menubar),
            // Fans & system monitors
            .init(bundleID: "com.crystalidea.macsfancontrol", name: "Macs Fan Control", replacedBy: .system, clash: "Fan speed".loc),
            .init(bundleID: "com.tunabellysoftware.tgpro", name: "TG Pro", replacedBy: .system, clash: "Fan speed".loc),
            .init(bundleID: "eu.exelban.Stats", name: "Stats", replacedBy: .system),
            .init(bundleID: "com.bjango.istatmenus", name: "iStat Menus", replacedBy: .system),
            .init(bundleID: "com.kyome.RunCat", name: "RunCat", replacedBy: .system),
            // Sound
            .init(bundleID: "com.finetuneapp.FineTune", name: "FineTune", replacedBy: .sound, clash: audio),
            .init(bundleID: "com.rogueamoeba.soundsource", name: "SoundSource", replacedBy: .sound, clash: audio),
            .init(bundleID: "com.bearisdriving.BGM.App", name: "Background Music", replacedBy: .sound, clash: audio),
            .init(bundleID: "com.bitgapp.eqmac", name: "eqMac", replacedBy: .sound, clash: audio),
            .init(bundleID: "com.globaldelight.Boom3D", name: "Boom 3D", replacedBy: .sound, clash: audio),
            // Storage & uninstall
            .init(bundleID: "net.freemacsoft.AppCleaner", name: "AppCleaner", replacedBy: .storage),
            .init(bundleID: "com.alienator88.Pearcleaner", name: "Pearcleaner", replacedBy: .storage),
            .init(bundleID: "com.macpaw.CleanMyMac5", name: "CleanMyMac", replacedBy: .storage),
            .init(bundleID: "com.macpaw.CleanMyMac4", name: "CleanMyMac X", replacedBy: .storage),
            .init(bundleID: "com.daisydiskapp.DaisyDiskStandAlone", name: "DaisyDisk", replacedBy: .storage),
            .init(bundleID: "com.omnigroup.OmniDiskSweeper", name: "OmniDiskSweeper", replacedBy: .storage),
            .init(bundleID: "net.sourceforge.grandperspectivemac", name: "GrandPerspective", replacedBy: .storage),
            // Capture, color, shelf
            .init(bundleID: "pl.maketheweb.cleanshotx", name: "CleanShot X", replacedBy: .capture),
            .init(bundleID: "cc.ffitch.shottr", name: "Shottr", replacedBy: .capture),
            .init(bundleID: "com.monosnap.monosnap", name: "Monosnap", replacedBy: .capture),
            .init(bundleID: "com.skillbrains.lightshot", name: "Lightshot", replacedBy: .capture),
            .init(bundleID: "com.IdeaPunch.ColorSlurp", name: "ColorSlurp", replacedBy: .system),
            .init(bundleID: "io.sipapp.Sip-paddle", name: "Sip", replacedBy: .system),
            .init(bundleID: "me.damir.dropover-mac", name: "Dropover", replacedBy: .system),
            .init(bundleID: "at.EternalStorms.Yoink", name: "Yoink", replacedBy: .system),
            // Now playing
            .init(bundleID: "com.replay.sleeve", name: "Sleeve", replacedBy: .nowPlaying),
            // Battery
            .init(bundleID: "com.apphousekitchen.aldente-pro", name: "AlDente Pro", replacedBy: .battery, clash: "Charge limit".loc),
            .init(bundleID: "com.apphousekitchen.aldente", name: "AlDente", replacedBy: .battery, clash: "Charge limit".loc),
            .init(bundleID: "com.coconut-flavour.coconutBattery", name: "coconutBattery", replacedBy: .battery),
            // Displays
            .init(bundleID: "me.guillaumeb.MonitorControl", name: "MonitorControl", replacedBy: .displays, clash: "Brightness keys".loc),
            .init(bundleID: "fyi.lunar.Lunar", name: "Lunar", replacedBy: .displays, clash: "Brightness keys".loc),
            .init(bundleID: "pro.betterdisplay.BetterDisplay", name: "BetterDisplay", replacedBy: .displays, clash: "Brightness keys".loc),
            // Scrolling & keyboard
            .init(bundleID: "com.pilotmoon.scroll-reverser", name: "Scroll Reverser", replacedBy: .system, clash: "Scroll direction".loc),
            .init(bundleID: "com.caldis.Mos", name: "Mos", replacedBy: .system, clash: "Scroll direction".loc),
            .init(bundleID: "com.lujjjh.LinearMouse", name: "LinearMouse", replacedBy: .system, clash: "Scroll direction".loc),
            .init(bundleID: "com.hegenberg.KeyboardCleanTool", name: "KeyboardCleanTool", replacedBy: .system),
            // Archives & folder previews
            .init(bundleID: "com.aone.keka", name: "Keka", replacedBy: .archives, clash: "Default archive app".loc),
            .init(bundleID: "cx.c3.theunarchiver", name: "The Unarchiver", replacedBy: .archives, clash: "Default archive app".loc),
            .init(bundleID: "com.macitbetter.betterzip5", name: "BetterZip 5", replacedBy: .archives, clash: "Default archive app".loc),
            .init(bundleID: "ltd.anybox.FolderPreview", name: "Folder Preview", replacedBy: .archives, clash: "Quick Look for folders".loc),
            .init(bundleID: "ltd.anybox.FolderPreviewPro", name: "Folder Preview Pro", replacedBy: .archives, clash: "Quick Look for folders".loc),
            // Snippets
            .init(bundleID: "com.smileonmymac.textexpander", name: "TextExpander", replacedBy: .snippets, clash: "Text expansion".loc),
            .init(bundleID: "com.federicoterzi.espanso", name: "Espanso", replacedBy: .snippets, clash: "Text expansion".loc),
            .init(bundleID: "com.ergonis.typinator", name: "Typinator", replacedBy: .snippets, clash: "Text expansion".loc),
            // Passwords
            .init(bundleID: "com.1password.1password", name: "1Password", replacedBy: .passwords, clash: "⌘⇧Space"),
            .init(bundleID: "com.agilebits.onepassword7", name: "1Password 7", replacedBy: .passwords, clash: "⌥⌘\\"),
            .init(bundleID: "com.bitwarden.desktop", name: "Bitwarden", replacedBy: .passwords),
            .init(bundleID: "com.dashlane.dashlanephonefinal", name: "Dashlane", replacedBy: .passwords),
            .init(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass", replacedBy: .passwords),
        ]
    }()

    /// Where an app's bundle is, by ID or by its usual file name.
    private static func locate(_ k: KnownApp) -> URL? {
        // Launch Services remembers apps after they're deleted — including copies sitting in the
        // Trash — so only count a bundle that's really there, outside the Trash.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: k.bundleID), Self.installed(url) { return url }
        let roots = ["/Applications", "/Applications/Setapp", NSHomeDirectory() + "/Applications"]
        return roots.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(k.name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func installed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return FileManager.default.fileExists(atPath: path + "/Contents/Info.plist")
            && !path.contains("/.Trash/") && !path.hasPrefix("/Volumes/") && !path.contains("/Library/Developer/")
    }

    private(set) var apps: [FoundApp] = []
    private(set) var shortcuts: [ShortcutClash] = []
    private(set) var replaced: [ReplacedHotKey] = []

    /// How many things are worth a look; shown on Home.
    var count: Int { apps.count + shortcuts.count + replaced.count }

    func refresh() {
        let runningURLs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL })
        var seen = Set<String>()
        apps = Self.known.compactMap { k in
            guard let url = Self.locate(k), seen.insert(url.path).inserted else { return nil }
            return FoundApp(known: k, url: url, running: runningURLs.contains(url.standardizedFileURL))
        }
        .sorted { ($0.running ? 0 : 1, $0.known.name) < ($1.running ? 0 : 1, $1.known.name) }
        shortcuts = ShortcutClash.find()
        let clashing = Set(shortcuts.map(\.system.id))
        replaced = ReplacedHotKey.find().filter { !clashing.contains($0.system.id) }
    }

    func turnOffAllReplaced() {
        replaced.forEach { SystemHotKey.setEnabled($0.system.id, false) }
        refresh()
    }

    func quit(_ app: FoundApp) {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func quitAll() {
        apps.filter(\.running).forEach(quit)
    }

    /// Hands over to the uninstaller, which also finds the app's leftovers.
    func remove(_ app: FoundApp) {
        quit(app)
        AppUninstaller.shared.present(app: app.url)
    }
}

/// An Orbit shortcut that macOS also uses.
struct ShortcutClash: Identifiable {
    let orbit: KeyboardShortcuts.Name
    let orbitTitle: String
    let keys: String
    let system: SystemHotKey
    var id: String { orbit.rawValue + "-\(system.id)" }

    @MainActor static func find() -> [ShortcutClash] {
        let system = SystemHotKey.enabled()
        var names: [(KeyboardShortcuts.Name, String)] = [(.ring, "Orbit Ring".loc)]
        for action in OrbitAction.allCases {
            if let name = action.shortcutName, !names.contains(where: { $0.0 == name }) { names.append((name, action.title)) }
        }
        return names.flatMap { name, title -> [ShortcutClash] in
            guard let s = KeyboardShortcuts.getShortcut(for: name) else { return [] }
            let mods = SystemHotKey.mask(UInt(s.modifiers.rawValue))
            return system.filter { $0.keyCode == s.carbonKeyCode && $0.modifiers == mods }
                .map { ShortcutClash(orbit: name, orbitTitle: title, keys: s.label, system: $0) }
        }
    }
}

/// A macOS shortcut for something Orbit does better (screenshots, Spotlight). Turning it off frees
/// the keys; "Use for Orbit" also gives those keys to the matching Orbit action.
struct ReplacedHotKey: Identifiable {
    let system: SystemHotKey
    let orbit: OrbitAction?
    var id: Int { system.id }

    /// macOS id → the Orbit action that does the same job.
    private static let map: [Int: OrbitAction?] = [
        28: .captureScreen, 29: nil, 30: .captureArea, 31: nil, 184: .captureWindow, 64: .launcher,
    ]

    @MainActor var keys: String { system.shortcut?.description ?? "" }

    @MainActor static func find() -> [ReplacedHotKey] {
        SystemHotKey.enabled().compactMap { hk in
            guard let entry = map[hk.id] else { return nil }
            return ReplacedHotKey(system: hk, orbit: entry)
        }
        .sorted { $0.system.id < $1.system.id }
    }

    /// Turns macOS's off and moves its keys onto Orbit's action.
    @MainActor func handOver() {
        SystemHotKey.setEnabled(system.id, false)
        if let name = orbit?.shortcutName, let s = system.shortcut {
            // Whatever Orbit action had these keys before loses them.
            for action in OrbitAction.allCases {
                if let n = action.shortcutName, n != name, KeyboardShortcuts.getShortcut(for: n) == s { KeyboardShortcuts.setShortcut(nil, for: n) }
            }
            KeyboardShortcuts.setShortcut(s, for: name)
        }
        Overlaps.shared.refresh()
    }
}

/// A macOS keyboard shortcut from System Settings › Keyboard › Keyboard Shortcuts.
struct SystemHotKey: Identifiable {
    let id: Int
    let keyCode: Int
    let modifiers: UInt

    /// The same keys as a KeyboardShortcuts value, for display and for giving them to Orbit.
    var shortcut: KeyboardShortcuts.Shortcut? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var carbon = 0
        if flags.contains(.command) { carbon |= 1 << 8 }
        if flags.contains(.shift) { carbon |= 1 << 9 }
        if flags.contains(.option) { carbon |= 1 << 11 }
        if flags.contains(.control) { carbon |= 1 << 12 }
        return KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: carbon)
    }

    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    var title: String {
        switch id {
        case 28: "Save picture of screen as a file".loc
        case 29: "Copy picture of screen".loc
        case 30: "Save picture of selected area".loc
        case 31: "Copy picture of selected area".loc
        case 184: "Screenshot and recording options".loc
        case 64: "Show Spotlight search".loc
        case 65: "Show Finder search window".loc
        case 60: "Select the previous input source".loc
        case 61: "Select next source in Input menu".loc
        case 32: "Mission Control".loc
        case 33: "Application windows".loc
        case 36: "Show Desktop".loc
        case 79: "Move left a space".loc
        case 81: "Move right a space".loc
        case 118...126: "Switch to Desktop %ld".loc(id - 117)
        default: "macOS shortcut #%ld".loc(id)
        }
    }

    /// Only the four modifier keys; arrows and F-keys also carry fn/keypad bits.
    static func mask(_ raw: UInt) -> UInt { raw & (NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.control.rawValue | NSEvent.ModifierFlags.option.rawValue | NSEvent.ModifierFlags.command.rawValue) }

    /// Entries macOS only writes once the user changes them; until then these are the defaults.
    private static let defaults: [Int: (ascii: Int, key: Int, mods: Int)] = [
        28: (51, 20, 1_179_648), 29: (51, 20, 1_441_792), 30: (52, 21, 1_179_648), 31: (52, 21, 1_441_792),
        184: (53, 23, 1_179_648), 64: (32, 49, 1_048_576), 65: (32, 49, 1_572_864),
        60: (32, 49, 262_144), 61: (32, 49, 786_432),
    ]

    private static func table() -> [String: Any] {
        (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
    }

    static func enabled() -> [SystemHotKey] {
        let stored = table()
        var result: [Int: SystemHotKey] = [:]
        for (id, d) in defaults where stored[String(id)] == nil {
            result[id] = SystemHotKey(id: id, keyCode: d.key, modifiers: mask(UInt(d.mods)))
        }
        for (k, v) in stored {
            guard let id = Int(k), let entry = v as? [String: Any], (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                  let value = entry["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count == 3, p[1] != 65535 else { continue }
            result[id] = SystemHotKey(id: id, keyCode: p[1], modifiers: mask(UInt(p[2])))
        }
        return Array(result.values)
    }

    /// Turns the macOS shortcut off (or back on) and tells the system to reload its shortcuts.
    static func setEnabled(_ id: Int, _ on: Bool) {
        var all = table()
        var entry = all[String(id)] as? [String: Any] ?? [:]
        if entry["value"] == nil, let d = defaults[id] {
            entry["value"] = ["parameters": [d.ascii, d.key, d.mods], "type": "standard"] as [String: Any]
        }
        entry["enabled"] = on
        all[String(id)] = entry
        CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        var disabled = Set(Pref.defaults.array(forKey: Pref.disabledSystemShortcuts) as? [Int] ?? [])
        if on { disabled.remove(id) } else { disabled.insert(id) }
        Pref.defaults.set(Array(disabled), forKey: Pref.disabledSystemShortcuts)
        let reload = Process()
        reload.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        reload.arguments = ["-u"]
        try? reload.run()
    }
}
