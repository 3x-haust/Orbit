import Foundation

enum Storage {
    static let root: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func load<T: Decodable>(_ type: T.Type, from file: String) -> T? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to file: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: root.appendingPathComponent(file), options: .atomic)
    }
}

/// User preferences, shared between settings UI (@AppStorage) and services.
enum Pref {
    static let historyLimit = "clipboard.historyLimit"
    static let ignoredApps = "clipboard.ignoredApps"
    static let pausedUntil = "clipboard.pausedUntil"
    static let pasteDirectly = "clipboard.pasteDirectly"
    static let captureSaveFolder = "capture.saveFolder"
    static let captureAutoCopy = "capture.autoCopy"
    static let captureSound = "capture.sound"
    static let captureThumbnailSeconds = "capture.thumbnailSeconds"
    /// Which screen corner screenshot previews appear in: bottomLeft, bottomRight, topLeft, topRight.
    static let captureThumbnailCorner = "capture.thumbnailCorner"
    static let windowGap = "window.gap"
    static let windowStageManager = "window.stageManagerAware"
    static let windowStageWidth = "window.stageStripWidth"
    static let onboarded = "app.onboarded"
    static let systemAccent = "app.systemAccent"
    static let awakeDisplay = "awake.keepDisplayOn"
    static let awakeClosedLid = "awake.closedLid"
    static let awakeLidOwned = "awake.lidOwnedByOrbit"
    static let awakeBatteryFloor = "awake.batteryFloor"
    static let awakeThermal = "awake.stopWhenHot"
    static let shelfEdge = "shelf.edgeReveal"
    static let timedCaptureSeconds = "capture.timerSeconds"
    static let translateDoubleCopy = "translate.doubleCopy"
    static let translateInterval = "translate.interval"
    static let translateEngine = "translate.engine"
    static let translatePrimary = "translate.primary"
    static let translateSecondary = "translate.secondary"
    static let translateFormality = "translate.formality"
    static let translateFontSize = "translate.fontSize"
    static let translateShowSource = "translate.showSource"
    static let translateCloseOnBlur = "translate.closeOnBlur"
    static let calendarEnabled = "menubar.calendar"
    /// The planet (SwiftUI MenuBarExtra). Off by default: the ✦, the ring and shortcuts reach Orbit.
    static let showOrbitIcon = "menubar.showOrbitIcon"
    static let calendarStyle = "menubar.calendarStyle"
    static let calendarIcon = "menubar.calendarIcon"
    static let calendarIconMonth = "menubar.calendarIconMonth"
    static let calendarIconWeekday = "menubar.calendarIconWeekday"
    static let calendarFormat = "menubar.calendarFormat"
    static let calendarEvents = "menubar.calendarEvents"
    static let calendarWeekStart = "menubar.weekStartsMonday"
    static let hiderEnabled = "menubar.hider"
    static let hiderAutoCollapse = "menubar.hiderAutoCollapse"
    static let hiderStyle = "menubar.hiderStyle"
    static let hiderAlways = "menubar.hiderAlways"
    /// The hider button's look: "chevron" (‹ › showing the state) or one of MenuBarHider.icons.
    static let hiderIcon = "menubar.hiderIcon"
    static let fanMode = "fans.mode"
    /// macOS shortcuts Orbit turned off, so they can be turned back on.
    static let disabledSystemShortcuts = "overlaps.disabledSystemShortcuts"
    static let fanFixedLevel = "fans.fixedLevel"
    static let fanCurveLow = "fans.curveLow"
    static let fanCurveHigh = "fans.curveHigh"

    static func register() {
        UserDefaults.standard.register(defaults: [
            historyLimit: 500,
            pasteDirectly: true,
            captureAutoCopy: true,
            captureSound: true,
            captureThumbnailSeconds: 8.0,
            windowGap: 0.0,
            windowStageManager: true,
            windowStageWidth: 190.0,
            awakeDisplay: true,
            awakeClosedLid: false,
            awakeBatteryFloor: 20,
            awakeThermal: true,
            shelfEdge: true,
            timedCaptureSeconds: 5,
            translateDoubleCopy: true,
            translateInterval: 0.4,
            translateEngine: "google",
            translatePrimary: "ko",
            translateSecondary: "en",
            translateFormality: "auto",
            translateFontSize: 16.0,
            translateShowSource: true,
            translateCloseOnBlur: true,
            calendarEnabled: true,
            calendarStyle: "date",
            calendarIcon: "none",
            calendarIconMonth: false,
            calendarIconWeekday: false,
            calendarFormat: "",
            calendarEvents: true,
            calendarWeekStart: false,
            hiderEnabled: false,
            hiderAutoCollapse: 10,
            hiderStyle: "bar",
            hiderAlways: false,
            fanMode: "auto",
            fanFixedLevel: 0.5,
            fanCurveLow: 55.0,
            fanCurveHigh: 85.0,
            captureSaveFolder: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path,
            ignoredApps: [
                "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
                "com.bitwarden.desktop", "com.apple.Passwords",
            ],
        ])
    }

    static var defaults: UserDefaults { .standard }

    /// Where a status item first appears, in points from the right end of the app icons (1 = next to
    /// Control Center). Only seeded once, so a ⌘-drag by the user always wins. New items otherwise land
    /// at the far left, where a crowded notched menu bar pushes them out of sight.
    static func seedMenuBarPosition(_ autosaveName: String, _ position: Double) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if defaults.object(forKey: key) == nil { defaults.set(position, forKey: key) }
    }
}
