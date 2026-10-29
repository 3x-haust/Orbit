import Foundation
import IOKit

/// What the battery and the charger report right now (AppleSmartBattery). Shared by Orbit and its
/// helper; reading needs no privileges.
struct BatteryReading: Equatable, Sendable {
    var percent = 0
    var plugged = false
    var charging = false
    var fullyCharged = false
    /// mV and mA; amperage is negative while the battery is draining.
    var voltage = 0
    var amperage = 0
    var cycles = 0
    var designCycles = 1000
    /// mAh.
    var fullCharge = 0
    var design = 0
    var adapterWatts = 0
    var adapterName = ""
    /// What the Mac draws from the wall and what the whole system uses, in watts.
    var wallWatts: Double = 0
    var systemWatts: Double = 0
    /// Non-zero when the charger says why it isn't charging (macOS's own limits included).
    var notChargingReason = 0

    /// Positive while charging, negative while draining.
    var batteryWatts: Double { Double(voltage) * Double(amperage) / 1_000_000 }
    var health: Double? { design > 0 && fullCharge > 0 ? min(1.2, Double(fullCharge) / Double(design)) : nil }
}

enum BatteryIO {
    /// nil on Macs without a battery.
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        func int(_ v: Any?) -> Int {
            if let n = v as? NSNumber { return n.intValue }
            return 0
        }
        var r = BatteryReading()
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        r.percent = int(d["CurrentCapacity"])
        r.plugged = d["ExternalConnected"] as? Bool ?? false
        r.charging = d["IsCharging"] as? Bool ?? false
        r.fullyCharged = d["FullyCharged"] as? Bool ?? false
        r.voltage = int(d["Voltage"])
        // Amperage is published as an unsigned 64-bit pattern; the signed value is what's meant.
        if let n = d["Amperage"] as? NSNumber { r.amperage = Int(truncatingIfNeeded: n.int64Value) }
        r.cycles = int(d["CycleCount"])
        let designCycles = int(d["DesignCycleCount9C"])
        r.designCycles = designCycles > 0 ? designCycles : 1000
        r.fullCharge = int(data["FullChargeCapacity"] ?? d["AppleRawMaxCapacity"])
        r.design = int(data["DesignCapacity"] ?? d["DesignCapacity"])
        if let a = d["AdapterDetails"] as? [String: Any] {
            r.adapterWatts = int(a["Watts"])
            r.adapterName = ((a["Name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        }
        if let t = d["PowerTelemetryData"] as? [String: Any] {
            r.wallWatts = Double(int(t["SystemPowerIn"])) / 1000
            r.systemWatts = Double(int(t["SystemLoad"])) / 1000
        }
        if let c = d["ChargerData"] as? [String: Any] { r.notChargingReason = int(c["NotChargingReason"]) }
        return r
    }
}

/// The SMC keys that control charging, and the only values Orbit's helper will ever write to them.
/// Which keys exist depends on the chip and its firmware; detection and values follow the open-source
/// `battery` CLI (actuallymentor/battery): a key is used only if this Mac answers when it's read.
enum ChargeKeys {
    static let allowed: [String: Set<[UInt8]>] = [
        // Charging inhibit (Apple Silicon, newer firmware): 1 = don't charge.
        "CHTE": [[0, 0, 0, 0], [1, 0, 0, 0]],
        // Charging inhibit (older firmware): 2 = don't charge, written to both.
        "CH0B": [[0], [2]], "CH0C": [[0], [2]],
        // Adapter off — the Mac runs from its battery while plugged in.
        "CHIE": [[0], [8]],
        "CH0J": [[0], [1]],
        "CH0I": [[0], [1]],
        // MagSafe LED: 0 macOS decides, 1 off, 3 green, 4 orange.
        "ACLC": [[0], [1], [3], [4]],
    ]

    enum Inhibit: String, Sendable { case chte = "CHTE", ch0b = "CH0B" }
    enum Adapter: String, Sendable { case chie = "CHIE", ch0j = "CH0J", ch0i = "CH0I" }

    static func inhibit(_ has: (String) -> Bool) -> Inhibit? {
        if has("CHTE") { return .chte }
        if has("CH0B"), has("CH0C") { return .ch0b }
        return nil
    }

    static func adapter(_ has: (String) -> Bool) -> Adapter? {
        if has("CHIE") { return .chie }
        if has("CH0J") { return .ch0j }
        if has("CH0I") { return .ch0i }
        return nil
    }
}

extension SMC {
    func has(_ key: String) -> Bool { bytes(key) != nil }

    /// Writes one of the charging keys — and only a value listed in `ChargeKeys.allowed`. Root only.
    @discardableResult
    func writeCharging(_ key: String, _ value: [UInt8]) -> Bool {
        guard ChargeKeys.allowed[key]?.contains(value) == true else { return false }
        if bytes(key) == value { return true }
        return writeKey(key, value)
    }

    /// Same whitelist, but writes even when the key already reads that value.
    @discardableResult
    func writeKeyIfAllowed(_ key: String, _ value: [UInt8]) -> Bool {
        guard ChargeKeys.allowed[key]?.contains(value) == true else { return false }
        return writeKey(key, value)
    }
}
