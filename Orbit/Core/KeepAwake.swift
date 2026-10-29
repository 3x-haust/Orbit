import AppKit
import IOKit.pwr_mgt
import Observation

/// Amphetamine-style keep-awake: sessions with an end condition, closed-lid mode and safety stops.
///
/// Closed-lid mode uses `pmset -a disablesleep 1`, the only switch macOS offers for staying awake
/// with the lid shut and no external display. It needs an administrator password, so Orbit tracks that
/// it turned it on and always turns it back off — on stop, on quit, and on the next launch after a crash.
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()

    enum Session: Equatable {
        case indefinite
        case duration(TimeInterval)
        case until(Date)
        case whileApp(bundleID: String, name: String)
    }

    private(set) var isOn = false
    private(set) var session: Session?
    private(set) var startedAt: Date?
    private(set) var until: Date?
    /// Orbit currently has `disablesleep` set.
    private(set) var closedLidActive = false
    private(set) var changingLid = false
    /// Another app (e.g. Amphetamine) already set `disablesleep`. Orbit leaves it alone.
    private(set) var lidDisabledElsewhere = false
    private(set) var lastStopReason: String?

    @ObservationIgnored private var assertions: [IOPMAssertionID] = []
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var appObserver: NSObjectProtocol?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    // MARK: Options

    static var keepDisplayOn: Bool { Pref.defaults.bool(forKey: Pref.awakeDisplay) }
    static var closedLid: Bool { Pref.defaults.bool(forKey: Pref.awakeClosedLid) }
    static var batteryFloor: Int { Pref.defaults.integer(forKey: Pref.awakeBatteryFloor) }
    static var stopWhenHot: Bool { Pref.defaults.bool(forKey: Pref.awakeThermal) }

    var remaining: TimeInterval? { until.map { max(0, $0.timeIntervalSinceNow) } }
    var total: TimeInterval? {
        guard let startedAt, let until else { return nil }
        return until.timeIntervalSince(startedAt)
    }

    // MARK: Sessions

    func toggle() { isOn ? stop() : start(.indefinite) }

    func start(for interval: TimeInterval?) { start(interval.map { .duration($0) } ?? .indefinite) }

    func start(_ session: Session) {
        releaseAssertions()
        let idle = Self.keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        hold(idle)
        hold(kIOPMAssertionTypePreventSystemSleep) // effective on power adapter
        guard !assertions.isEmpty else {
            Toast.show("Couldn’t keep your Mac awake", symbol: "exclamationmark.triangle.fill")
            return
        }
        isOn = true
        lastStopReason = nil
        self.session = session
        startedAt = Date()
        switch session {
        case .duration(let t): until = Date().addingTimeInterval(t)
        case .until(let d): until = d
        default: until = nil
        }
        watch()
        saveForRelaunch()
        // One notice per start: with closed-lid mode, the lid step reports for both.
        if Self.closedLid, !closedLidActive {
            Task { await setLid(true) }
        } else {
            Toast.show("Keeping your Mac awake", symbol: "cup.and.saucer.fill", detail: Self.describe(session))
        }
    }

    func stop(reason: String? = nil) {
        guard isOn else { return }
        releaseAssertions()
        unwatch()
        isOn = false
        session = nil
        until = nil
        startedAt = nil
        lastStopReason = reason
        lidDisabledElsewhere = false
        Pref.defaults.removeObject(forKey: Self.resumeKey)
        if closedLidActive { Task { await setLid(false) } }
        Toast.show(reason ?? "Sleep is back to normal", symbol: "moon.zzz.fill")
    }

    /// Turns closed-lid mode on or off; applies right away if a session is running.
    func setClosedLid(_ on: Bool) {
        Pref.defaults.set(on, forKey: Pref.awakeClosedLid)
        guard isOn, on != closedLidActive else { return }
        Task { await setLid(on) }
    }

    /// Display sleep preference changed mid-session: swap the assertion.
    func refreshAssertions() {
        guard isOn, let session else { return }
        let until = self.until, started = startedAt
        releaseAssertions()
        let idle = Self.keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        hold(idle)
        hold(kIOPMAssertionTypePreventSystemSleep)
        self.session = session
        self.until = until
        startedAt = started
    }

    // MARK: Closed lid

    private func setLid(_ on: Bool) async {
        changingLid = true
        defer { changingLid = false }
        if on, await Task.detached(operation: { KeepAwake.systemSleepDisabled() }).value {
            // Not ours to turn off later.
            lidDisabledElsewhere = true
            Toast.show("Lid sleep is already off", symbol: "laptopcomputer", detail: "Another app turned it off — Orbit won’t change it")
            return
        }
        lidDisabledElsewhere = false
        // The Orbit helper (approved once in Login Items) does it without a password, like Amphetamine.
        if let ok = await FanControl.shared.setSleepDisabled(on) {
            if ok {
                closedLidActive = on
                Pref.defaults.set(on, forKey: Pref.awakeLidOwned)
                if on { Toast.show("Keeping your Mac awake", symbol: "cup.and.saucer.fill", detail: "Stays awake with the lid closed, too") }
                return
            }
        }
        let ok = await Shell.runAsAdmin(
            "/usr/bin/pmset -a disablesleep \(on ? 1 : 0)",
            prompt: on ? "Orbit wants to keep your Mac awake with the lid closed."
                       : "Orbit wants to restore normal sleep when the lid closes.")
        if ok {
            closedLidActive = on
            Pref.defaults.set(on, forKey: Pref.awakeLidOwned)
            if on {
                Toast.show("Keeping your Mac awake", symbol: "cup.and.saucer.fill",
                           detail: FanControl.shared.helper == .ready ? "Stays awake with the lid closed, too" : "Turn on Orbit Helper to skip the password next time")
            }
        } else if on {
            Toast.show("Closed-lid mode needs your password", symbol: "lock.fill", detail: "Awake while the lid is open")
        } else {
            Toast.show("Couldn’t restore lid sleep", symbol: "exclamationmark.triangle.fill", detail: "Try again from Orbit › Awake")
        }
    }

    nonisolated static func systemSleepDisabled() -> Bool {
        Shell.run("/usr/bin/pmset", ["-g"]).output
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SleepDisabled") && $0.hasSuffix("1") }
    }

    /// After a crash or force-quit, closed-lid mode could be left on. Offer to put it back.
    /// Orbit quit without stopping (a crash, an update, a forced quit). A session that should still
    /// be running picks up where it was; one that's over gives sleep back. No question asked — a modal
    /// here held up everything else Orbit does at launch.
    func recoverIfNeeded() {
        let resume = Self.savedSession()
        let lidOwned = Pref.defaults.bool(forKey: Pref.awakeLidOwned)
        guard resume != nil || lidOwned else { return }
        Task {
            if lidOwned {
                let stillOn = await Task.detached { KeepAwake.systemSleepDisabled() }.value
                if stillOn { closedLidActive = true } else { Pref.defaults.set(false, forKey: Pref.awakeLidOwned) }
            }
            if let resume {
                start(resume)
                if closedLidActive, !Self.closedLid { await setLid(false) }
            } else {
                Pref.defaults.removeObject(forKey: Self.resumeKey)
                if closedLidActive {
                    await setLid(false)
                    Toast.show("Sleep is back to normal", symbol: "moon.zzz.fill")
                }
            }
        }
    }

    private static let resumeKey = "awake.resume"

    private func saveForRelaunch() {
        guard let session else { return }
        var d: [String: Any] = [:]
        switch session {
        case .indefinite: d["kind"] = "indefinite"
        case .duration, .until: d["kind"] = "until"; d["until"] = (until ?? Date()).timeIntervalSince1970
        case .whileApp(let id, let name): d["kind"] = "app"; d["id"] = id; d["name"] = name
        }
        Pref.defaults.set(d, forKey: Self.resumeKey)
    }

    /// The session Orbit was running when it last went away, if it should still be running now.
    private static func savedSession() -> Session? {
        guard let d = Pref.defaults.dictionary(forKey: resumeKey) else { return nil }
        switch d["kind"] as? String {
        case "indefinite": return .indefinite
        case "until":
            guard let t = d["until"] as? Double, t > Date().timeIntervalSince1970 + 5 else { return nil }
            return .until(Date(timeIntervalSince1970: t))
        case "app":
            guard let id = d["id"] as? String, let name = d["name"] as? String,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return nil }
            return .whileApp(bundleID: id, name: name)
        default: return nil
        }
    }

    /// Called from applicationShouldTerminate: never leave the lid switch behind.
    func restoreForQuit() async {
        releaseAssertions()
        if closedLidActive { await setLid(false) }
    }

    // MARK: Watching end conditions

    private func watch() {
        unwatch()
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.check() }
        }
        if case .whileApp(let id, let name) = session {
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == id else { return }
                MainActor.assumeIsolated { KeepAwake.shared.stop(reason: "%@ quit — sleep is back to normal".loc(name)) }
            }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.check() }
        }
    }

    private func unwatch() {
        tick?.invalidate()
        tick = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        appObserver = nil
        thermalObserver = nil
    }

    private func check() {
        guard isOn else { return }
        if let until, until <= Date() { stop(reason: "Keep awake finished".loc); return }
        if case .whileApp(let id, let name) = session,
           !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == id }) {
            stop(reason: "%@ quit — sleep is back to normal".loc(name)); return
        }
        let floor = Self.batteryFloor
        if floor > 0, let b = Battery.read(), !b.onAC, b.percent <= floor {
            stop(reason: "Battery at %ld%% — sleep is back to normal".loc(b.percent)); return
        }
        if Self.stopWhenHot, ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            stop(reason: "Your Mac is getting hot — sleep is back to normal".loc)
        }
    }

    // MARK: Assertions

    private func hold(_ type: String) {
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Orbit Keep Awake" as CFString, &id) == kIOReturnSuccess {
            assertions.append(id)
        }
    }

    private func releaseAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
    }

    // MARK: Formatting

    static func describe(_ session: Session) -> String {
        switch session {
        case .indefinite: "Until you turn it off".loc
        case .duration(let t): "For %@".loc(format(t))
        case .until(let d): "Until %@".loc(d.formatted(date: .omitted, time: .shortened))
        case .whileApp(_, let name): "While %@ is open".loc(name)
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s >= 3600 { return s % 3600 / 60 == 0 ? "%ldh".loc(s / 3600) : "%ldh %@m".loc(s / 3600, String(format: "%02d", s % 3600 / 60)) }
        if s >= 60 { return "%ldm".loc(s / 60) }
        return "%lds".loc(s)
    }
}
