import Foundation
import IOKit

/// Access to the System Management Controller: fan speeds and temperature sensors.
/// Reading needs no privileges. Writing (manual fan control) needs root, so only OrbitFanHelper does it.
final class SMC {
    nonisolated(unsafe) static let shared = SMC()

    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    private struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0 }
    private typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    /// Mirrors the kernel's SMCParamStruct; layout must match exactly.
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var limit = PLimit()
        var info = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private lazy var temperatureKeys: [String] = discoverTemperatureKeys()

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess { connection = 0 }
    }

    var available: Bool { connection != 0 }

    struct Fan: Identifiable, Equatable {
        let id: Int
        var rpm: Double
        var min: Double
        var max: Double
        /// 0…1 between the fan's minimum and maximum speed.
        var level: Double { max > min ? Swift.min(1, Swift.max(0, (rpm - min) / (max - min))) : 0 }
    }

    func fans() -> [Fan] {
        guard let count = value("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return Fan(id: i, rpm: rpm, min: value("F\(i)Mn") ?? 0, max: value("F\(i)Mx") ?? 0)
        }
    }

    struct Temperatures: Equatable {
        var chip: Double?
        var battery: Double?
        var storage: Double?
    }

    /// Apple Silicon sensor names change between chips, so they're grouped by prefix:
    /// TP*/TR* are processor dies, TB*T the battery cells, TH* the SSD.
    /// Just the battery's sensors: a handful of keys instead of every temperature on the chip.
    func batteryTemperature() -> Double? {
        let values = temperatureKeys.filter { $0.hasPrefix("TB") && $0.hasSuffix("T") }
            .compactMap { value($0) }.filter { $0 > 5 && $0 < 130 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    func temperatures() -> Temperatures {
        var t = Temperatures()
        var chip: [Double] = [], battery: [Double] = [], storage: [Double] = []
        for key in temperatureKeys {
            guard let v = value(key), v > 5, v < 130 else { continue }
            if key.hasPrefix("TP") || key.hasPrefix("TR") || key.hasPrefix("Tp") || key.hasPrefix("Te") { chip.append(v) }
            else if key.hasPrefix("TB"), key.hasSuffix("T") { battery.append(v) }
            else if key.hasPrefix("TH") { storage.append(v) }
        }
        t.chip = chip.max()
        t.battery = battery.isEmpty ? nil : battery.reduce(0, +) / Double(battery.count)
        t.storage = storage.max()
        return t
    }

    // MARK: Fan control (root only)

    /// Takes `fan` off automatic control and aims it at `rpm`, clamped to the fan's own range.
    @discardableResult
    func setManual(fan i: Int, rpm: Double) -> Bool {
        guard let lo = value("F\(i)Mn"), let hi = value("F\(i)Mx"), hi > lo else { return false }
        if value("F\(i)md") != 1, !write("F\(i)md", [1]) {
            // M1–M4 lock mode changes behind a test flag that takes a moment to take effect.
            guard raw("Ftst") != nil, write("Ftst", [1]) else { return false }
            guard (0..<20).contains(where: { _ in
                if write("F\(i)md", [1]) { return true }
                usleep(100_000)
                return false
            }) else { return false }
        }
        var target = Float(Swift.min(hi, Swift.max(lo, rpm)))
        return write("F\(i)Tg", withUnsafeBytes(of: &target) { Array($0) })
    }

    /// Hands `fan` back to macOS.
    @discardableResult
    func setAutomatic(fan i: Int) -> Bool {
        let ok = write("F\(i)md", [0])
        if raw("Ftst") != nil, fans().allSatisfy({ value("F\($0.id)md") == 0 }) { write("Ftst", [0]) }
        return ok
    }

    /// Raw bytes of any key; nil when this Mac doesn't have it.
    func bytes(_ key: String) -> [UInt8]? { raw(key)?.bytes }

    /// Writes are root-only and go through a caller's own whitelist (fans above, `writeCharging`).
    func writeKey(_ key: String, _ bytes: [UInt8]) -> Bool { write(key, bytes) }

    @discardableResult
    private func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard available else { return false }
        var info = Param()
        info.key = Self.code(key)
        info.command = 9
        guard let described = call(&info), Int(described.info.size) == bytes.count else { return false }
        var p = Param()
        p.key = info.key
        p.info.size = described.info.size
        p.command = 6
        withUnsafeMutableBytes(of: &p.bytes) { buffer in
            for (i, b) in bytes.enumerated() { buffer[i] = b }
        }
        return call(&p) != nil
    }

    // MARK: Low level

    private func discoverTemperatureKeys() -> [String] {
        guard let total = raw("#KEY").map({ $0.bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }) else { return [] }
        let wanted = ["TP", "TR", "Tp", "Te", "TB", "TH"]
        return (0..<total).compactMap { i -> String? in
            var p = Param()
            p.command = 8
            p.index = i
            guard let out = call(&p) else { return nil }
            let key = Self.string(out.key)
            return wanted.contains(where: key.hasPrefix) ? key : nil
        }
    }

    func value(_ key: String) -> Double? {
        guard let (type, bytes) = raw(key) else { return nil }
        switch type {
        case "flt " where bytes.count >= 4: return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16" where bytes.count >= 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "fpe2" where bytes.count >= 2: return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78" where bytes.count >= 2: return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }

    private func raw(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard available else { return nil }
        var info = Param()
        info.key = Self.code(key)
        info.command = 9
        guard let described = call(&info) else { return nil }
        var read = Param()
        read.key = info.key
        read.info.size = described.info.size
        read.command = 5
        guard let out = call(&read) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(described.info.size))) }
        return (Self.string(described.info.type), bytes)
    }

    private func call(_ input: inout Param) -> Param? {
        lock.lock(); defer { lock.unlock() }
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        return result == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}
