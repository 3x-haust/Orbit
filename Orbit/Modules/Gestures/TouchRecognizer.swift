import Foundation

/// The trackpad gestures Orbit can tell apart from raw touches.
enum TrackpadGesture: String, Codable, CaseIterable, Hashable, Sendable {
    case tap3, tap4, tap5
    case swipe3Up, swipe3Down, swipe3Left, swipe3Right
    case swipe4Up, swipe4Down, swipe4Left, swipe4Right
    case tipTapLeft, tipTapRight

    var fingers: Int {
        switch self {
        case .tap3, .swipe3Up, .swipe3Down, .swipe3Left, .swipe3Right: 3
        case .tap4, .swipe4Up, .swipe4Down, .swipe4Left, .swipe4Right: 4
        case .tap5: 5
        case .tipTapLeft, .tipTapRight: 2
        }
    }

    enum Direction: Sendable { case up, down, left, right }

    var direction: Direction? {
        switch self {
        case .swipe3Up, .swipe4Up: .up
        case .swipe3Down, .swipe4Down: .down
        case .swipe3Left, .swipe4Left, .tipTapLeft: .left
        case .swipe3Right, .swipe4Right, .tipTapRight: .right
        default: nil
        }
    }

    var isTap: Bool { self == .tap3 || self == .tap4 || self == .tap5 }
    var isTipTap: Bool { self == .tipTapLeft || self == .tipTapRight }

    static func swipe(fingers: Int, _ d: Direction) -> TrackpadGesture? {
        switch (fingers, d) {
        case (3, .up): .swipe3Up
        case (3, .down): .swipe3Down
        case (3, .left): .swipe3Left
        case (3, .right): .swipe3Right
        case (4, .up): .swipe4Up
        case (4, .down): .swipe4Down
        case (4, .left): .swipe4Left
        case (4, .right): .swipe4Right
        default: nil
        }
    }
}

/// One finger on the trackpad, in millimetres from the pad's bottom-left corner.
struct TouchPoint: Equatable, Sendable {
    var id: Int
    var x: Double
    var y: Double
}

/// Everything on the pad at one moment. `pressed` is the pad physically clicked down: a three-finger
/// click is a click, not a tap.
struct TouchFrame: Equatable, Sendable {
    var time: Double
    var touches: [TouchPoint]
    var pressed = false
}

/// Turns a stream of touch frames into gestures. Pure: no device, no clock, no AppKit, so it can be
/// fed recorded or made-up frames (see `selfTest`).
///
/// Only three or more fingers, or a second finger tapped beside a resting one, ever count — so
/// pointing, clicking, two-finger scrolling and pinching never fire anything. Each time the fingers
/// come down counts for at most one gesture.
struct TouchRecognizer: Sendable {
    /// Taps: the whole touch shorter than this, every finger staying put, all of them landing together.
    static let tapMaxDuration = 0.28
    static let tapMaxTravel = 3.5        // mm
    static let tapLandingSpread = 0.14   // s between the first and the last finger landing
    /// Swipes: this far in one direction, mostly straight, every finger going the same way.
    static let swipeDistance = 16.0      // mm
    static let swipeStraightness = 1.7   // main axis over cross axis
    static let swipeAgreement = 0.6      // each finger's share along the swipe
    static let swipeSettle = 0.06        // s after the last finger lands before travel counts
    /// TipTap: the resting finger stayed down this long and still, the other one lands and lifts quickly.
    static let tipRestBefore = 0.18
    static let tipMaxDuration = 0.25
    static let tipMaxTravel = 3.0        // mm

    private struct Track {
        let start: TouchPoint
        let landed: Double
        var last: TouchPoint
        var travel: Double { hypot(last.x - start.x, last.y - start.y) }
    }

