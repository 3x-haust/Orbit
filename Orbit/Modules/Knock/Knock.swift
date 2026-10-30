import AppKit
import os

/// Knock on the MacBook — on the palm rest, the lid, or the desk beside it — two or three times, and
/// what's set for that runs: anything Hot Corners can do. Only the MacBook is needed: its own motion
/// sensor feels the knocks (see ``KnockSensor``).
@MainActor @Observable
final class Knock {
    static let shared = Knock()

    enum Status: Equatable { case off, listening, unsupported, failed }

    /// How light a knock is still felt. Knocks measure 0.04–0.15g; the Mac at rest stays under 0.03g.
    enum Sensitivity: Int, CaseIterable {
        case high, normal, low
        /// In g above the resting signal.
        var threshold: Double {
            switch self {
            case .high: 0.03
            case .normal: 0.045
            case .low: 0.07
            }
        }
    }

    static let enabledKey = "knock.enabled"
    static let sensitivityKey = "knock.sensitivity"
    static let showKey = "knock.showWhatRan"

    var enabled: Bool { didSet { Pref.defaults.set(enabled, forKey: Self.enabledKey); restart() } }
    var sensitivity: Sensitivity { didSet { Pref.defaults.set(sensitivity.rawValue, forKey: Self.sensitivityKey); configure() } }
    /// A short note of what a knock just ran.
    var showWhatRan: Bool { didSet { Pref.defaults.set(showWhatRan, forKey: Self.showKey) } }
    private(set) var status: Status = .off
    /// Each knock's live strength while the page is open, and the last pattern that ran.
    private(set) var level = 0.0
    private(set) var lastPattern: (count: Int, at: Date)?
    /// Bumped when a pattern's action changes, so the page shows it.
    private(set) var choices = 0
    /// The page is open and wants the live level.
    var metering = false { didSet { engine.metering = metering } }

    private let engine = Engine()
    private var sensor: KnockSensor?
    private var monitors: [Any] = []
    private var wakeObserver: Any?

    private init() {
        let d = Pref.defaults
        enabled = d.bool(forKey: Self.enabledKey)
        sensitivity = Sensitivity(rawValue: d.object(forKey: Self.sensitivityKey) as? Int ?? 1) ?? .normal
        showWhatRan = d.object(forKey: Self.showKey) as? Bool ?? true
    }

    // MARK: What each pattern does

    static func key(_ count: Int) -> String { "knock.\(count)" }

    func target(_ count: Int) -> HotCorners.Target {
        _ = choices
        // Out of the box: two knocks play or pause, three open the Ring.
        let fallback = count == 2 ? HotCorners.Target.command(.mediaPlayPause).raw : count == 3 ? HotCorners.Target.ring.raw : ""
        return HotCorners.Target(Pref.defaults.string(forKey: Self.key(count)) ?? fallback)
    }

    func set(_ t: HotCorners.Target, for count: Int) {
        Pref.defaults.set(t.raw, forKey: Self.key(count))
        choices += 1
        configure()
        if t != .none, !enabled { enabled = true }
    }

    // MARK: Listening

    func start() { restart() }

