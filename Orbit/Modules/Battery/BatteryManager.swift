import AppKit
import IOKit.pwr_mgt

/// Charge limiting, AlDente-style. Orbit decides the policy; OrbitFanHelper (root) writes the SMC and
/// keeps enforcing the limit on its own, so it holds while Orbit is closed. Running from the battery
/// while plugged in (discharge, calibration) always needs Orbit: it stops when Orbit goes away.
@MainActor @Observable
final class BatteryManager {
    static let shared = BatteryManager()

    enum LED: String, CaseIterable, Identifiable {
        case system, state, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "macOS"
            case .state: "Show state"
            case .off: "Off"
            }
        }
        var helperValue: Int { switch self { case .system: 0; case .state: 1; case .off: 2 } }
    }

    enum OnQuit: String, CaseIterable, Identifiable {
        case keep, restore
        var id: String { rawValue }
        var title: String { self == .keep ? "Keep the limit" : "Charge normally" }
    }

    /// How this Mac can be told to stop charging.
    enum Control: Equatable {
        /// A real "don't charge" switch: the Mac keeps running from the adapter.
        case inhibit
        /// Only "adapter off": the limit is held by running from the battery between floor and limit.
        case adapterOnly
        case none
    }

    struct Calibration: Codable, Equatable {
        /// The `battery calibrate` order: drain to 15%, charge to 100%, rest an hour, discharge back to the limit.
        enum Step: Int, Codable, CaseIterable { case drain, charge, hold, settle }
        var step: Step
        var holdUntil: Date?
        static let drainTo = 15
        static let holdMinutes = 60
    }

    struct Schedule: Codable, Identifiable, Equatable {
        enum Action: String, Codable, CaseIterable, Identifiable {
            case topUp, discharge, limitOn, limitOff
            var id: String { rawValue }
            var title: String {
                switch self {
                case .topUp: "Top up to 100%"
                case .discharge: "Discharge to the limit"
                case .limitOn: "Turn the limit on"
                case .limitOff: "Turn the limit off"
                }
            }
        }
        var id = UUID()
        var action: Action = .topUp
        var hour = 7
        var minute = 0
        /// Calendar weekdays, 1 = Sunday. Empty means every day.
        var days: Set<Int> = []
        var enabled = true
    }

    // MARK: Live state

    private(set) var reading: BatteryReading?
    private(set) var temperature: Double?
    private(set) var control: Control = .none
    private(set) var hasLED = false
    /// Can run from the battery while plugged in (discharge, calibration).
    private(set) var canDischarge = false
    /// The helper's own view: is it holding the charge right now?
    private(set) var inhibited = false
    private(set) var adapterOff = false
    private(set) var heatPaused = false
    private(set) var helperVersion: Int?
    private(set) var lastError: String?

    var hasBattery: Bool { reading != nil }
    var helperReady: Bool { (helperVersion ?? 0) >= 3 }

    // MARK: Settings

    var limitOn: Bool { didSet { save("battery.limitOn", limitOn); apply() } }
    var limit: Int { didSet { save("battery.limit", limit); apply() } }
    var sailing: Bool { didSet { save("battery.sailing", sailing); apply() } }
    var sailingRange: Int { didSet { save("battery.sailingRange", sailingRange); apply() } }
    var heatOn: Bool { didSet { save("battery.heatOn", heatOn); apply() } }
    var heatLimit: Double { didSet { save("battery.heatLimit", heatLimit); apply() } }
    var led: LED { didSet { save("battery.led", led.rawValue); apply() } }
    var awakeUntilLimit: Bool { didSet { save("battery.awakeUntilLimit", awakeUntilLimit); updateAssertion() } }
    var onQuit: OnQuit { didSet { save("battery.onQuit", onQuit.rawValue) } }
    var schedules: [Schedule] { didSet { saveSchedules() } }

    /// One full charge, then back to the limit.
    private(set) var toppingUp: Bool { didSet { save("battery.topUp", toppingUp) } }
    private(set) var discharging = false
    private(set) var calibration: Calibration? { didSet { saveCalibration() } }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var lastSent: String?
    @ObservationIgnored private var lastSentAt = Date.distantPast
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var fired: [UUID: Date] = [:]
    @ObservationIgnored private var started = false

    private init() {
        let d = Pref.defaults
        limitOn = d.bool(forKey: "battery.limitOn")
        limit = d.object(forKey: "battery.limit") as? Int ?? 80
        sailing = d.object(forKey: "battery.sailing") as? Bool ?? true
        sailingRange = d.object(forKey: "battery.sailingRange") as? Int ?? 5
        heatOn = d.bool(forKey: "battery.heatOn")
        heatLimit = d.object(forKey: "battery.heatLimit") as? Double ?? 35
        led = LED(rawValue: d.string(forKey: "battery.led") ?? "") ?? .system
        awakeUntilLimit = d.bool(forKey: "battery.awakeUntilLimit")
        onQuit = OnQuit(rawValue: d.string(forKey: "battery.onQuit") ?? "") ?? .keep
        toppingUp = d.bool(forKey: "battery.topUp")
        schedules = (d.data(forKey: "battery.schedules")).flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) } ?? []
        calibration = (d.data(forKey: "battery.calibration")).flatMap { try? JSONDecoder().decode(Calibration.self, from: $0) }
    }

    func start() {
        guard !started else { return }
        started = true
        reading = BatteryIO.read()
        guard reading != nil else { return }
        let smc = SMC.shared
        control = ChargeKeys.inhibit(smc.has) != nil ? .inhibit : (ChargeKeys.adapter(smc.has) != nil ? .adapterOnly : .none)
        hasLED = smc.has("ACLC")
        canDischarge = ChargeKeys.adapter(smc.has) != nil
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BatteryManager.shared.sleepChanged(true) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BatteryManager.shared.sleepChanged(false) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BatteryManager.shared.quitting() }
        }
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { BatteryManager.shared.tick() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await connect() }
        tick()
    }

    /// Re-checks the helper (after it's installed or approved).
    func connect() async {
        helperVersion = await FanControl.shared.helperVersion()
        lastSent = nil
        apply()
    }

    // MARK: Actions

    func topUp() {
        guard hasBattery else { return }
        stopDischarge()
        toppingUp = true
        apply()
        Toast.show("Charging to 100%", symbol: "battery.100percent.bolt", detail: "Then back to your limit")
    }

    func cancelTopUp() {
        toppingUp = false
        apply()
    }

    func discharge() {
        guard canDischarge, reading?.plugged == true else {
            Toast.show("Plug in your Mac first", symbol: "powerplug")
            return
        }
        toppingUp = false
        discharging = true
        apply()
    }

    func stopDischarge() {
        guard discharging else { return }
        discharging = false
        apply()
    }

    func toggleLimit() {
        limitOn.toggle()
        Toast.show(limitOn ? "Charge limit on" : "Charge limit off", symbol: limitOn ? "battery.75percent" : "battery.100percent",
                   detail: limitOn ? "Stops charging at %ld%%".loc(limit) : nil)
    }

    func startCalibration() {
        guard canDischarge else { return }
        stopDischarge()
        toppingUp = false
        calibration = Calibration(step: .drain)
        apply()
        Toast.show("Calibration started", symbol: "gauge.with.dots.needle.67percent", detail: "Keep your Mac plugged in")
    }

    func cancelCalibration() {
        calibration = nil
        apply()
    }

    /// Everything back to how macOS charges: no limit, no top up, no discharge, no calibration.
    func restoreNormal() {
        calibration = nil
        toppingUp = false
        discharging = false
        heatOn = false
        limitOn = false
        led = .system
        apply()
        Toast.show("Charging normally", symbol: "battery.100percent.bolt", detail: "Orbit isn't limiting the battery")
    }

    // MARK: State

    /// The limit actually in force right now.
    var effectiveLimit: Int {
        if let c = calibration { return c.step == .settle ? limitOrDefault : 100 }
        if toppingUp || !limitOn { return 100 }
        return limit
    }

    private var floor: Int {
        let l = effectiveLimit
        guard l < 100 else { return 100 }
        return sailing ? max(15, l - sailingRange) : max(15, l - 1)
    }

    /// The limit calibration settles back to.
    private var limitOrDefault: Int { limitOn ? limit : 80 }

    private var dischargeTarget: Int {
        if calibration?.step == .drain { return Calibration.drainTo }
        if calibration?.step == .settle { return limitOrDefault }
        return discharging ? (limitOn ? limit : 50) : 0
    }

    enum Status: Equatable {
        case noBattery, unplugged, charging, full, holding, sailing, heat, discharging, toppingUp, calibrating, macOSHolding
    }

    var status: Status {
        guard let r = reading else { return .noBattery }
        if calibration != nil { return .calibrating }
        if discharging || (adapterOff && dischargeTarget > 0) { return .discharging }
        if !r.plugged { return .unplugged }
        if toppingUp { return .toppingUp }
        if heatPaused { return .heat }
        if inhibited || adapterOff {
            return r.percent >= effectiveLimit ? .holding : .sailing
        }
        if r.charging { return .charging }
        if r.fullyCharged || r.percent >= 100 { return .full }
        // Plugged in, not charging, and not because of Orbit: macOS is holding it (Optimized Charging,
        // its own charge limit, or heat).
        if r.notChargingReason != 0 { return .macOSHolding }
        return .full
    }

    var statusTitle: String {
        switch status {
        case .noBattery: "No battery".loc
        case .unplugged: "On battery".loc
        case .charging: limitOn && effectiveLimit < 100 ? "Charging to %ld%%".loc(effectiveLimit) : "Charging".loc
        case .full: "Fully charged".loc
        case .holding: "Charging paused at %ld%%".loc(effectiveLimit)
        case .sailing: "Sailing down to %ld%%".loc(floor)
        case .heat: "Paused — battery is warm".loc
        case .discharging: "Discharging to %ld%%".loc(dischargeTarget)
        case .toppingUp: "Topping up to 100%".loc
        case .calibrating: calibrationTitle
        case .macOSHolding: "macOS is holding the charge".loc
        }
    }

    var calibrationTitle: String {
        switch calibration?.step {
        case .drain?: "Calibrating · draining to %ld%%".loc(Calibration.drainTo)
        case .charge?: "Calibrating · charging to 100%".loc
        case .hold?: "Calibrating · resting at 100%".loc
        case .settle?: "Calibrating · back down to %ld%%".loc(limitOrDefault)
        case nil: ""
        }
    }

    /// 0…1 through the four steps.
    var calibrationProgress: Double {
        guard let c = calibration, let r = reading else { return 0 }
        let p = Double(r.percent)
        let within: Double = switch c.step {
        case .drain: (100 - p) / Double(100 - Calibration.drainTo)
        case .charge: (p - Double(Calibration.drainTo)) / Double(100 - Calibration.drainTo)
        case .hold:
            c.holdUntil.map { 1 - max(0, $0.timeIntervalSinceNow) / Double(Calibration.holdMinutes * 60) } ?? 0
        case .settle: (100 - p) / max(1, Double(100 - limitOrDefault))
        }
        return (Double(c.step.rawValue) + min(1, max(0, within))) / 4
    }

    // MARK: Loop

    private func tick() {
        let previous = reading
        reading = BatteryIO.read()
        Task.detached {
            let t = SMC.shared.batteryTemperature()
            await MainActor.run { BatteryManager.shared.temperature = t }
        }
        guard let r = reading else { return }

        if toppingUp, r.fullyCharged || r.percent >= 100 {
            toppingUp = false
            Toast.show("Topped up", symbol: "battery.100percent", detail: limitOn ? "Back to your %ld%% limit".loc(limit) : nil)
        }
        if discharging, r.percent <= dischargeTarget || !r.plugged {
            discharging = false
            if r.plugged { Toast.show("Discharged to %ld%%".loc(r.percent), symbol: "battery.50percent") }
        }
        advanceCalibration(r)
        runSchedules()
        if previous?.plugged != r.plugged { lastSent = nil }
        apply()
        refreshHelperState()
        updateAssertion()
    }

    private func advanceCalibration(_ r: BatteryReading) {
        guard var c = calibration else { return }
        switch c.step {
        case .drain where r.percent <= Calibration.drainTo: c.step = .charge
        case .charge where r.fullyCharged || r.percent >= 100:
            c.step = .hold
            c.holdUntil = Date().addingTimeInterval(Double(Calibration.holdMinutes * 60))
        case .hold where (c.holdUntil ?? .distantPast) <= Date(): c.step = .settle
        case .settle where r.percent <= limitOrDefault || !r.plugged:
            calibration = nil
            Toast.show("Calibration done", symbol: "checkmark.circle.fill", detail: "The battery reading is fresh again")
            return
        default: return
        }
        calibration = c
    }

    private func runSchedules() {
        let now = Date()
        let cal = Calendar.current
        let parts = cal.dateComponents([.hour, .minute, .weekday], from: now)
        for s in schedules where s.enabled && s.hour == parts.hour && s.minute == parts.minute {
            guard s.days.isEmpty || s.days.contains(parts.weekday ?? 0) else { continue }
            if let last = fired[s.id], now.timeIntervalSince(last) < 120 { continue }
            fired[s.id] = now
            switch s.action {
            case .topUp: topUp()
            case .discharge: discharge()
            case .limitOn: limitOn = true
            case .limitOff: limitOn = false
            }
        }
    }

    private func sleepChanged(_ sleeping: Bool) {
        asleep = sleeping
        apply()
    }

    private func quitting() {
        timer?.invalidate()
        let restore = onQuit == .restore
        // Running from the battery never outlives Orbit; the helper also stops it when Orbit disconnects.
        guard helperReady else { return }
        let heat = heatOn ? heatLimit : 0
        let led = self.led.helperValue
        let limit = restore ? 100 : effectiveLimitIgnoringTransient
        let floor = restore ? 100 : (limit < 100 ? (sailing ? max(15, limit - sailingRange) : max(15, limit - 1)) : 100)
        FanControl.synchronously(timeout: 0.6) { helper, done in
            helper.setDischarge(to: 0) { _ in
                helper.setChargePolicy(limit: limit, floor: floor, heatLimit: restore ? 0 : heat, led: restore ? 0 : led, asleep: false) { _ in done() }
            }
        }
    }

    /// What should hold after Orbit is gone: no top up or calibration in progress.
    private var effectiveLimitIgnoringTransient: Int { limitOn ? limit : 100 }

    private func apply() {
        guard started, hasBattery, helperReady, let helper = FanControl.shared.helperProxy() else { return }
        let limit = effectiveLimit, floor = floor
        let heat = heatOn ? heatLimit : 0
        let asleep = false // the helper pauses charging before sleep itself
        let target = dischargeTarget
        let key = "\(limit)/\(floor)/\(heat)/\(led.helperValue)/\(asleep)/\(target)"
        // Unchanged policy is resent every half minute: that also renews a discharge.
        guard key != lastSent || Date().timeIntervalSince(lastSentAt) > 30 else { return }
        lastSent = key
        lastSentAt = Date()
        helper.setChargePolicy(limit: limit, floor: min(floor, limit), heatLimit: heat, led: led.helperValue, asleep: asleep) { error in
            Task { @MainActor in BatteryManager.shared.lastError = error }
        }
        helper.setDischarge(to: target) { error in
            if let error { Task { @MainActor in BatteryManager.shared.lastError = error } }
        }
        refreshHelperState()
    }

    private func refreshHelperState() {
        guard helperReady, let helper = FanControl.shared.helperProxy() else { return }
        helper.chargeState { json in
            guard let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
            Task { @MainActor in
                let m = BatteryManager.shared
                m.inhibited = d["inhibited"] as? Bool ?? false
                m.adapterOff = d["adapterOff"] as? Bool ?? false
                m.heatPaused = d["heatPaused"] as? Bool ?? false
                let e = d["error"] as? String ?? ""
                if !e.isEmpty { m.lastError = e }
            }
        }
    }

    /// "Stay awake until the limit": the SMC keeps charging while the Mac sleeps, so the limit
    /// would be overshot; staying awake while charging toward it lets the helper stop on time.
    /// Also held through discharge and calibration, which need Orbit running.
    private func updateAssertion() {
        guard let r = reading else { return }
        let charging = r.plugged && r.charging && effectiveLimit < 100 && r.percent < effectiveLimit && awakeUntilLimit
        let want = charging || discharging || calibration != nil
        if want, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Orbit is managing the battery charge" as CFString, &assertion)
        } else if !want, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: Persistence

    private func save(_ key: String, _ value: Any) { Pref.defaults.set(value, forKey: key) }

    private func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules) { Pref.defaults.set(data, forKey: "battery.schedules") }
    }

    private func saveCalibration() {
        if let calibration, let data = try? JSONEncoder().encode(calibration) {
            Pref.defaults.set(data, forKey: "battery.calibration")
        } else {
            Pref.defaults.removeObject(forKey: "battery.calibration")
        }
    }

    static func openMacOSBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
