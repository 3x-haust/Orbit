import Foundation
import IOKit.ps
import Darwin
import Observation

enum Shell {
    /// Runs a tool synchronously and returns its exit status and stdout.
    @discardableResult
    nonisolated static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs off the main thread.
    nonisolated static func runAsync(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await Task.detached { run(path, args) }.value
    }

    /// Runs a command as root behind macOS's own administrator password dialog. False if cancelled.
    /// `command` and `prompt` must not contain double quotes.
    nonisolated static func runAsAdmin(_ command: String, prompt: String) async -> Bool {
        let script = "do shell script \"\(command)\" with prompt \"\(prompt)\" with administrator privileges"
        return await runAsync("/usr/bin/osascript", ["-e", script]).status == 0
    }

    nonisolated static func appleScript(_ source: String) async -> Bool {
        await runAsync("/usr/bin/osascript", ["-e", source]).status == 0
    }
}

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var onAC: Bool
}

enum Battery {
    /// nil on Macs without a battery.
    nonisolated static func read() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return BatteryState(percent: max > 0 ? current * 100 / max : current,
                                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}

/// Live CPU, memory, disk, network and battery readings. Polls only while something is watching.
@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    static let historyLength = 60

    private(set) var cpu: [Double] = []
    private(set) var memoryUsed: Double = 0
    /// Shares of the last CPU sample, for the runner's breakdown.
    private(set) var cpuUser: Double = 0
    private(set) var cpuSystem: Double = 0
    /// Activity Monitor's split of used memory, in bytes.
    private(set) var memoryApp: Double = 0
    private(set) var memoryWired: Double = 0
    private(set) var memoryCompressed: Double = 0
    private(set) var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    private(set) var memoryHistory: [Double] = []
    private(set) var diskFree: Double = 0
    private(set) var diskTotal: Double = 0
    private(set) var download: Double = 0
    private(set) var upload: Double = 0
    private(set) var downloadHistory: [Double] = []
    private(set) var battery: BatteryState?
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private(set) var fans: [SMC.Fan] = []
    private(set) var temperatures = SMC.Temperatures()
    private(set) var chipHistory: [Double] = []

    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var lightWatchers = 0
    @ObservationIgnored private var timerFull: Bool?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    @ObservationIgnored private var lastNet: (rx: UInt64, tx: UInt64, at: Date)?

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// `light` watchers (the menu bar runner) only need CPU and memory; the System page and the
    /// runner's popover want everything, sensors included. Walking the SMC and the disk every 1.5s
    /// for a runner that only shows CPU was most of Orbit's idle work.
    func watch(_ on: Bool, light: Bool = false) {
        if light { lightWatchers = max(0, lightWatchers + (on ? 1 : -1)) }
        else { watchers = max(0, watchers + (on ? 1 : -1)) }
        let wantFull = watchers > 0
        guard wantFull || lightWatchers > 0 else {
            timer?.invalidate()
            timer = nil
            timerFull = nil
            return
        }
        guard timerFull != wantFull else { return }
        timer?.invalidate()
        timerFull = wantFull
        sample(full: wantFull)
        let t = Timer(timeInterval: wantFull ? 1.5 : 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let m = SystemMonitor.shared
                m.sample(full: m.watchers > 0)
            }
        }
        t.tolerance = wantFull ? 0.2 : 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample(full: Bool = true) {
        if let c = sampleCPU() { cpu = Array((cpu + [c]).suffix(Self.historyLength)) }
        sampleMemory()
        guard full else { return }
        sampleDisk()
        sampleNetwork()
        battery = Battery.read()
        thermal = ProcessInfo.processInfo.thermalState
        // Sensor discovery walks ~3,000 SMC keys once, so it stays off the main thread.
        Task.detached {
            let fans = SMC.shared.fans(), temps = SMC.shared.temperatures()
            await MainActor.run {
                let monitor = SystemMonitor.shared
                monitor.fans = fans
                monitor.temperatures = temps
                if let chip = temps.chip { monitor.chipHistory = Array((monitor.chipHistory + [chip / 110]).suffix(Self.historyLength)) }
            }
        }
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let now = (user: t.0, system: t.1, idle: t.2, nice: t.3)
        defer { lastTicks = now }
        guard let l = lastTicks else { return nil }
        let busy = Double(now.user &- l.user) + Double(now.system &- l.system) + Double(now.nice &- l.nice)
        let total = busy + Double(now.idle &- l.idle)
        if total > 0 {
            cpuUser = (Double(now.user &- l.user) + Double(now.nice &- l.nice)) / total
            cpuSystem = Double(now.system &- l.system) / total
        }
        return total > 0 ? busy / total : nil
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let page = Double(getpagesize())
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        memoryUsed = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        memoryApp = app * page
        memoryWired = Double(stats.wire_count) * page
        memoryCompressed = Double(stats.compressor_page_count) * page
        memoryHistory = Array((memoryHistory + [memoryUsed / memoryTotal]).suffix(Self.historyLength))
    }

    @ObservationIgnored private var diskSampledAt = Date.distantPast

    private func sampleDisk() {
        // "Available for important usage" asks the volume to total up purgeable space (~15ms);
        // free space doesn't move fast enough to ask every tick.
        guard Date().timeIntervalSince(diskSampledAt) > 20 else { return }
        diskSampledAt = Date()
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        diskTotal = Double(v.volumeTotalCapacity ?? 0)
    }

    private func sampleNetwork() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return }
        defer { freeifaddrs(head) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor = head
        while let p = cursor {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let raw = ifa.ifa_data,
               !String(cString: ifa.ifa_name).hasPrefix("lo") {
                let data = raw.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(data.ifi_ibytes)
                tx += UInt64(data.ifi_obytes)
            }
            cursor = ifa.ifa_next
        }
        let now = Date()
        if let last = lastNet {
            let dt = max(0.1, now.timeIntervalSince(last.at))
            download = rx >= last.rx ? Double(rx - last.rx) / dt : 0
            upload = tx >= last.tx ? Double(tx - last.tx) / dt : 0
            downloadHistory = Array((downloadHistory + [download]).suffix(Self.historyLength))
        }
        lastNet = (rx, tx, now)
    }
}

extension Double {
    /// 1.2 GB, 340 MB …
    var orbitBytes: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .memory) }
    var orbitRate: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) + "/s" }
}
