import AppKit

/// What starts a gesture rule.
enum GestureTrigger: Codable, Hashable, Sendable {
    case trackpad(TrackpadGesture)
    /// A mouse button by its CGEvent number (3 is the fourth button), and the modifiers held with it.
    case mouse(button: Int, mods: KeyMods)
    case keys(KeyCombo)
    /// The same modifier pressed and let go twice, alone.
    case doubleTap(Modifier)

    enum Modifier: String, Codable, CaseIterable, Sendable {
        case command, option, control, shift
        var symbol: String {
            switch self {
            case .command: "⌘"
            case .option: "⌥"
            case .control: "⌃"
            case .shift: "⇧"
            }
        }
    }

    enum Kind: String, CaseIterable, Sendable { case trackpad, mouse, keyboard }

    var kind: Kind {
        switch self {
        case .trackpad: .trackpad
        case .mouse: .mouse
        case .keys, .doubleTap: .keyboard
        }
    }

    @MainActor var title: String {
        switch self {
        case .trackpad(let g): Self.title(g)
        case .mouse(let button, let mods): mods.symbols + "Button %ld".loc(button + 1)
        case .keys(let c): c.label
        case .doubleTap(let m): "Double %@".loc(m.symbol)
        }
    }

    static func title(_ g: TrackpadGesture) -> String {
        switch g {
        case .tap3: "Three-finger tap".loc
        case .tap4: "Four-finger tap".loc
        case .tap5: "Five-finger tap".loc
        case .swipe3Up: "Three-finger swipe up".loc
        case .swipe3Down: "Three-finger swipe down".loc
        case .swipe3Left: "Three-finger swipe left".loc
        case .swipe3Right: "Three-finger swipe right".loc
        case .swipe4Up: "Four-finger swipe up".loc
        case .swipe4Down: "Four-finger swipe down".loc
        case .swipe4Left: "Four-finger swipe left".loc
        case .swipe4Right: "Four-finger swipe right".loc
        case .tipTapLeft: "TipTap left".loc
        case .tipTapRight: "TipTap right".loc
        }
    }

    /// For the log. Keyboard rules stay anonymous: which keys they use is nobody's business there.
    var logName: String {
        switch self {
        case .trackpad(let g): "trackpad.\(g.rawValue)"
        case .mouse(let button, _): "mouse.button\(button + 1)"
        case .keys: "keys"
        case .doubleTap(let m): "double.\(m.rawValue)"
        }
    }
}

/// One rule: this trigger runs that action, in every app or only in some.
struct GestureRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var trigger: GestureTrigger
    var action: GestureAction = .none
    /// Bundle IDs; empty means every app.
    var apps: [String] = []
    var enabled = true
}

/// The rules as the event threads see them: a lock, no main thread. The taps ask it whether an event
/// is Orbit's before deciding to swallow it.
final class GestureTable: @unchecked Sendable {
    enum Match { case record, rule(GestureRule) }

    private let lock = NSLock()
    private var rules: [GestureRule] = []
    private var active = false
    private var front: String?
    private var recording: GestureTrigger.Kind?

    func update(rules: [GestureRule], active: Bool) { lock.withLock { self.rules = rules; self.active = active } }
    func setFront(_ id: String?) { lock.withLock { front = id } }
    func setRecording(_ kind: GestureTrigger.Kind?) { lock.withLock { recording = kind } }
    var isRecording: GestureTrigger.Kind? { lock.withLock { recording } }

    /// A rule for this app beats one for every app.
    func match(_ t: GestureTrigger) -> Match? {
        lock.withLock {
            if recording == t.kind { return .record }
            guard active else { return nil }
            let candidates = rules.filter { $0.enabled && $0.trigger == t && $0.action != .none }
            if let front, let own = candidates.first(where: { $0.apps.contains(front) }) { return .rule(own) }
            return candidates.first(where: { $0.apps.isEmpty }).map { .rule($0) }
        }
    }

