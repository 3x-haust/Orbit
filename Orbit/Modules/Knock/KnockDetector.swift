import Foundation

/// Turns the accelerometer's stream into knocks: two or three sudden jolts in a quick, even beat.
/// A MacBook's body rings for half a second or more after a knock, so a knock is told by how
/// suddenly it rises over what was already there, not by how fast it dies away. A lone knock,
/// drumming, an uneven beat, or anything while the Mac itself is moving never counts.
///
/// Plain arithmetic per sample, on the sensor's own thread.
struct KnockDetector {
    /// Two or three knocks, finished.
    struct Pattern: Equatable {
        var count: Int
        var start: TimeInterval
        var end: TimeInterval
        /// The softest knock in it, in g.
        var strength: Double
    }

    /// How hard a knock has to be, in g above the resting signal.
    var threshold = 0.045
    /// The most knocks anything is set for; more than that is drumming, and nothing runs.
    var longest = 3

    /// Knocks closer than this are one knock (its rise and first swings).
    static let minGap: TimeInterval = 0.11
    /// Knocks further apart than this aren't one pattern. People knock 0.12–0.25s apart on their lap
    /// or a desk, and slower, up to 0.4s, on the floor.
    static let maxGap: TimeInterval = 0.5
    /// A knock this much later than the beat so far starts a pattern of its own: two doubles in a row.
    static let newBeat = 1.7
    /// After the last knock: how long to wait for another before the pattern is over. Even a third
    /// knock waits it out: a fourth would make it drumming.
    static let settle: TimeInterval = maxGap
    /// How long after a knock starts its peak is looked for.
    static let rise: TimeInterval = 0.04
    /// A new knock has to rise this many times over the ringing of the last.
    static let over = 1.6
    /// How fast the ringing a new knock has to beat dies down (its half-life, roughly).
    static let ringing: TimeInterval = 0.15
    /// What the ringing is compared with: the level from this long ago, before the rise began.
    static let lookBack: TimeInterval = 0.03
    /// A move of the Mac itself (lifted, tilted, the lid swung): how far gravity drifts, in g. A firm
    /// knock rocks the Mac a little too, so it takes more than that.
    static let moving = 0.1
    /// How long after a move knocks aren't believed.
    static let movingQuiet: TimeInterval = 0.8

    /// The last sample's distance from rest, for a live meter.
    private(set) var level = 0.0
    /// The last knock that was felt, alone or in a pattern: its peak, for the log.
    private(set) var lastJolt: (strength: Double, knock: Bool)?

    private var gravity: (x: Double, y: Double, z: Double)?
    /// Where the Mac points, over half a second (a knock's ringing averages out) and over a few seconds.
    private var pose = (x: 0.0, y: 0.0, z: 0.0)
    private var slowGravity = (x: 0.0, y: 0.0, z: 0.0)
    /// The everyday background (a fan, a desk on a train): knocks have to stand out from it.
    private var floor = 0.004
    private var quietUntil: TimeInterval = 0
    /// The ringing: a peak that dies down slowly.
    private var envelope = 0.0
    private var lastTime: TimeInterval?
    /// Recent envelope levels, for what it was just before a rise.
    private var history: [(time: TimeInterval, level: Double)] = []

    /// A knock whose peak is being looked for: when it started and its peak so far.
    private var jolt: (start: TimeInterval, peak: Double)?
    private var knocks: [(time: TimeInterval, strength: Double)] = []

    /// One sample in g. Returns a pattern when one has just finished.
    mutating func add(x: Double, y: Double, z: Double, at t: TimeInterval) -> Pattern? {
        guard var g = gravity else {
            gravity = (x, y, z)
            pose = (x, y, z)
            slowGravity = (x, y, z)
            lastTime = t
            return nil
        }
        // Gravity follows slowly, and a single jolt can only nudge it: knocks don't read as moves.
        func follow(_ v: Double, _ rest: Double, _ k: Double) -> Double { rest + k * min(max(v - rest, -0.1), 0.1) }
        g = (follow(x, g.x, 0.02), follow(y, g.y, 0.02), follow(z, g.z, 0.02))
        gravity = g
        func ease(_ v: Double, _ rest: Double, _ k: Double) -> Double { rest + k * (v - rest) }
        pose = (ease(x, pose.x, 0.005), ease(y, pose.y, 0.005), ease(z, pose.z, 0.005))
        slowGravity = (ease(x, slowGravity.x, 0.0006), ease(y, slowGravity.y, 0.0006), ease(z, slowGravity.z, 0.0006))

        let d = Self.length(x - g.x, y - g.y, z - g.z)
        level = d
        let dt = max(0, t - (lastTime ?? t))
        lastTime = t
        envelope = max(d, envelope * exp(-dt / Self.ringing))
        history.append((t, envelope))
        if let first = history.first, t - first.time > Self.lookBack * 2 { history.removeFirst(history.count / 2) }
        let before = history.last(where: { t - $0.time >= Self.lookBack })?.level ?? 0

        if Self.length(pose.x - slowGravity.x, pose.y - slowGravity.y, pose.z - slowGravity.z) > Self.moving {
            quietUntil = t + Self.movingQuiet
            jolt = nil
            knocks.removeAll()
        }
        let bar = max(threshold, floor * 8)
        if d < bar { floor += 0.002 * (min(d, floor * 3) - floor) }

        if var j = jolt {
            j.peak = max(j.peak, d)
            jolt = j
            if t - j.start >= Self.rise {
                jolt = nil
                lastJolt = (j.peak, true)
                var done: Pattern?
                if let previous = knocks.last {
                    let gap = j.start - previous.time
                    let beat = knocks.count >= 2 ? previous.time - knocks[knocks.count - 2].time : nil
                    if gap > Self.maxGap {
                        knocks.removeAll()
                    } else if let beat, gap > beat * Self.newBeat {
                        if (2...longest).contains(knocks.count) { done = pattern() }
                        knocks.removeAll()
                    }
                }
                knocks.append((j.start, j.peak))
                if let done { return done }
            }
        } else if d > bar, d > before * Self.over, t >= quietUntil,
                  knocks.last.map({ t - $0.time >= Self.minGap }) ?? true {
            jolt = (t, d)
        }
        return finish(at: t)
    }

    mutating func clearJolt() { lastJolt = nil }

    private mutating func finish(at t: TimeInterval) -> Pattern? {
        guard let lastKnock = knocks.last, jolt == nil, t - lastKnock.time > Self.settle else { return nil }
        defer { knocks.removeAll() }
        return (2...longest).contains(knocks.count) ? pattern() : nil
    }

    private func pattern() -> Pattern? {
        guard let first = knocks.first, let lastKnock = knocks.last else { return nil }
        // Knocks in a pattern come in a steady beat: one gap more than twice another is two things
        // happening, not a knock pattern.
        let gaps = zip(knocks, knocks.dropFirst()).map { $1.time - $0.time }
        if let short = gaps.min(), let long = gaps.max(), long > short * 2.2 { return nil }
        return Pattern(count: knocks.count, start: first.time, end: lastKnock.time, strength: knocks.map(\.strength).min() ?? 0)
    }

    private static func length(_ x: Double, _ y: Double, _ z: Double) -> Double { (x * x + y * y + z * z).squareRoot() }
}
