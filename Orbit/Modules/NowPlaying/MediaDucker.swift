import AppKit

/// Pauses the music when something else starts playing — a YouTube video, a movie, any app's sound —
/// and plays it again once that stops, like an iPhone does. Only music Orbit paused itself is resumed,
/// and not if the user played, paused or changed it in between.
///
/// Two signals: Now Playing (videos in browsers and players publish themselves there, with a play
/// state), and Core Audio's per-process "running output" for apps that don't. A browser keeps its output
/// open for a paused video, so a browser only counts through Now Playing (or a level Orbit actually hears).
@MainActor
final class MediaDucker {
    static let shared = MediaDucker()

    private struct Music { var bundle: String; var key: String; var playing: Bool }
    /// Music Orbit paused, waiting for the other sound to stop.
    private struct Hold { var bundle: String; var key: String; var at: Date; var cause: String }

    private var music: Music?
    private var hold: Hold?
    /// Now Playing's current source, when it isn't a music app.
    private var other: (bundle: String, playing: Bool)?
    /// Apps with an output running right now (Core Audio), and since when.
    private var sounding: [String: Date] = [:]
    /// Apps whose output was already open when the music started: a stream left open isn't a new video.
    private var baseline: Set<String> = []
    private var quietSince: Date?
    private var timer: Timer?
    private var owners: [pid_t: String] = [:]
    private var categories: [String: String] = [:]
    private var lastCause: String?

    /// Sound has to last this long before it pauses the music (notification sounds don't), and the
    /// other app has to stay quiet this long before the music comes back.
    private let settle: TimeInterval = 1.5

    var enabled: Bool { NowPlayingPrefs.autoPauseOn }

    static let callApps: Set<String> = [
        "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
        "com.tinyspeck.slackmacgap", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.kakao.KakaoTalkMac",
        "com.skype.skype", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop",
        "com.google.meet", "com.apple.TelephonyUtilities",
    ]

    // MARK: Inputs

    /// Every Now Playing update, before "Show from" filters it.
    func observe(bundle: String?, isMusicApp: Bool, key: String?, playing: Bool) {
        guard enabled else { reset(); return }
        guard let bundle else {
            other = nil // nothing is playing anywhere
            evaluate()
            return
        }
        if Self.isMusic(bundle, isMusicApp: isMusicApp) {
            other = nil
            if let key { sawMusic(bundle: bundle, key: key, playing: playing) }
        } else {
            other = (bundle, playing)
        }
        evaluate()
    }

    private func sawMusic(bundle: String, key: String, playing: Bool) {
        if let h = hold {
            if h.bundle == bundle, h.key != key {
                log("\(bundle) moved to another song while paused — leaving it paused"); hold = nil
            } else if playing, Date().timeIntervalSince(h.at) > 2 {
                log("\(bundle) was played again by hand — not touching it"); hold = nil
            }
        }
        if playing, music?.playing != true || music?.bundle != bundle {
            pollAudio(HAL.playingPIDs())
            baseline = Set(sounding.keys)
        }
        music = Music(bundle: bundle, key: key, playing: playing && hold == nil)
    }

    /// Play, pause or skip from Orbit — the user is in charge now.
    func userActed() {
        guard hold != nil else { return }
        log("play/pause from Orbit — dropping the auto-pause")
        hold = nil
        quietSince = nil
        updateTimer()
    }

    func reset() {
        hold = nil
        music = nil
        other = nil
        quietSince = nil
        sounding.removeAll()
        updateTimer()
    }

    // MARK: Deciding

    private func evaluate() {
        guard enabled else { return }
        if let h = hold, NSRunningApplication.runningApplications(withBundleIdentifier: h.bundle).isEmpty {
            log("\(h.bundle) quit — nothing to resume"); hold = nil
        }
        if let cause = activity() {
            quietSince = nil
            if hold == nil, let m = music, m.playing { pause(m, for: cause) }
        } else if let h = hold {
            let since = quietSince ?? Date()
            quietSince = since
            if Date().timeIntervalSince(since) >= settle { resume(h) }
        }
        updateTimer()
    }

    /// The app (other than the music) making sound right now, if any.
    private func activity() -> String? {
        if let o = other, o.playing, counts(o.bundle) {
            note(o.bundle, "Now Playing")
            return o.bundle
        }
        let now = Date()
        for (bundle, since) in sounding.sorted(by: { $0.value < $1.value }) where now.timeIntervalSince(since) >= settle {
            if let o = other, o.bundle == bundle, !o.playing { continue } // paused in its own controls
            guard !baseline.contains(bundle), counts(bundle), soundMeansMedia(bundle) else { continue }
            note(bundle, "sound")
            return bundle
        }
        lastCause = nil
        return nil
    }

    private func counts(_ bundle: String) -> Bool {
        if bundle == Bundle.main.bundleIdentifier || bundle == music?.bundle || Self.musicApps.contains(bundle) { return false }
        if (Pref.defaults.stringArray(forKey: NowPlayingPrefs.autoPauseExcluded) ?? []).contains(bundle) { return false }
        if Self.callApps.contains(bundle), !Pref.defaults.bool(forKey: NowPlayingPrefs.autoPauseCalls) { return false }
        return true
    }