    /// Any rule that could ever use this kind of trigger (or one is being recorded): the taps stay off otherwise.
    func wants(_ kind: GestureTrigger.Kind) -> Bool {
        lock.withLock { recording == kind || (active && rules.contains { $0.enabled && $0.trigger.kind == kind && $0.action != .none }) }
    }

    func wantsDoubleTap() -> Bool {
        lock.withLock {
            recording == .keyboard || (active && rules.contains {
                guard $0.enabled, $0.action != .none, case .doubleTap = $0.trigger else { return false }
                return true
            })
        }
    }
}

/// BetterTouchTool's job: trackpad gestures, mouse buttons and keys that run anything, everywhere
/// or only in the apps you pick.
@MainActor @Observable
final class Gestures {
    static let shared = Gestures()

    static let enabledKey = "gestures.enabled"
    static let rulesKey = "gestures.rules"
    static let showKey = "gestures.showWhatRan"

    var enabled: Bool { didSet { Pref.defaults.set(enabled, forKey: Self.enabledKey); apply() } }
    var showWhatRan: Bool { didSet { Pref.defaults.set(showWhatRan, forKey: Self.showKey) } }
    private(set) var rules: [GestureRule] = []

    /// The page is open and wants live fingers.
    var metering = false { didSet { if metering != oldValue { apply() } } }
    /// Fingers on the pad right now, 0...1 with y up — only while metering.
    private(set) var fingers: [CGPoint] = []
    /// The last thing recognized, and what it ran (nil when nothing was set for it).
    private(set) var last: (trigger: GestureTrigger, ran: GestureAction?, at: Date)?
    /// Waiting for a gesture to record, and what was just recorded.
    private(set) var recording: GestureTrigger.Kind?
    private(set) var recorded: UUID?

    /// Shared with the event threads, so not tied to the main actor.
    nonisolated static let table = GestureTable()
    var table: GestureTable { Self.table }
    private var frontObserver: Any?
    private var frameStamp = 0.0

    var trackpadAvailable: Bool { MultitouchSource.shared.isAvailable }

    private init() {
        let d = Pref.defaults
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        showWhatRan = d.bool(forKey: Self.showKey)
        if let data = d.data(forKey: Self.rulesKey), let saved = try? JSONDecoder().decode([GestureRule].self, from: data) {
            rules = saved
        }
    }