    private var tracks: [Int: Track] = [:]
    /// The current touch, from the first finger down to the last one up.
    private var sessionStart = 0.0
    private var maxFingers = 0
    private var firstLanding = 0.0
    private var lastLanding = 0.0
    private var anyMoved = false
    private var clicked = false
    private var fired = false
    /// Where every finger was when the count last changed, for swipes.
    private var swipeBase: [Int: TouchPoint] = [:]
    private var swipeBaseTime = 0.0
    private var swipeCount = 0
    /// A second finger that came down beside a resting one.
    private var tip: (id: Int, rest: Int, landed: Double)?

    init() {}

    /// Feeds one frame; returns the gesture it completes, if any.
    mutating func feed(_ frame: TouchFrame) -> TrackpadGesture? {
        let now = frame.time
        let ids = Set(frame.touches.map(\.id))
        var result: TrackpadGesture?

        if tracks.isEmpty, !frame.touches.isEmpty { beginSession(at: now) }
        if frame.pressed { clicked = true }

        // Lifted fingers.
        for (id, track) in tracks where !ids.contains(id) {
            if let tip, tip.id == id {
                result = result ?? tipTapEnded(track, at: now)
                self.tip = nil
            }
            if tip?.rest == id { tip = nil }
            tracks[id] = nil
        }

        // Landed and moved fingers.
        let before = tracks.count
        for t in frame.touches {
            if var track = tracks[t.id] {
                track.last = t
                tracks[t.id] = track
                if track.travel > Self.tapMaxTravel { anyMoved = true }
            } else {
                tracks[t.id] = Track(start: t, landed: now, last: t)
                if before == 0 || firstLanding == 0 { firstLanding = now }
                lastLanding = now
                tipLanded(t, at: now)
            }
        }
        maxFingers = max(maxFingers, tracks.count)

        if tracks.count != swipeCount {
            swipeCount = tracks.count
            swipeBase = tracks.mapValues(\.last)
            swipeBaseTime = now
        }

        if result == nil, !fired, tracks.count == 3 || tracks.count == 4 {
            result = swipe(at: now)
        }

        if tracks.isEmpty {
            if result == nil, !fired { result = tapEnded(at: now) }
            reset()
        }
        if result != nil { fired = true }
        return result
    }

    private mutating func beginSession(at now: Double) {
        reset()
        sessionStart = now
        firstLanding = now
    }

    private mutating func reset() {
        tracks = [:]
        maxFingers = 0
        firstLanding = 0
        lastLanding = 0
        anyMoved = false
        clicked = false
        fired = false
        swipeBase = [:]
        swipeCount = 0
        tip = nil
    }

    // MARK: Taps

    private func tapEnded(at now: Double) -> TrackpadGesture? {
        guard (3...5).contains(maxFingers), !anyMoved, !clicked,
              now - sessionStart <= Self.tapMaxDuration,
              lastLanding - firstLanding <= Self.tapLandingSpread else { return nil }
        switch maxFingers {
        case 3: return .tap3
        case 4: return .tap4
        default: return .tap5
        }
    }

    // MARK: Swipes

    private func swipe(at now: Double) -> TrackpadGesture? {
        // Fingers land one after another; a four-finger swipe passes through three for a moment.
        guard now - swipeBaseTime >= Self.swipeSettle, !clicked else { return nil }
        var moves: [(dx: Double, dy: Double)] = []
        for (id, track) in tracks {
            guard let base = swipeBase[id] else { return nil }
            moves.append((track.last.x - base.x, track.last.y - base.y))
        }
        let n = Double(moves.count)
        let dx = moves.map(\.dx).reduce(0, +) / n
        let dy = moves.map(\.dy).reduce(0, +) / n
        let horizontal = abs(dx) >= abs(dy)
        let main = horizontal ? abs(dx) : abs(dy)
        let cross = horizontal ? abs(dy) : abs(dx)
        guard main >= Self.swipeDistance, main >= cross * Self.swipeStraightness else { return nil }
        // Every finger has to go the same way: a pinch or a spread moves them apart.
        let ux = horizontal ? (dx > 0 ? 1.0 : -1.0) : 0, uy = horizontal ? 0 : (dy > 0 ? 1.0 : -1.0)
        for m in moves where m.dx * ux + m.dy * uy < main * Self.swipeAgreement { return nil }
        let d: TrackpadGesture.Direction = horizontal ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
        return .swipe(fingers: tracks.count, d)
    }