    /// An open output alone doesn't mean a video: browsers keep one for a paused tab and a terminal keeps
    /// one after a bell. Without Now Playing, it counts for video players, games and calls — or for any
    /// app whose sound Orbit actually hears through the mixer.
    private func soundMeansMedia(_ bundle: String) -> Bool {
        if AudioMixer.shared.isAudible(bundle) { return true }
        if Self.isBrowser(bundle) { return false }
        if Self.callApps.contains(bundle) { return true }
        let category = categories[bundle] ?? {
            let c = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String } ?? ""
            categories[bundle] = c
            return c
        }()
        return category == "public.app-category.video" || category == "public.app-category.entertainment"
            || category == "public.app-category.sports" || category.hasSuffix("games")
    }

    private func note(_ bundle: String, _ via: String) {
        guard lastCause != bundle else { return }
        lastCause = bundle
        log("\(bundle) is playing (\(via))")
    }

    private func pause(_ m: Music, for cause: String) {
        // Now Playing only follows one app; once the video took over it, check the music is really still going.
        if other != nil, sounding[m.bundle] == nil {
            log("\(m.bundle) looks paused already — not pausing it")
            music?.playing = false
            return
        }
        hold = Hold(bundle: m.bundle, key: m.key, at: Date(), cause: cause)
        music?.playing = false
        log("pausing \(m.bundle) because \(cause) started")
        NowPlaying.shared.autoPaused(m.bundle)
        let isTarget = other == nil
        Task { await send(play: false, to: m.bundle, isTarget: isTarget) }
    }

    private func resume(_ h: Hold) {
        hold = nil
        quietSince = nil
        let isTarget = other == nil
        Task {
            // With scripting, check nothing changed behind Now Playing's back.
            if let app = ScriptedPlayers.app(for: h.bundle), await scriptable(app), let s = await ScriptedPlayers.read(app) {
                if s.playing { log("\(h.bundle) is already playing — leaving it"); return }
                if !h.key.hasPrefix(s.title + "\u{1}") {
                    log("\(h.bundle) is on another song now — leaving it paused"); return
                }
            }
            log("\(h.cause) stopped — resuming \(h.bundle)")
            NowPlaying.shared.autoResumed(h.bundle)
            await send(play: true, to: h.bundle, isTarget: isTarget)
        }
    }

    /// AppleScript for Music and Spotify when allowed; otherwise Now Playing, aimed at the music app
    /// (or the plain command when the music app is what Now Playing controls anyway).
    private func send(play: Bool, to bundle: String, isTarget: Bool) async {
        if let app = ScriptedPlayers.app(for: bundle), await scriptable(app),
           await ScriptedPlayers.send(play ? .play : .pause, to: app) {
            log("  sent \(play ? "play" : "pause") by AppleScript")
            return
        }
        NowPlaying.shared.send(play ? .play : .pause, to: isTarget ? nil : bundle)
        log("  sent \(play ? "play" : "pause") through Now Playing\(isTarget ? "" : " to \(bundle)")")
    }

    private func scriptable(_ app: ScriptedPlayers.App) async -> Bool {
        guard ScriptedPlayers.enabled else { return false }
        return await ScriptedPlayers.permission(app, ask: false) == .allowed
    }

    // MARK: Core Audio

    private func updateTimer() {
        let needed = enabled && (music?.playing == true || hold != nil)
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 0.2
        } else if !needed, let t = timer {
            t.invalidate()
            timer = nil
            sounding.removeAll()
        }
    }

    private var polling = false

    /// Core Audio is asked off the main thread (each read is a round trip to coreaudiod); the
    /// answer comes back here.
    private func tick() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let playing = HAL.playingPIDs()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let ducker = MediaDucker.shared
                    ducker.polling = false
                    guard ducker.timer != nil else { return }
                    ducker.pollAudio(playing)
                    ducker.evaluate()
                }
            }
        }
    }

    private func pollAudio(_ playing: [pid_t]) {
        // Owners are cached per PID; forget the ones that stopped playing so a reused PID is looked up again.
        let alive = Set(playing)
        owners = owners.filter { alive.contains($0.key) }
        var running = Set<String>()
        for pid in playing {
            if let bundle = owner(pid) { running.insert(bundle) }
        }
        let now = Date()
        for b in running where sounding[b] == nil { sounding[b] = now }
        for b in sounding.keys where !running.contains(b) { sounding[b] = nil }
        baseline.formIntersection(running)
    }

    private func owner(_ pid: pid_t) -> String? {
        if let b = owners[pid] { return b.isEmpty ? nil : b }
        let b = AudioOwner.app(for: pid)?.bundleIdentifier ?? ""
        owners[pid] = b
        return b.isEmpty ? nil : b
    }

    // MARK: Helpers

    private static var musicApps: Set<String> { NowPlaying.musicApps }

    private static func isBrowser(_ bundle: String) -> Bool {
        NowPlaying.browsers.contains(bundle) || bundle.hasPrefix("com.apple.WebKit")
            || bundle.hasPrefix("com.apple.Safari.WebApp") || bundle.hasPrefix("com.google.Chrome.app.")
    }

    private static func isMusic(_ bundle: String, isMusicApp: Bool) -> Bool {
        !isBrowser(bundle) && (musicApps.contains(bundle) || isMusicApp)
    }

    private func log(_ message: String) { NowPlayingLog.write("auto-pause: \(message)") }
}
