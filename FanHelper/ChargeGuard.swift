import Foundation

/// The helper's charge limiter. Runs on the helper's SMC queue. The policy is kept in root's
/// preferences so the limit is back in force after a restart even before Orbit opens; when the
/// helper itself is stopped (Orbit Helper turned off or removed), charging goes back to normal.
final class ChargeGuard {
    private var limit = 100, floor = 100, led = 0
    private var heatLimit: Double = 0
    private var asleep = false
    /// Between willSleep and didWake: hold whatever was set for sleep.
    private var sleeping = false
    private var dischargeTarget = 0
    private var dischargeRenewed = Date.distantPast
    private var inhibited = false, adapterOff = false, heatPaused = false
    private var lastError: String?
    /// What Orbit last put on the LED; macOS owns it (0) until Orbit changes it. macOS rewrites the
    /// key with the colour it shows, so it's compared with this rather than read back.
    private var lastLED: UInt8 = 0
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private let defaults = UserDefaults.standard

    private lazy var inhibitKey = ChargeKeys.inhibit(SMC.shared.has)
    private lazy var adapterKey = ChargeKeys.adapter(SMC.shared.has)
    private lazy var hasLED = SMC.shared.has("ACLC")

    init(queue: DispatchQueue) {
        self.queue = queue
        limit = defaults.object(forKey: "charge.limit") as? Int ?? 100
        floor = defaults.object(forKey: "charge.floor") as? Int ?? limit
        heatLimit = defaults.double(forKey: "charge.heat")
        led = defaults.integer(forKey: "charge.led")
    }

    /// At boot (launchd starts the helper at load) the saved limit is back in force within seconds,
    /// before Orbit or anyone has logged in — like `battery maintain` recovering from its LaunchAgent.
    func start() {
        guard active else { return }
        tick()
        run()
    }

    /// Going to sleep: the SMC keeps charging while the Mac sleeps and nobody is watching the
    /// percentage, so with a limit set charging is paused first; the next tick after wake decides
    /// again. Running from the battery never continues into sleep.
    func willSleep() {
        if dischargeTarget > 0 { dischargeTarget = 0 }
        if limit < 100, inhibitKey != nil { setInhibit(true) }
        setAdapterOff(false)
        sleeping = true
    }

    func didWake() {
        sleeping = false
        tick()
    }

    private var active: Bool { limit < 100 || heatLimit > 0 || dischargeTarget > 0 || led != 0 || asleep }

    func setPolicy(limit: Int, floor: Int, heatLimit: Double, led: Int, asleep: Bool) -> String? {
        guard (20...100).contains(limit) else { return "Limit out of range" }
        guard (10...limit).contains(floor) else { return "Sailing floor out of range" }
        guard heatLimit == 0 || (25...50).contains(heatLimit) else { return "Heat limit out of range" }
        guard (0...2).contains(led) else { return "Unknown LED mode" }
        guard inhibitKey != nil || adapterKey != nil || limit == 100 else { return "This Mac has no charging control" }
        self.limit = limit
        self.floor = floor
        self.heatLimit = heatLimit
        self.led = led
        self.asleep = asleep
        defaults.set(limit, forKey: "charge.limit")
        defaults.set(floor, forKey: "charge.floor")
        defaults.set(heatLimit, forKey: "charge.heat")
        defaults.set(led, forKey: "charge.led")
        tick()
        run()
        return lastError
    }

    func setDischarge(to target: Int) -> String? {
        guard target == 0 || (10...100).contains(target) else { return "Target out of range" }
        guard target == 0 || adapterKey != nil else { return "This Mac can't run from its battery while plugged in" }
        dischargeTarget = target
        dischargeRenewed = Date()
        tick()
        run()
        return lastError
    }

    /// Orbit went away: never leave the Mac running from its battery on its own.
    func clientGone() {
        guard dischargeTarget > 0 else { return }
        dischargeTarget = 0
        tick()
    }

    func state() -> String {
        let d: [String: Any] = [
            "inhibitKey": inhibitKey?.rawValue ?? "", "adapterKey": adapterKey?.rawValue ?? "", "led": hasLED,
            "inhibited": inhibited, "adapterOff": adapterOff, "heatPaused": heatPaused,
            "discharging": dischargeTarget > 0, "limit": limit, "floor": floor, "error": lastError ?? "",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Helper stopping: everything back to how macOS does it.
    func restoreNormal() {
        setInhibit(false)
        setAdapterOff(false)
        if hasLED, lastLED != 0 { SMC.shared.writeKeyIfAllowed("ACLC", [0]) }
    }

    private func run() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !sleeping, let b = BatteryIO.read() else { return }
        if dischargeTarget > 0, Date().timeIntervalSince(dischargeRenewed) > FanHelper.dischargeLease || b.percent <= dischargeTarget || !b.plugged {
            dischargeTarget = 0
        }
        let temp = SMC.shared.temperatures().battery
        if heatLimit > 0, let temp {
            // Two degrees of hysteresis so it doesn't flicker on and off at the threshold.
            heatPaused = heatPaused ? temp > heatLimit - 2 : temp >= heatLimit
        } else {
            heatPaused = false
        }
        // Holding at the limit; resumes only once it has sailed down to the floor.
        let holding = limit < 100 && (b.percent >= limit || ((inhibited || adapterOff) && b.percent > floor))
        let discharging = dischargeTarget > 0

        if inhibitKey != nil {
            setInhibit(holding || heatPaused || discharging || asleep)
            setAdapterOff(discharging)
        } else {
            // No charge-only switch on this Mac: hold by running from the battery between floor and limit.
            setAdapterOff(discharging || holding || heatPaused)
        }
        applyLED(b)
        if !active, !inhibited, !adapterOff {
            timer?.cancel()
            timer = nil
        }
    }

    private func setInhibit(_ on: Bool) {
        switch inhibitKey {
        case .chte?: record(SMC.shared.writeCharging("CHTE", on ? [1, 0, 0, 0] : [0, 0, 0, 0]), "CHTE")
        case .ch0b?:
            record(SMC.shared.writeCharging("CH0B", on ? [2] : [0]), "CH0B")
            record(SMC.shared.writeCharging("CH0C", on ? [2] : [0]), "CH0C")
        case nil: break
        }
        inhibited = on && inhibitKey != nil
    }

    private func setAdapterOff(_ on: Bool) {
        switch adapterKey {
        case .chie?: record(SMC.shared.writeCharging("CHIE", on ? [8] : [0]), "CHIE")
        case .ch0j?: record(SMC.shared.writeCharging("CH0J", on ? [1] : [0]), "CH0J")
        case .ch0i?: record(SMC.shared.writeCharging("CH0I", on ? [1] : [0]), "CH0I")
        case nil: break
        }
        adapterOff = on && adapterKey != nil
    }

    private func applyLED(_ b: BatteryReading) {
        guard hasLED else { return }
        let value: UInt8 = switch led {
        case 1: !b.plugged || adapterOff ? 1 : (b.charging ? 4 : 3)
        case 2: 1
        default: 0
        }
        guard value != lastLED else { return }
        if SMC.shared.writeKeyIfAllowed("ACLC", [value]) { lastLED = value } else { lastError = "The SMC refused ACLC" }
    }

    private func record(_ ok: Bool, _ key: String) {
        lastError = ok ? nil : "The SMC refused \(key)"
    }
}