    private func restart() {
        sensor?.stop()
        sensor = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard enabled else { status = .off; return }
        guard KnockSensor.available else {
            status = .unsupported
            KnockLog.write("no motion sensor on this Mac")
            return
        }
        configure()
        let engine = self.engine
        let s = KnockSensor { x, y, z, t in engine.add(x, y, z, t) }
        guard s.start() else {
            status = .failed
            KnockLog.write("couldn't open the motion sensor")
            return
        }
        sensor = s
        status = .listening
        engine.heardAnything = false
        // Opened but silent: the Mac lists the sensor and never sends from it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.sensor === s, !self.engine.heardAnything else { return }
            self.status = .failed
            KnockLog.write("the motion sensor opened but sent nothing")
        }
        // Typing and clicking shake the Mac too: a knock right around them isn't one.
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { _ in engine.touched() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: events, handler: { e in engine.touched(); return e }) { monitors.append(m) }
        if wakeObserver == nil {
            // The hub forgets it was asked to report while the Mac sleeps.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Knock.shared.restart() }
            }
        }
        KnockLog.write("listening (\(sensitivity))")
    }

    private func configure() {
        engine.configure(threshold: sensitivity.threshold, longest: target(3) == .none ? 2 : 3)
    }

    // MARK: From the sensor's thread

    fileprivate func heard(_ p: KnockDetector.Pattern) {
        let t = target(p.count)
        KnockLog.write("\(p.count) knocks, softest \(String(format: "%.3f", p.strength))g → \(t.raw.isEmpty ? "nothing" : t.raw)")
        lastPattern = (p.count, Date())
        guard t != .none, !Self.screenAsleepOrLocked else { return }
        HotCorners.shared.run(t)
        if showWhatRan { Toast.show(t.title, symbol: "hand.tap", detail: p.count == 2 ? "Two knocks".loc : "Three knocks".loc) }
    }

    fileprivate func metered(_ level: Double) { self.level = level }

    private static var screenAsleepOrLocked: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}

/// The detector and what it needs, used from the sensor's thread; settings and input times come in
/// from the main thread under a lock.
private final class Engine: @unchecked Sendable {
    private struct Shared {
        var threshold = 0.045
        var longest = 3
        /// Keys and clicks of the last couple of seconds.
        var inputs: [TimeInterval] = []
        var metering = false
        var heardAnything = false
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var detector = KnockDetector()
    private var peak = 0.0
    private var lastMeter: TimeInterval = 0

    /// A key or a click just now (any thread).
    func touched() {
        let now = ProcessInfo.processInfo.systemUptime
        shared.withLock { s in
            s.inputs.removeAll { now - $0 > 2 }
            s.inputs.append(now)
        }
    }

    func configure(threshold: Double, longest: Int) {
        shared.withLock { $0.threshold = threshold; $0.longest = longest }
    }

    var metering: Bool {
        get { shared.withLock { $0.metering } }
        set { shared.withLock { $0.metering = newValue } }
    }

    /// A sample has come since listening started.
    var heardAnything: Bool {
        get { shared.withLock { $0.heardAnything } }
        set { shared.withLock { $0.heardAnything = newValue } }
    }

    /// A sample, on the sensor's thread.
    func add(_ x: Double, _ y: Double, _ z: Double, _ t: TimeInterval) {
        let s = shared.withLock { state in
            defer { state.heardAnything = true }
            return state
        }
        if !s.heardAnything { KnockLog.write("motion sensor streaming") }
        detector.threshold = s.threshold
        detector.longest = s.longest
        let pattern = detector.add(x: x, y: y, z: z, at: t)
        // With the page open, every jolt goes in the log: what tuning the sensitivity goes by.
        if s.metering, let jolt = detector.lastJolt {
            detector.clearJolt()
            KnockLog.write("knock \(String(format: "%.3f", jolt.strength))g")
        }
        if s.metering {
            peak = max(peak, detector.level)
            // Twenty times a second is plenty for a meter.
            if t - lastMeter > 0.05 {
                let level = peak
                peak = 0
                lastMeter = t
                DispatchQueue.main.async { MainActor.assumeIsolated { Knock.shared.metered(level) } }
            }
        }
        guard let pattern else { return }
        // Typed or clicked anywhere from just before the first knock to the last: those were keys.
        if s.inputs.contains(where: { $0 > pattern.start - 0.3 && $0 < pattern.end + 0.15 }) {
            KnockLog.write("\(pattern.count) knocks ignored: typing or clicking")
            return
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { Knock.shared.heard(pattern) } }
    }
}

/// ~/Library/Logs/Orbit/knock.log: what was heard and what ran.
enum KnockLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("knock.log")
    }()

    static func write(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