    // MARK: TipTap

    private mutating func tipLanded(_ t: TouchPoint, at now: Double) {
        // Exactly one other finger, resting: down a while and not moving.
        guard tracks.count == 2,
              let rest = tracks.values.first(where: { $0.start.id != t.id }),
              now - rest.landed >= Self.tipRestBefore,
              rest.travel <= Self.tipMaxTravel * 2 else { tip = nil; return }
        tip = (t.id, rest.start.id, now)
    }

    private func tipTapEnded(_ track: Track, at now: Double) -> TrackpadGesture? {
        guard let tip, maxFingers == 2, !clicked,
              now - tip.landed <= Self.tipMaxDuration,
              track.travel <= Self.tipMaxTravel,
              let rest = tracks[tip.rest],
              hypot(rest.last.x - rest.start.x, rest.last.y - rest.start.y) <= Self.tipMaxTravel * 2 else { return nil }
        return track.start.x < rest.last.x ? .tipTapLeft : .tipTapRight
    }
}

#if DEBUG
extension TouchRecognizer {
    /// Made-up touches for every gesture, and for the things that must never count. Returns one line
    /// per case; a line starting with "FAIL" is a regression.
    static func selfTest() -> [String] {
        typealias P = (x: Double, y: Double)
        let hz = 1.0 / 120

        /// Fingers that land at `starts`, move to `ends` over `duration`, then lift.
        func stroke(_ starts: [P], _ ends: [P], duration: Double, stagger: Double = 0.01, pressed: Bool = false, hold: Double = 0) -> [TouchFrame] {
            var frames: [TouchFrame] = []
            var t = 0.0
            let landEnd = stagger * Double(starts.count - 1)
            while t <= landEnd + duration + hold + 1e-9 {
                var touches: [TouchPoint] = []
                for (i, s) in starts.enumerated() {
                    let landed = stagger * Double(i)
                    guard t >= landed else { continue }
                    let k = min(1, max(0, (t - landEnd) / max(duration, hz)))
                    let e = ends[i]
                    touches.append(TouchPoint(id: i + 1, x: s.x + (e.x - s.x) * k, y: s.y + (e.y - s.y) * k))
                }
                frames.append(TouchFrame(time: t, touches: touches, pressed: pressed))
                t += hz
            }
            frames.append(TouchFrame(time: t + hz, touches: []))
            return frames
        }
        func row(_ n: Int, y: Double = 50) -> [P] { (0..<n).map { (40 + Double($0) * 18, y + Double($0 % 2) * 4) } }
        func moved(_ ps: [P], _ dx: Double, _ dy: Double) -> [P] { ps.map { ($0.x + dx, $0.y + dy) } }

        /// One finger resting, another tapping beside it.
        func tipTap(side: Double, restMove: Double = 0, tapDuration: Double = 0.1, restFor: Double = 0.3) -> [TouchFrame] {
            var frames: [TouchFrame] = []
            var t = 0.0
            let rest = TouchPoint(id: 1, x: 80, y: 50)
            while t < restFor { frames.append(TouchFrame(time: t, touches: [rest])); t += hz }
            let tapStart = t
            while t < tapStart + tapDuration {
                let r = TouchPoint(id: 1, x: 80 + restMove * (t - tapStart) / tapDuration, y: 50)
                frames.append(TouchFrame(time: t, touches: [r, TouchPoint(id: 2, x: 80 + side, y: 52)]))
                t += hz
            }
            frames.append(TouchFrame(time: t, touches: [TouchPoint(id: 1, x: 80 + restMove, y: 50)]))
            t += 0.2
            frames.append(TouchFrame(time: t, touches: []))
            return frames
        }

        let cases: [(String, [TouchFrame], TrackpadGesture?)] = [
            ("three-finger tap", stroke(row(3), row(3), duration: 0.08), .tap3),
            ("four-finger tap", stroke(row(4), row(4), duration: 0.08), .tap4),
            ("five-finger tap", stroke(row(5), row(5), duration: 0.08, stagger: 0.02), .tap5),
            ("three-finger swipe up", stroke(row(3), moved(row(3), 0, 30), duration: 0.2), .swipe3Up),
            ("three-finger swipe down", stroke(row(3, y: 70), moved(row(3, y: 70), 0, -30), duration: 0.2), .swipe3Down),
            ("three-finger swipe left", stroke(row(3), moved(row(3), -30, 2), duration: 0.2), .swipe3Left),
            ("three-finger swipe right", stroke(row(3), moved(row(3), 30, -2), duration: 0.2), .swipe3Right),
            ("four-finger swipe up", stroke(row(4), moved(row(4), 0, 28), duration: 0.25), .swipe4Up),
            ("four-finger swipe down", stroke(row(4, y: 70), moved(row(4, y: 70), 0, -28), duration: 0.25), .swipe4Down),
            ("four-finger swipe left", stroke(row(4), moved(row(4), -28, 0), duration: 0.25), .swipe4Left),
            ("four-finger swipe right", stroke(row(4), moved(row(4), 28, 0), duration: 0.25), .swipe4Right),
            ("tiptap left", tipTap(side: -25), .tipTapLeft),
            ("tiptap right", tipTap(side: 25), .tipTapRight),
            // Never:
            ("one-finger pointing", stroke(row(1), moved(row(1), 40, 20), duration: 0.4), nil),
            ("one-finger tap", stroke(row(1), row(1), duration: 0.08), nil),
            ("two-finger tap (right click)", stroke(row(2), row(2), duration: 0.08), nil),
            ("two-finger scroll", stroke(row(2), moved(row(2), 0, -40), duration: 0.4), nil),
            ("two-finger scroll sideways", stroke(row(2), moved(row(2), 40, 0), duration: 0.4), nil),
            ("pinch with two fingers", stroke([(40, 50), (90, 50)], [(60, 50), (70, 50)], duration: 0.3), nil),
            ("three-finger pinch", stroke([(30, 40), (90, 40), (60, 90)], [(55, 55), (65, 55), (60, 65)], duration: 0.3), nil),
            ("four-finger spread", stroke([(55, 55), (65, 55), (55, 65), (65, 65)], [(20, 20), (100, 20), (20, 100), (100, 100)], duration: 0.3), nil),
            ("three-finger click", stroke(row(3), row(3), duration: 0.08, pressed: true), nil),
            ("slow three-finger rest", stroke(row(3), row(3), duration: 0.6), nil),
            ("three-finger drag diagonal", stroke(row(3), moved(row(3), 20, 20), duration: 0.3), nil),
            ("short three-finger nudge", stroke(row(3), moved(row(3), 8, 0), duration: 0.15), nil),
            ("tiptap with moving rest finger", tipTap(side: 25, restMove: 15), nil),
            ("slow second finger", tipTap(side: 25, tapDuration: 0.5), nil),
            ("both fingers land together", stroke(row(2), row(2), duration: 0.1, stagger: 0.02), nil),
        ]

        var lines: [String] = []
        for (name, frames, expected) in cases {
            var r = TouchRecognizer()
            let got = frames.compactMap { r.feed($0) }
            let ok = expected.map { got == [$0] } ?? got.isEmpty
            lines.append("\(ok ? "ok  " : "FAIL") \(name): expected \(expected?.rawValue ?? "nothing"), got \(got.isEmpty ? "nothing" : got.map(\.rawValue).joined(separator: ","))")
        }
        return lines
    }
}
#endif
