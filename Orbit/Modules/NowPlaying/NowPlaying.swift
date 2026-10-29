import AppKit
import SwiftUI

/// The song playing right now, from any app, and the controls for it.
@MainActor @Observable
final class NowPlaying {
    static let shared = NowPlaying()

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var bundle: String?
        var appName: String?
        var isMusic: Bool

        /// Same song, whatever its progress.
        var key: String { "\(title)\u{1}\(artist)\u{1}\(album)" }
    }

    enum Status: Equatable { case off, starting, ready, unavailable(String) }

    private(set) var track: Track?
    private(set) var artwork: NSImage?
    private(set) var palette = ArtworkPalette.neutral
    private(set) var playing = false
    private(set) var status: Status = .off
    /// The source app's icon.
    private(set) var appIcon: NSImage?
    /// Liked in the source app (Music, read through AppleScript) or by the user here.
    private(set) var liked = false
    /// When the current track started, for scrobbling.
    private(set) var trackStarted = Date()
    /// Bumped on every new track; views key their transitions on it.
    private(set) var generation = 0

    private var elapsedAnchor: Double = 0
    private var anchorDate = Date()
    private var rate: Double = 0
    private var artworkKey: String?
    private var likedKeys: Set<String> = []

    private let bridge = MediaRemoteBridge()
    private var pollTimer: Timer?
    private var started = false
    private var usingScripts = false

    var onTrackChange: ((Track) -> Void)?

    #if DEBUG
    /// Debug: a placeholder song's fixed position; while set, the real player isn't listened to.
    var debugElapsed: Double?

    /// Debug: shows a made-up song instead of what's really playing, for promo frames; nil goes back.
    func debugPlaceholder(title: String?, artist: String, duration: Double, elapsed: Double, artwork: NSImage?) {
        guard let title else {
            debugElapsed = nil
            track = nil
            playing = false
            setArtwork(nil)
            update()
            return
        }
        debugElapsed = elapsed
        stop()
        track = Track(title: title, artist: artist, album: "", duration: duration, bundle: nil, appName: nil, isMusic: true)
        setArtwork(artwork)
        playing = true
        generation += 1
    }
    #endif

    private init() {
        bridge.onPayload = { [weak self] in self?.apply($0) }
        bridge.onFailure = { [weak self] message in
            guard let self else { return }
            self.status = .unavailable(message)
            self.startPollingIfAllowed()
        }
        onTrackChange = { [weak self] t in
            // Not for the song that was already on when Orbit started listening.
            guard let self, Date().timeIntervalSince(self.listeningSince) > 3 else { return }
            TrackPopup.shared.show(t)
        }
    }

    private var listeningSince = Date()

    // MARK: Lifecycle

    /// Any feature that shows or uses the current song.
    var needed: Bool {
        let d = Pref.defaults
        return d.bool(forKey: NowPlayingPrefs.widget) || d.bool(forKey: NowPlayingPrefs.popup)
            || d.bool(forKey: NowPlayingPrefs.notch) || NowPlayingPrefs.autoPauseOn
            || (NotchCenter.enabled && d.bool(forKey: NotchPrefs.liveMusic))
    }

    /// Starts or stops listening to match what's turned on, and the widget/notch/popup with it.
    func update() {
        if needed { start() } else { stop() }
        NowPlayingWidgetController.shared.update()
        NotchPlayer.shared.update()
    }

    func start() {
        #if DEBUG
        if debugElapsed != nil { return } // a placeholder song is showing; don't listen
        #endif
        guard !started else { return }
        started = true
        listeningSince = Date()
        status = .starting
        if MediaRemoteBridge.available {
            bridge.start()
            status = .ready
        } else {
            status = .unavailable("The Now Playing helper is missing from Orbit.")
            startPollingIfAllowed()
        }
        // Scripts also tell whether a Music song is loved; refreshed now and then while playing.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        pollTimer?.tolerance = 0.5
    }

    func stop() {
        guard started else { return }
        started = false
        bridge.stop()
        pollTimer?.invalidate()
        pollTimer = nil
        status = .off
    }

    private func startPollingIfAllowed() {
        usingScripts = ScriptedPlayers.enabled
    }

    // MARK: Time

    var duration: Double { track?.duration ?? 0 }

    func elapsed(at date: Date = Date()) -> Double {
        #if DEBUG
        if let debugElapsed { return debugElapsed }
        #endif
        let e = elapsedAnchor + (playing ? date.timeIntervalSince(anchorDate) * (rate > 0 ? rate : 1) : 0)
        return duration > 0 ? min(max(0, e), duration) : max(0, e)
    }

    // MARK: Commands

    func togglePlayPause() {
        ensureListening()
        MediaDucker.shared.userActed()
        if track != nil {
            // Feels instant; the next update from the app corrects it.
            elapsedAnchor = elapsed()
            anchorDate = Date()
            playing.toggle()
        }
        if let app = scriptApp { Task { await ScriptedPlayers.send(.playPause, to: app) } }
        else { bridge.send(.togglePlayPause) }
    }

    func next() {
        ensureListening()
        MediaDucker.shared.userActed()
        if let app = scriptApp { Task { await ScriptedPlayers.send(.next, to: app) } } else { bridge.send(.next) }
    }

    func previous() {
        ensureListening()
        MediaDucker.shared.userActed()
        if let app = scriptApp { Task { await ScriptedPlayers.send(.previous, to: app) } } else { bridge.send(.previous) }
    }

    func seek(to seconds: Double) {
        elapsedAnchor = seconds
        anchorDate = Date()
        if let app = scriptApp { Task { await ScriptedPlayers.send(.seek(seconds), to: app) } } else { bridge.seek(to: seconds) }
    }

    func toggleLike() {
        ensureListening()
        guard let track else { Toast.show("Nothing is playing", symbol: "music.note"); return }
        let on = !liked
        // Spotify keeps Liked Songs to itself.
        if track.bundle == ScriptedPlayers.App.spotify.rawValue {
            Toast.show("Spotify doesn’t let other apps like songs", symbol: "heart.slash", detail: "Like it in Spotify itself")
            return
        }
        liked = on
        if on { likedKeys.insert(track.key) } else { likedKeys.remove(track.key) }
        if ScriptedPlayers.enabled, track.bundle == ScriptedPlayers.App.music.rawValue {
            Task { await ScriptedPlayers.send(.like(on), to: .music) }
        } else if on {
            bridge.send(.like) // apps that take Now Playing's "like" (Music without scripting, some players)
        }
        Toast.show(on ? "Liked" : "Removed from Liked", symbol: on ? "heart.fill" : "heart", detail: track.title)
    }

    /// A Now Playing command for one app (nil: whatever is now playing), for auto-pause.
    func send(_ command: MediaRemoteBridge.Command, to bundle: String?) {
        if let bundle { bridge.send(command, to: bundle) } else { bridge.send(command) }
    }

    /// Commands from a shortcut work even with every Now Playing feature off.
    private func ensureListening() {
        if !started { start() }
    }

    /// Music and Spotify are driven by script when the user allowed it; anything else goes through Now Playing.
    private var scriptApp: ScriptedPlayers.App? {
        guard ScriptedPlayers.enabled, let app = ScriptedPlayers.app(for: track?.bundle) else {
            // With no Now Playing helper, the scripts are the only way.
            if usingScripts, let running = ScriptedPlayers.App.allCases.first(where: \.isRunning) { return running }
            return nil
        }
        return app
    }

    // MARK: Updates

    private func apply(_ p: MediaRemoteBridge.Payload) {
        guard p.type == "info" else { return }
        status = .ready
        let source = p.parentBundle ?? p.bundle
        MediaDucker.shared.observe(bundle: p.title == nil ? nil : source, isMusicApp: p.isMusicApp ?? false,
                                   key: p.title.map { "\($0)\u{1}\(p.artist ?? "")\u{1}\(p.album ?? "")" },
                                   playing: p.playing ?? ((p.rate ?? 0) > 0))
        guard let title = p.title, (p.pid ?? 0) != 0 || p.bundle != nil else {
            clear()
            return
        }
        let bundle = source
        lastSource = bundle.map { ($0, p.appName ?? Self.appName(for: $0) ?? $0) }
        if !Self.allowed(bundle ?? "", isMusicApp: p.isMusicApp ?? false) {
            if lastSkipped != bundle {
                lastSkipped = bundle
                NowPlayingLog.write("not showing \(bundle ?? "an unknown app") (not a music app, or skipped)")
            }
            clear()
            return
        }
        let new = Track(title: title, artist: p.artist ?? "", album: p.album ?? "", duration: p.duration ?? 0,
                        bundle: bundle, appName: p.appName, isMusic: p.isMusicApp ?? Self.musicApps.contains(bundle ?? ""))
        let changed = new.key != track?.key
        playing = p.playing ?? ((p.rate ?? 0) > 0)
        rate = p.rate ?? (playing ? 1 : 0)
        if let e = p.elapsed {
            elapsedAnchor = e
            anchorDate = p.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
            // MediaRemote's timestamp can be well in the past for paused tracks.
            if !playing { anchorDate = Date() }
        }
        if let art = p.artwork, let data = Data(base64Encoded: art), let image = NSImage(data: data) {
            setArtwork(image)
            artworkKey = p.artworkKey
        } else if p.artworkKey == nil, changed {
            setArtwork(nil)
        }
        if changed { begin(new) } else { track = new }
    }

    private func begin(_ new: Track) {
        let previous = track
        track = new
        generation += 1
        trackStarted = Date().addingTimeInterval(-elapsed())
        liked = likedKeys.contains(new.key)
        if new.bundle != previous?.bundle { appIcon = Self.icon(for: new.bundle) }
        NowPlayingLog.write("track: \(new.appName ?? new.bundle ?? "?") — \(new.title.prefix(40))")
        onTrackChange?(new)
        if ScriptedPlayers.enabled { poll() }
        fetchMissingArtwork(for: generation)
    }

    /// The cover usually comes a moment after the song's title. If it still hasn't come, ask the player
    /// itself (Music hands over the picture, Spotify a link to it).
    private func fetchMissingArtwork(for gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.generation == gen, self.artwork == nil, ScriptedPlayers.enabled,
                  let app = ScriptedPlayers.app(for: self.track?.bundle) else { return }
            let title = self.track?.title
            Task {
                var image: NSImage?
                switch app {
                case .music: image = await ScriptedPlayers.musicArtwork()
                case .spotify:
                    if let s = await ScriptedPlayers.read(.spotify), s.title == title, let url = s.artworkURL,
                       let (data, _) = try? await URLSession.shared.data(from: url) { image = NSImage(data: data) }
                }
                guard let image, self.generation == gen, self.artwork == nil else { return }
                NowPlayingLog.write("artwork: filled in from \(app.scriptName)")
                self.setArtwork(image)
            }
        }
    }

    private func clear() {
        guard track != nil || playing else { return }
        track = nil
        playing = false
        artworkKey = nil
        setArtwork(nil)
        generation += 1
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        palette = image.map(ArtworkPalette.init) ?? .neutral
        // A banner already up for this song shows the cover as soon as it arrives.
        if image != nil { TrackPopup.shared.refresh() }
    }

    /// AppleScript top-ups: Music's loved state, and the whole state when Now Playing isn't available.
    private func poll() {
        guard ScriptedPlayers.enabled else { return }
        let useAsSource = usingScripts || { if case .unavailable = status { return true }; return false }()
        let bundle = track?.bundle
        Task {
            if useAsSource {
                guard let s = await ScriptedPlayers.read() else { clear(); return }
                applyScripted(s)
            } else if bundle == ScriptedPlayers.App.music.rawValue, let s = await ScriptedPlayers.read(.music), s.title == track?.title {
                if let l = s.liked { liked = l }
            }
        }
    }

    private func applyScripted(_ s: ScriptedPlayers.State) {
        guard Self.allowed(s.app.rawValue, isMusicApp: true) else { clear(); return }
        let new = Track(title: s.title, artist: s.artist, album: s.album, duration: s.duration, bundle: s.app.rawValue,
                        appName: s.app.scriptName, isMusic: true)
        playing = s.playing
        rate = s.playing ? 1 : 0
        elapsedAnchor = s.position
        anchorDate = Date()
        if let l = s.liked { liked = l }
        guard new.key != track?.key else { track = new; return }
        begin(new)
        Task {
            if s.app == .music { setArtwork(await ScriptedPlayers.musicArtwork()) }
            else if let url = s.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) { setArtwork(NSImage(data: data)) }
        }
    }

    static let musicApps: Set<String> = [
        "com.apple.Music", "com.apple.iTunes", "com.apple.podcasts", "com.spotify.client", "com.tidal.desktop",
        "com.deezer.deezer-desktop", "com.amazon.music", "com.coppertino.Vox", "com.swinsian.Swinsian",
        "co.brushedtype.doppler-macos", "com.github.th-ch.youtube-music", "app.ytmd.youtube-music-desktop-app",
        "com.ytmdesktop.app", "sh.cider.electron", "sh.cider.genten.mac", "com.cider.app", "tv.plex.plexamp",
        "com.audirvana.Audirvana-Studio", "com.audirvana.Audirvana", "com.foobar2000.mac", "com.roon.Roon",
        "com.qobuz.QobuzDesktop", "com.soundcloud.desktop", "com.pandora.desktop", "com.bandcamp.app",
        "com.marvis.pro", "com.melodics.app", "com.overcast.mac", "fm.castro.mac",
    ]

    /// Browsers (and their web content processes) play video and ads far more often than music.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent",
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "company.thebrowser.Browser",
        "company.thebrowser.dia", "at.studio.AsideBrowser", "com.microsoft.edgemac", "com.brave.Browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.operasoftware.Opera", "com.kagi.kagimacOS",
        "app.zen-browser.zen", "com.vivaldi.Vivaldi", "org.chromium.Chromium", "com.sigmaos.sigmaos.macos",
        "com.openai.atlas", "ai.perplexity.comet",
    ]

    /// Whether this source shows, by "Show from" and the skipped apps.
    static func allowed(_ bundle: String, isMusicApp: Bool) -> Bool {
        let d = Pref.defaults
        if (d.stringArray(forKey: NowPlayingPrefs.excluded) ?? []).contains(bundle) { return false }
        guard (d.string(forKey: NowPlayingPrefs.sources) ?? "music") == "music" else { return true }
        if browsers.contains(bundle) || bundle.hasPrefix("com.apple.WebKit") { return false }
        return musicApps.contains(bundle) || isMusicApp
    }

    /// The last app Now Playing reported, shown or not, for "Skip this app".
    private(set) var lastSource: (bundle: String, name: String)?
    @ObservationIgnored private var lastSkipped: String?

    /// Re-reads after "Show from" or the skipped apps change.
    func sourcesChanged() {
        clear()
        bridge.refresh()
    }

    static func appName(for bundle: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    private static func icon(for bundle: String?) -> NSImage? {
        guard let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Opens the app that's playing.
    func openSource() {
        guard let bundle = track?.bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Artwork colors

/// Colors pulled from the cover: a deep background, a vivid accent, and which text reads on it.
struct ArtworkPalette: Equatable {
    var background: Color
    var accent: Color
    var isDark: Bool
    var backgroundNS: NSColor

    static let neutral = ArtworkPalette(background: Color(white: 0.12), accent: Palette.brand, isDark: true,
                                        backgroundNS: NSColor(white: 0.12, alpha: 1))

    init(background: Color, accent: Color, isDark: Bool, backgroundNS: NSColor) {
        self.background = background; self.accent = accent; self.isDark = isDark; self.backgroundNS = backgroundNS
    }

    init(_ image: NSImage) {
        let side = 24
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            self = .neutral; return
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { self = .neutral; return }

        // Hue buckets weighted by saturation: the most present real color wins over grey.
        var buckets = [(r: Double, g: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: 12)
        var avg = (r: 0.0, g: 0.0, b: 0.0)
        for i in 0..<(side * side) {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            avg.r += r; avg.g += g; avg.b += b
            let c = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let s = c.saturationComponent, v = c.brightnessComponent
            let w = s * s * (0.25 + v)
            let k = min(11, Int(c.hueComponent * 12))
            buckets[k].r += r * w; buckets[k].g += g * w; buckets[k].b += b * w; buckets[k].w += w
        }
        let n = Double(side * side)
        avg = (avg.r / n, avg.g / n, avg.b / n)
        let top = buckets.max { $0.w < $1.w }!
        let vivid: NSColor = top.w > 4
            ? NSColor(srgbRed: top.r / top.w, green: top.g / top.w, blue: top.b / top.w, alpha: 1)
            : NSColor(srgbRed: avg.r, green: avg.g, blue: avg.b, alpha: 1)

        // Background: the cover's own color, deepened so white text always reads.
        let base = NSColor(srgbRed: avg.r * 0.55 + vivid.redComponent * 0.45, green: avg.g * 0.55 + vivid.greenComponent * 0.45,
                           blue: avg.b * 0.55 + vivid.blueComponent * 0.45, alpha: 1)
        let bg = NSColor(hue: base.hueComponent, saturation: min(0.75, base.saturationComponent * 1.1),
                         brightness: min(0.32, max(0.12, base.brightnessComponent * 0.55)), alpha: 1)
        let accent = NSColor(hue: vivid.hueComponent, saturation: max(0.45, vivid.saturationComponent),
                             brightness: max(0.75, vivid.brightnessComponent), alpha: 1)
        self.init(background: Color(nsColor: bg), accent: vivid.saturationComponent > 0.15 ? Color(nsColor: accent) : .white,
                  isDark: true, backgroundNS: bg)
    }
}
