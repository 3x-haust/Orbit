import Foundation

/// Which app's song Orbit shows — the notch ear, the Home player, the song banner and the widget all
/// read the one picked here.
///
/// Now Playing reports a single app at a time and jumps to whichever made sound last: a YouTube tab,
/// then Music's old paused song, then the tab again. So every app it reported is remembered, and the one
/// shown is picked from the apps the user allows: the one that most recently started playing, else the
/// one already showing. An app that isn't allowed never replaces what's showing, and a switch waits a
/// moment so a handoff's play/pause churn doesn't flash.
///
/// The banner is only for a new song: an allowed app moved to a title it hasn't shown, and kept playing
/// for a second. A paused song turning up, an app taking over, or Music coming back after auto-pause
/// isn't one.
struct NowPlayingSources<Info: Equatable> {
    struct Source: Equatable {
        var bundle: String
        /// Title, artist and album.
        var key: String
        var info: Info
        var playing: Bool
        /// When it last started playing, to pick the newest.
        var startedAt: TimeInterval
        var updatedAt: TimeInterval
        /// When Orbit's auto-pause paused it.
        var heldAt: TimeInterval?
    }

    enum Change: Equatable { case keep, show(Source), clear }

    struct Step: Equatable {
        var change: Change = .keep
        /// A new song to announce.
        var announce: Source?
        /// Call `step` again then.
        var wake: TimeInterval?
    }

    static var switchDelay: TimeInterval { 0.4 }
    /// How long a new song has to keep playing before it's announced.
    static var announceDelay: TimeInterval { 1 }

    private(set) var sources: [String: Source] = [:]
    private(set) var shown: Source?
    /// The app Now Playing reported last, allowed or not.
    private(set) var current: String?
    /// The app Now Playing was on when Orbit started listening.
    private var first: String?
    private var waitingSince: TimeInterval?
    private var pending: (bundle: String, key: String, at: TimeInterval)?
    /// The last song each app showed.
    private var seen: [String: String] = [:]

    /// One Now Playing update.
    mutating func report(_ bundle: String, key: String, info: Info, playing: Bool, allowed: Bool, now: TimeInterval) {
        // Now Playing moved off an app to show a paused one: the app it left isn't what's playing.
        if !playing, let previous = current, previous != bundle, var p = sources[previous], p.playing {
            p.playing = false
            sources[previous] = p
        }
        current = bundle
        if first == nil { first = bundle }
        guard allowed else { return }
        var s = sources[bundle] ?? Source(bundle: bundle, key: key, info: info, playing: false, startedAt: now, updatedAt: now)
        var playing = playing
        // Right after auto-pause, a "playing" can still be the update from before the pause.
        if playing, let held = s.heldAt, now - held < 2 { playing = false }
        if playing, !s.playing || s.key != key { s.startedAt = now }
        if playing { s.heldAt = nil }
        s.key = key
        s.info = info
        s.playing = playing
        s.updatedAt = now
        sources[bundle] = s
    }

    /// Nothing plays anywhere.
    mutating func reportNothing() {
        sources.removeAll()
        current = nil
    }

    mutating func forget(_ bundle: String) { sources[bundle] = nil }

    /// "Show from" changed: start over, without announcing the songs already seen.
    mutating func reset() {
        sources.removeAll()
        current = nil
        first = nil
        shown = nil
        waitingSince = nil
        pending = nil
    }

    /// Auto-pause paused it; Now Playing may not say so while another app is its current one.
    mutating func held(_ bundle: String, now: TimeInterval) {
        guard var s = sources[bundle] else { return }
        s.playing = false
        s.heldAt = now
        sources[bundle] = s
    }

    /// Auto-pause played it again.
    mutating func resumed(_ bundle: String, now: TimeInterval) {
        guard var s = sources[bundle] else { return }
        s.heldAt = nil
        s.playing = true
        s.startedAt = now
        s.updatedAt = now
        sources[bundle] = s
    }

    /// What to show and announce now.
    mutating func step(now: TimeInterval) -> Step {
        var step = Step()
        let target = pick()
        if target != shown {
            // The same app going on (a new song, the time, playing again) shows at once; another app
            // taking over, a pause, or nothing left waits a moment in case it's just a handoff.
            let instant = shown == nil || (target?.bundle == shown?.bundle && (target?.playing == true || shown?.playing == false))
            let since = waitingSince ?? now
            if instant || now >= since + Self.switchDelay {
                waitingSince = nil
                shown = target
                step.change = target.map(Change.show) ?? .clear
                if let t = target, seen[t.bundle] != t.key {
                    if t.playing { pending = (t.bundle, t.key, now + Self.announceDelay) } else { seen[t.bundle] = t.key }
                }
            } else {
                waitingSince = since
                step.wake = since + Self.switchDelay
            }
        } else {
            waitingSince = nil
        }
        if let p = pending {
            if let s = shown, s.bundle == p.bundle, s.key == p.key, s.playing {
                if now >= p.at {
                    pending = nil
                    seen[s.bundle] = s.key
                    step.announce = s
                } else {
                    step.wake = min(step.wake ?? p.at, p.at)
                }
            } else {
                pending = nil // paused, or something else took over, within the second
            }
        }
        return step
    }

    private func pick() -> Source? {
        if let newest = sources.values.filter(\.playing).max(by: { ($0.startedAt, $0.bundle) < ($1.startedAt, $1.bundle) }) {
            return newest
        }
        if let shown, let s = sources[shown.bundle] { return s }
        // Nothing playing and nothing showing: the paused song Now Playing was on from the start. A paused
        // app it jumps to later is an old leftover (Music's last song when a video starts), not news.
        guard let current, current == first else { return nil }
        return sources[current]
    }
}
