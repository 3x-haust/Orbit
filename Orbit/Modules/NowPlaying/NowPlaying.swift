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
    /// What one app last reported.
    struct Report: Equatable {
        var track: Track
        var rate: Double
        var elapsed: Double?
        var anchor: Date
    }
    /// Every app Now Playing reported, and which of them shows.
    @ObservationIgnored private var sources = NowPlayingSources<Report>()
    /// Each app's cover for its last song.
    @ObservationIgnored private var covers: [String: (key: String, artworkKey: String?, image: NSImage)] = [:]
    @ObservationIgnored private var settleWork: DispatchWorkItem?
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

    /// `heard`: from a shortcut, the Ring, a knock or a hot corner. Like the keyboard's play key, that
    /// goes to the app macOS's Now Playing is on (a YouTube video in a browser, say) when it isn't
    /// what's shown, rather than starting the paused music over it. The widget's and the notch's
    /// buttons are for what they show.
    func togglePlayPause(heard: Bool = false) {
        ensureListening()
        MediaDucker.shared.userActed()
        if heard, heardElsewhere {
            bridge.send(.togglePlayPause)
            return
        }
        if track != nil {
            // Feels instant; the next update from the app corrects it.
            elapsedAnchor = elapsed()
            anchorDate = Date()
            playing.toggle()
        }
        if let app = scriptApp { Task { await ScriptedPlayers.send(.playPause, to: app) } }
        else { bridge.send(.togglePlayPause) }
    }

    func next(heard: Bool = false) {
        ensureListening()
        MediaDucker.shared.userActed()
        if heard, heardElsewhere { bridge.send(.next); return }
        if let app = scriptApp { Task { await ScriptedPlayers.send(.next, to: app) } } else { bridge.send(.next) }
    }

    func previous(heard: Bool = false) {
        ensureListening()
        MediaDucker.shared.userActed()
        if heard, heardElsewhere { bridge.send(.previous); return }
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
        let webMusic = source.map { Self.isWebMusic($0, album: p.album) } ?? false
        systemSource = source.map { ($0, p.title != nil && (p.playing ?? ((p.rate ?? 0) > 0))) }
        let musicFlag = source.map(Self.isBrowser) == true ? webMusic : (p.isMusicApp ?? false)
        MediaDucker.shared.observe(bundle: p.title == nil ? nil : source, isMusicApp: musicFlag,
                                   key: p.title.map { "\($0)\u{1}\(p.artist ?? "")\u{1}\(p.album ?? "")" },
                                   playing: p.playing ?? ((p.rate ?? 0) > 0))
        guard let title = p.title, (p.pid ?? 0) != 0 || p.bundle != nil else {
            sources.reportNothing()
            settle()
            return
        }
        let bundle = source ?? "pid.\(p.pid ?? 0)"
        lastSource = source.map { ($0, p.appName ?? Self.appName(for: $0) ?? $0) }
        let allowed = Self.allowed(bundle, isMusicApp: p.isMusicApp ?? false, album: p.album)
        if !allowed, lastSkipped != bundle {
            lastSkipped = bundle
            NowPlayingLog.write("not showing \(bundle) (not a music app, or skipped)")
        }
        let new = Track(title: title, artist: p.artist ?? "", album: p.album ?? "", duration: p.duration ?? 0,
                        bundle: bundle, appName: p.appName ?? Self.appName(for: bundle),
                        isMusic: (p.isMusicApp ?? Self.musicApps.contains(bundle)) || webMusic)
        let playing = p.playing ?? ((p.rate ?? 0) > 0)
        var report = Report(track: new, rate: p.rate ?? (playing ? 1 : 0), elapsed: p.elapsed, anchor: Date())
        if p.elapsed != nil {
            // MediaRemote's timestamp can be well in the past for paused tracks.
            if playing, let t = p.timestamp { report.anchor = Date(timeIntervalSince1970: t) }
        } else if let old = sources.sources[bundle]?.info, old.track.key == new.key {
            report.elapsed = old.elapsed
            report.anchor = old.anchor
        }
        if allowed {
            if let art = p.artwork, let data = Data(base64Encoded: art), let image = NSImage(data: data) {
                covers[bundle] = (new.key, p.artworkKey, image)
            } else if let c = covers[bundle], c.key != new.key {
                // The same picture carried over to the next song (an album), or none yet.
                covers[bundle] = p.artworkKey != nil && c.artworkKey == p.artworkKey ? (new.key, c.artworkKey, c.image) : nil
            }
        }
        sources.report(bundle, key: new.key, info: report, playing: playing, allowed: allowed, now: Self.uptime)
        settle()
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Shows what `sources` picked, announces a new song, and comes back when a switch is due.
    private func settle() {
        settleWork?.cancel()
        settleWork = nil
        let now = Self.uptime
        let step = sources.step(now: now)
        switch step.change {
        case .keep: break
        case .clear: clear()
        case .show(let s): show(s)
        }
        syncArtwork()
        if let a = step.announce, a.key == track?.key, let track {
            NowPlayingLog.write("new song: \(track.appName ?? a.bundle) — \(track.title.prefix(40))")
            onTrackChange?(track)
        }
        if let wake = step.wake {
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, wake - now), execute: work)
        }
    }

    private func show(_ s: NowPlayingSources<Report>.Source) {
        let r = s.info
        playing = s.playing
        rate = r.rate
        if let e = r.elapsed {
            elapsedAnchor = e
            anchorDate = r.anchor
        }
        if r.track.key != track?.key || r.track.bundle != track?.bundle { begin(r.track) } else { track = r.track }
    }

    private func syncArtwork() {
        guard let t = track, let bundle = t.bundle else { return }
        let image = covers[bundle].flatMap { $0.key == t.key ? $0.image : nil }
        if image !== artwork { setArtwork(image) }
    }

    /// Auto-pause paused this app. Now Playing may not say so while a video is its current app.
    func autoPaused(_ bundle: String) {
        sources.held(bundle, now: Self.uptime)
        settle()
    }

    /// Auto-pause is playing it again: it comes back as it was, without a banner.
    func autoResumed(_ bundle: String) {
        sources.resumed(bundle, now: Self.uptime)
        settle()
    }

    private func begin(_ new: Track) {
        let previous = track
        track = new
        generation += 1
        trackStarted = Date().addingTimeInterval(-elapsed())
        liked = likedKeys.contains(new.key)
        if new.bundle != previous?.bundle { appIcon = Self.icon(for: new.bundle) }
        NowPlayingLog.write("track: \(new.appName ?? new.bundle ?? "?") — \(new.title.prefix(40))\(playing ? "" : " (paused)")")
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
                guard let image, self.generation == gen, self.artwork == nil, let track = self.track else { return }
                NowPlayingLog.write("artwork: filled in from \(app.scriptName)")
                if let bundle = track.bundle { self.covers[bundle] = (track.key, nil, image) }
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
                guard let s = await ScriptedPlayers.read() else { sources.reportNothing(); settle(); return }
                applyScripted(s)
            } else if bundle == ScriptedPlayers.App.music.rawValue, let s = await ScriptedPlayers.read(.music), s.title == track?.title {
                if let l = s.liked { liked = l }
            }
        }
    }

    private func applyScripted(_ s: ScriptedPlayers.State) {
        let bundle = s.app.rawValue
        let new = Track(title: s.title, artist: s.artist, album: s.album, duration: s.duration, bundle: bundle,
                        appName: s.app.scriptName, isMusic: true)
        if let l = s.liked { liked = l }
        let isNew = sources.sources[bundle]?.key != new.key
        sources.report(bundle, key: new.key, info: Report(track: new, rate: s.playing ? 1 : 0, elapsed: s.position, anchor: Date()),
                       playing: s.playing, allowed: Self.allowed(bundle, isMusicApp: true), now: Self.uptime)
        settle()
        guard isNew else { return }
        Task {
            var image: NSImage?
            if s.app == .music { image = await ScriptedPlayers.musicArtwork() }
            else if let url = s.artworkURL, let (data, _) = try? await URLSession.shared.data(from: url) { image = NSImage(data: data) }
            guard let image else { return }
            covers[bundle] = (new.key, nil, image)
            syncArtwork()
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
    static func allowed(_ bundle: String, isMusicApp: Bool, album: String? = nil) -> Bool {
        let d = Pref.defaults
        if (d.stringArray(forKey: NowPlayingPrefs.excluded) ?? []).contains(bundle) { return false }
        guard (d.string(forKey: NowPlayingPrefs.sources) ?? "music") == "music" else { return true }
        if isBrowser(bundle) { return isWebMusic(bundle, album: album) }
        return musicApps.contains(bundle) || isMusicApp
    }

    /// A browser, or a site saved as an app from one.
    static func isBrowser(_ bundle: String) -> Bool {
        browsers.contains(bundle) || bundle.hasPrefix("com.apple.WebKit")
            || bundle.hasPrefix("com.apple.Safari.WebApp") || bundle.hasPrefix("com.google.Chrome.app.")
    }

    /// Music in a browser: YouTube Music, Spotify's or Apple Music's web player. Unlike a video, the
    /// page names the song's album.
    static func isWebMusic(_ bundle: String, album: String?) -> Bool {
        isBrowser(bundle) && !(album ?? "").isEmpty
    }

    /// The app macOS's Now Playing is on right now, shown or not, and whether it's playing.
    @ObservationIgnored private var systemSource: (bundle: String, playing: Bool)?

    /// macOS's Now Playing is on another app than the one shown, and it's playing or the shown one isn't.
    private var heardElsewhere: Bool {
        guard let other = systemSource, other.bundle != track?.bundle else { return false }
        return other.playing || !playing
    }

    /// The last app Now Playing reported, shown or not, for "Skip this app".
    private(set) var lastSource: (bundle: String, name: String)?
    @ObservationIgnored private var lastSkipped: String?

    /// Re-reads after "Show from" or the skipped apps change.
    func sourcesChanged() {
        sources.reset()
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
