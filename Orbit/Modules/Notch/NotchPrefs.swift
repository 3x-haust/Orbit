import Foundation

/// Settings for Orbit's notch: what opens it, what lives in it, how it looks.
enum NotchPrefs {
    static let enabled = "notch.enabled"

    // Opening
    static let hoverOpen = "notch.hoverOpen"
    static let openDelay = "notch.openDelay"
    static let closeDelay = "notch.closeDelay"
    static let swipe = "notch.swipe"
    static let haptics = "notch.haptics"

    // Look
    static let scale = "notch.scale"
    static let radius = "notch.radius"
    static let shadow = "notch.shadow"
    /// "notch": only screens with a camera housing; "all": a drawn notch on the others too.
    static let screens = "notch.screens"
    static let hideFullScreen = "notch.hideFullScreen"

    // Tabs in the open notch
    static let tabHome = "notch.tab.home"
    static let tabShelf = "notch.tab.shelf"
    static let tabMirror = "notch.tab.mirror"
    static let tabTimer = "notch.tab.timer"
    static let tabClipboard = "notch.tab.clipboard"

    // Live activities beside the closed notch
    static let liveMusic = "notch.live.music"
    static let liveCharging = "notch.live.charging"
    static let liveTimer = "notch.live.timer"
    static let liveRecording = "notch.live.recording"
    static let liveAwake = "notch.live.awake"
    static let liveFocus = "notch.live.focus"
    static let liveDownloads = "notch.live.downloads"
    static let liveBluetooth = "notch.live.bluetooth"

    /// The tab an open shows: "home", or "last" (the one last looked at).
    static let openTab = "notch.openTab"

    /// Minutes for the "Start Notch Timer" shortcut.
    static let timerMinutes = "notch.timerMinutes"

    /// Where Orbit's volume and brightness HUD appears: "notch" or "bottom". Shared with Displays.
    static let hudPlace = "displays.hudPlace"

    static func register() {
        Pref.defaults.register(defaults: [
            enabled: true,
            hoverOpen: true, openDelay: 0.12, closeDelay: 0.35, swipe: true, haptics: true,
            scale: 1.0, radius: 30.0, shadow: true, screens: "notch", hideFullScreen: true,
            tabHome: true, tabShelf: true, tabMirror: true, tabTimer: true, tabClipboard: true,
            liveMusic: true, liveCharging: true, liveTimer: true, liveRecording: true, liveAwake: true,
            liveFocus: true, liveDownloads: false, liveBluetooth: false,
            timerMinutes: 25, hudPlace: "bottom", openTab: "home",
        ])
    }

    static func bool(_ key: String) -> Bool { Pref.defaults.bool(forKey: key) }
    static func double(_ key: String) -> Double { Pref.defaults.double(forKey: key) }
}