    func start() {
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Gestures.table.setFront(id)
        }
        table.setFront(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        MultitouchSource.shared.onGesture = { g in
            guard let m = Gestures.table.match(.trackpad(g)) else { Gestures.noticeUnbound(g); return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Gestures.shared.handle(.trackpad(g), m) } }
        }
        apply()
    }

    // MARK: Rules

    func add(_ rule: GestureRule) {
        rules.append(rule)
        save()
    }

    func update(_ rule: GestureRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        save()
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    /// Suggestions to start from, added switched off so nothing changes until you turn one on.
    func addRecommended() {
        let picks: [(GestureTrigger, GestureAction)] = [
            (.trackpad(.tipTapLeft), .preset(.previousTab)),
            (.trackpad(.tipTapRight), .preset(.nextTab)),
            (.trackpad(.tap3), .middleClick),
            (.trackpad(.tap4), .target(HotCorners.Target.ring.raw)),
            (.trackpad(.tap5), .target(HotCorners.Target.command(.captureArea).raw)),
            (.mouse(button: 3, mods: []), .preset(.back)),
            (.mouse(button: 4, mods: []), .preset(.forward)),
            (.doubleTap(.control), .target(HotCorners.Target.command(.clipboard).raw)),
        ]
        for (trigger, action) in picks where !rules.contains(where: { $0.trigger == trigger && $0.apps.isEmpty }) {
            rules.append(GestureRule(trigger: trigger, action: action, enabled: false))
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { Pref.defaults.set(data, forKey: Self.rulesKey) }
        apply()
    }

    // MARK: Recording

    func record(_ kind: GestureTrigger.Kind?) {
        recording = kind
        recorded = nil
        table.setRecording(kind)
        apply()
    }

    private func captured(_ t: GestureTrigger) {
        record(nil)
        if let same = rules.first(where: { $0.trigger == t && $0.apps.isEmpty }) {
            recorded = same.id
            return
        }
        let rule = GestureRule(trigger: t)
        rules.append(rule)
        recorded = rule.id
        save()
    }

    // MARK: Listening

    /// Each source runs only while something needs it: a rule that's on, the page's live view, or recording.
    func apply() {
        table.update(rules: rules, active: enabled)
        let trackpad = table.wants(.trackpad) || metering
        if trackpad { MultitouchSource.shared.start() } else { MultitouchSource.shared.stop() }
        if metering {
            MultitouchSource.shared.onFrame = { @Sendable points in
                DispatchQueue.main.async { MainActor.assumeIsolated { Gestures.shared.show(points) } }
            }
        } else {
            MultitouchSource.shared.onFrame = nil
        }
        if !metering { fingers = [] }
        GestureMouse.shared.update(wanted: table.wants(.mouse))
    }

    private func show(_ points: [CGPoint]) {
        // A frame every ~30ms is plenty for dots; the pad sends more than a hundred a second.
        let now = CACurrentMediaTime()
        guard now - frameStamp > 0.03 || points.isEmpty != fingers.isEmpty else { return }
        frameStamp = now
        fingers = points
    }

    /// A trackpad gesture nothing is set for: the page still shows it.
    private nonisolated static func noticeUnbound(_ g: TrackpadGesture) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let s = Gestures.shared
                if s.metering { s.last = (.trackpad(g), nil, Date()) }
            }
        }
    }

    func handle(_ t: GestureTrigger, _ match: GestureTable.Match) {
        switch match {
        case .record:
            GestureLog.write("recorded \(t.logName)")
            captured(t)
        case .rule(let rule):
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            GestureLog.write("\(t.logName) in \(app) → \(rule.action.kind) (rule \(rule.id.uuidString.prefix(8))\(rule.apps.isEmpty ? "" : ", app rule"))")
            last = (t, rule.action, Date())
            rule.action.run()
            if showWhatRan { Toast.show(rule.action.title, symbol: rule.action.symbol, detail: t.title) }
        }
    }

    // MARK: macOS's own gestures

    /// The macOS trackpad gesture that also answers to this one, if it's on: both will happen.
    static func systemOverlap(_ g: TrackpadGesture) -> String? {
        func value(_ key: String, default fallback: Int) -> Int {
            var best: Int?
            for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
                if let v = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int { best = max(best ?? 0, v) }
            }
            return best ?? fallback
        }
        let threeDrag = value("TrackpadThreeFingerDrag", default: 0) != 0
        switch g {
        case .swipe3Left, .swipe3Right:
            if threeDrag { return "Three-finger drag" }
            return value("TrackpadThreeFingerHorizSwipeGesture", default: 0) != 0 ? "Swipe between full-screen apps" : nil
        case .swipe3Up, .swipe3Down:
            if threeDrag { return "Three-finger drag" }
            return value("TrackpadThreeFingerVertSwipeGesture", default: 0) != 0 ? "Mission Control and App Exposé" : nil
        case .swipe4Left, .swipe4Right:
            return value("TrackpadFourFingerHorizSwipeGesture", default: 2) != 0 ? "Swipe between full-screen apps" : nil
        case .swipe4Up, .swipe4Down:
            return value("TrackpadFourFingerVertSwipeGesture", default: 2) != 0 ? "Mission Control and App Exposé" : nil
        case .tap3:
            return value("TrackpadThreeFingerTapGesture", default: 0) != 0 ? "Look up & data detectors" : nil
        case .tap4, .tap5, .tipTapLeft, .tipTapRight:
            return nil
        }
    }
}
