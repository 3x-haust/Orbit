import Foundation

/// The privileged fan helper's XPC interface, shared by Orbit and OrbitFanHelper.
@objc protocol FanHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    /// Holds `fan` at `rpm`, clamped to the fan's own range. Orbit renews this every few seconds;
    /// a fan not renewed within `FanHelper.leaseSeconds` goes back to macOS.
    func setFan(_ fan: Int, rpm: Double, reply: @escaping (String?) -> Void)
    func setAutomatic(_ fan: Int, reply: @escaping (String?) -> Void)
    /// `pmset -a disablesleep`: closed-lid mode without asking for a password every time. (v2)
    func setSleepDisabled(_ on: Bool, reply: @escaping (String?) -> Void)

    // Battery (v3). The helper enforces the charge limit itself, so it holds while Orbit is closed.
    /// `limit` 100 means charge normally. Charging resumes once the battery is down to `floor`
    /// (sailing). `heatLimit` 0 is off; at or above it charging pauses. `led`: 0 macOS, 1 follow the
    /// charge state, 2 off. `asleep` pauses charging while the Mac sleeps.
    func setChargePolicy(limit: Int, floor: Int, heatLimit: Double, led: Int, asleep: Bool, reply: @escaping (String?) -> Void)
    /// Runs from the battery while plugged in, down to `target` (0 stops). Orbit renews it every
    /// half minute; it lapses after `FanHelper.dischargeLease`, and stops when Orbit disconnects.
    func setDischarge(to target: Int, reply: @escaping (String?) -> Void)
    /// JSON: which keys this Mac has and what the helper is doing right now.
    func chargeState(reply: @escaping (String) -> Void)
}

enum FanHelper {
    static let label = "com.lyu.orbit.fanhelper"
    static let plist = "com.lyu.orbit.fanhelper.plist"
    static let version = 3
    static let leaseSeconds: TimeInterval = 15
    static let dischargeLease: TimeInterval = 90
    /// At or above this chip temperature every manual fan runs at full speed, whatever was asked.
    static let hotLimit: Double = 95
    /// Only Orbit, signed by its own team, may drive the fans…
    static let clientRequirement = #"anchor apple generic and identifier "com.lyu.orbit" and certificate leaf[subject.OU] = "UM52UU4B7L""#
    /// …and Orbit only talks to its own helper.
    static let helperRequirement = #"anchor apple generic and identifier "com.lyu.orbit.fanhelper" and certificate leaf[subject.OU] = "UM52UU4B7L""#
}
