import AppKit

/// Music and Spotify driven directly through AppleScript — opt-in, since macOS asks once per app.
/// Used for things Now Playing can't do (liking a song in Music) and as the source when the
/// Now Playing helper isn't available.
enum ScriptedPlayers {
    enum App: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var scriptName: String { self == .music ? "Music" : "Spotify" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }

    struct State {
        var app: App
        var playing: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var liked: Bool?
        var artworkURL: URL?
    }

    private static let queue = DispatchQueue(label: "orbit.nowplaying.scripts")

    static var enabled: Bool { Pref.defaults.bool(forKey: NowPlayingPrefs.directControl) }

    static func app(for bundle: String?) -> App? { bundle.flatMap(App.init(rawValue:)) }

    /// Reads whichever of the two is running and playing (or paused), never launching either.
    static func read() async -> State? {
        for app in App.allCases where app.isRunning {
            if let s = await read(app) { return s }
        }
        return nil
    }

    static func read(_ app: App) async -> State? {
        guard app.isRunning else { return nil }
        let body: String
        switch app {
        case .spotify:
            body = """
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) / 1000 as text) & linefeed & (player position as text) & linefeed & "-" & linefeed & (artwork url of t)
            """
        case .music:
            body = """
            if player state is stopped then return "stopped"
            set t to current track
            set f to "-"
            try
                set f to (favorited of t) as text
            on error
                try
                    set f to (loved of t) as text
                end try
            end try
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as text) & linefeed & (player position as text) & linefeed & f & linefeed & "-"
            """
        }
        guard let text = await run("tell application \"\(app.scriptName)\"\n\(body)\nend tell")?.stringValue else { return nil }
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 8 else { return nil }
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return State(app: app, playing: parts[0] == "playing", title: parts[1], artist: parts[2], album: parts[3],
                     duration: number(parts[4]), position: number(parts[5]),
                     liked: parts[6] == "-" ? nil : parts[6] == "true",
                     artworkURL: parts[7] == "-" ? nil : URL(string: parts[7]))
    }

    /// Music's artwork for the current track, as image data.
    static func musicArtwork() async -> NSImage? {
        guard App.music.isRunning,
              let d = await run("tell application \"Music\" to get raw data of artwork 1 of current track")?.data,
              !d.isEmpty else { return nil }
        return NSImage(data: d)
    }

    enum Command { case playPause, play, pause, next, previous, seek(Double), like(Bool) }

    @discardableResult
    static func send(_ command: Command, to app: App) async -> Bool {
        guard app.isRunning else { return false }
        let line: String
        switch command {
        case .playPause: line = "playpause"
        case .play: line = "play"
        case .pause: line = "pause"
        case .next: line = "next track"
        case .previous: line = "previous track"
        case .seek(let s): line = "set player position to \(String(format: "%.2f", s))"
        case .like(let on):
            guard app == .music else { return false } // Spotify has no scripting for Liked Songs
            line = "try\nset favorited of current track to \(on)\non error\nset loved of current track to \(on)\nend try"
        }
        return await run("tell application \"\(app.scriptName)\"\n\(line)\nend tell") != nil
    }

    enum Permission: Equatable { case allowed, denied, notAsked, notRunning, unknown }

    /// Whether macOS lets Orbit script this app. With `ask`, shows macOS's prompt if it hasn't yet.
    static func permission(_ app: App, ask: Bool) async -> Permission {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: app.rawValue)
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
                NowPlayingLog.write("automation \(app.scriptName): \(status)")
                let result: Permission = switch status {
                case noErr: .allowed
                case OSStatus(errAEEventNotPermitted): .denied
                case OSStatus(errAEEventWouldRequireUserConsent): .notAsked
                case OSStatus(procNotFound): .notRunning
                default: .unknown
                }
                cont.resume(returning: result)
            }
        }
    }

    private static func run(_ source: String) async -> NSAppleEventDescriptor? {
        await withCheckedContinuation { cont in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { NowPlayingLog.write("script error: \(error[NSAppleScript.errorMessage] ?? error)") }
                cont.resume(returning: error == nil ? result : nil)
            }
        }
    }
}
