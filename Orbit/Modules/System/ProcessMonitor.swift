import AppKit
import Darwin
import IOKit
import Observation

/// Which column a process view is about, like Activity Monitor's tabs.
enum ProcessMetric: String, CaseIterable, Identifiable {
    case cpu, memory, energy, disk, network, gpu
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .energy: "Energy"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .energy: "bolt"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        case .gpu: "square.stack.3d.up"
        }
    }
}

/// One process with Activity Monitor–grade numbers. Rates are per second over the last sample.
struct ProcessRow: Identifiable, Equatable {
    let pid: pid_t
    var id: pid_t { pid }
    var ppid: pid_t = 0
    var uid: uid_t = 0
    /// The process macOS holds responsible for this one: an app for its helpers and XPC services.
    var responsible: pid_t = 0
    var name = ""
    var path = ""
    /// "Renderer", "GPU", "Network Service"… for browser and Electron helpers.
    var role: String?
    /// macOS doesn't share the detailed counters of other users' processes; only CPU and memory from `ps`.
    var restricted = false
    var cpu: Double = 0
    var cpuTime: Double = 0
    var threads = 0
    var memory: UInt64 = 0
    var realMemory: UInt64 = 0
    var wakeups: Double = 0
    /// Milliwatts, from the kernel's billed energy counter.
    var energy: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var diskReadTotal: UInt64 = 0
    var diskWriteTotal: UInt64 = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var netInTotal: UInt64 = 0
    var netOutTotal: UInt64 = 0
    var gpu: Double = 0
    var gpuTime: Double = 0
    var started: Date?

    func value(_ m: ProcessMetric) -> Double {
        switch m {
        case .cpu: cpu
        case .memory: Double(memory)
        case .energy: energy
        case .disk: diskRead + diskWrite
        case .network: netIn + netOut
        case .gpu: gpu
        }
    }
}

/// The whole machine's memory, the way Activity Monitor's Memory tab splits it.
struct MemoryBreakdown: Equatable {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// 0…1, how hard macOS is working to find memory.
    var pressure: Double = 0
    /// 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int = 1
    var used: UInt64 { app + wired + compressed }
}

struct CPULoad: Equatable {
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
}

/// Samples every process while a process view is open, and nothing at all otherwise.
@MainActor @Observable
final class ProcessMonitor {
    static let shared = ProcessMonitor()
    static let historyLength = 30 // 60s at one sample every 2s

    private(set) var rows: [ProcessRow] = []
    private(set) var memory = MemoryBreakdown()
    private(set) var load = CPULoad()
    private(set) var history: [pid_t: [Double]] = [:]
    private(set) var memoryHistory: [pid_t: [Double]] = [:]
    private(set) var apps: [pid_t: NSRunningApplication] = [:]
    private(set) var sampledAt: Date?
    /// Network and GPU need extra work per sample, so they run only while their tab shows.
    var metric: ProcessMetric = .cpu

    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.lyu.orbit.processes", qos: .utility)
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    func watch(_ on: Bool) {
        watchers += on ? 1 : -1
        watchers = max(0, watchers)
        if watchers > 0, timer == nil {
            tick()
            let t = Timer(timeInterval: 2, repeats: true) { _ in Task { @MainActor in ProcessMonitor.shared.tick() } }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if watchers == 0 {
            timer?.invalidate()
            timer = nil
            // Nothing kept around while no one looks.
            rows = []
            history = [:]
            memoryHistory = [:]
            let sampler = self.sampler
            queue.async { sampler.reset() }
        }
    }

    func refreshNow() { tick() }

    private func tick() {
        guard !busy else { return }
        busy = true
        let network = metric == .network
        let gpu = metric == .gpu || metric == .energy
        let sampler = self.sampler
        queue.async {
            let rows = sampler.sample(network: network, gpu: gpu)
            let memory = sampler.memoryBreakdown()
            let load = sampler.cpuLoad()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ProcessMonitor.shared.apply(rows, memory, load) }
            }
        }
    }

    private func apply(_ new: [ProcessRow], _ mem: MemoryBreakdown, _ cpu: CPULoad) {
        busy = false
        guard watchers > 0 else { return }
        var running: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { running[app.processIdentifier] = app }
        apps = running
        var h: [pid_t: [Double]] = [:], mh: [pid_t: [Double]] = [:]
        for r in new {
            h[r.pid] = Array(((history[r.pid] ?? []) + [r.cpu]).suffix(Self.historyLength))
            mh[r.pid] = Array(((memoryHistory[r.pid] ?? []) + [Double(r.memory)]).suffix(Self.historyLength))
        }
        history = h
        memoryHistory = mh
        rows = new
        memory = mem
        load = cpu
        sampledAt = Date()
    }

    // MARK: Identity

    func app(for row: ProcessRow) -> NSRunningApplication? {
        apps[row.pid] ?? apps[row.responsible]
    }

    func icon(for row: ProcessRow) -> NSImage {
        if let app = apps[row.pid], let icon = app.icon { return icon }
        // Helpers live inside their app's bundle; show the app they belong to.
        let key = Self.bundlePath(of: row.path) ?? row.path
        if let cached = icons[key] { return cached }
        let image: NSImage
        if key.hasSuffix(".app") || key.hasSuffix(".appex") || key.hasSuffix(".xpc") {
            image = NSWorkspace.shared.icon(forFile: key)
        } else {
            image = NSImage(systemSymbolName: row.uid == 0 ? "gearshape.2" : "terminal", accessibilityDescription: nil) ?? NSImage()
        }
        icons[key] = image
        return image
    }

    /// The outermost `.app` the executable sits in.
    nonisolated static func bundlePath(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    // MARK: On demand (detail panel)

    nonisolated static func arguments(_ pid: pid_t) -> [String] { ProcessSampler.arguments(pid) }

    nonisolated static func openFiles(_ pid: pid_t) -> Int? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        return Int(size) / MemoryLayout<proc_fdinfo>.stride
    }

    /// Listening and connected sockets, via lsof. Only for processes you own.
    nonisolated static func ports(_ pid: pid_t) async -> [String] {
        let out = await Shell.runAsync("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-i"]).output
        return out.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 9 else { return nil }
            return cols[7...].joined(separator: " ")
        }
    }

    /// A 3-second `sample` report, or nil when macOS doesn't allow it (other users' processes).
    nonisolated static func sample(_ pid: pid_t) async -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-sample-\(pid).txt")
        let r = await Shell.runAsync("/usr/bin/sample", ["\(pid)", "3", "-file", file.path])
        defer { try? FileManager.default.removeItem(at: file) }
        guard r.status == 0, let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text
    }

    // MARK: Ending processes

    /// Processes macOS can't do without; ending them logs you out or freezes the Mac.
    nonisolated static let critical: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logd", "opendirectoryd", "configd",
        "securityd", "coreservicesd", "notifyd", "powerd", "cfprefsd", "UserEventAgent", "mds", "syslogd",
        "kextd", "kernelmanagerd", "diskarbitrationd", "fseventsd", "mDNSResponder", "watchdogd", "runningboardd",
        "trustd", "distnoted", "sandboxd", "tccd", "airportd", "bluetoothd", "coreaudiod", "hidd",
    ]

    func canEnd(_ row: ProcessRow) -> Bool {
        row.pid > 1 && row.pid != getpid() && !Self.critical.contains(row.name)
    }

    /// Quit asks nicely (apps get to save); force quit doesn't. Returns an error message on failure.
    func end(_ row: ProcessRow, force: Bool) -> String? {
        guard canEnd(row) else { return "macOS needs this process to keep running." }
        if let app = apps[row.pid] {
            let ok = force ? app.forceTerminate() : app.terminate()
            if ok { return nil }
        }
        if kill(row.pid, force ? SIGKILL : SIGTERM) == 0 { return nil }
        return errno == EPERM ? "It belongs to another user or to macOS, so Orbit isn't allowed to end it." : "Couldn’t end it."
    }
}

/// The sampling itself, kept off the main thread. Not thread-safe: one queue only.
final class ProcessSampler: @unchecked Sendable {
    private struct Previous {
        var start: UInt64
        var cpu: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
        var wakeups: UInt64
        var energy: UInt64
    }

    private var previous: [pid_t: Previous] = [:]
    private var previousTime: UInt64 = 0
    private var gpuPrevious: [pid_t: UInt64] = [:]
    private var gpuTime: UInt64 = 0
    private var netPrevious: [pid_t: (UInt64, UInt64)] = [:]
    private var netTime: UInt64 = 0
    private var roles: [String: String?] = [:]
    private var cpuTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    func reset() {
        netTop.stop()
        previous = [:]
        gpuPrevious = [:]
        netPrevious = [:]
        previousTime = 0
        gpuTime = 0
        netTime = 0
    }

    func sample(network: Bool, gpu: Bool) -> [ProcessRow] {
        let now = mach_absolute_time()
        let elapsed = previousTime > 0 ? Double(now - previousTime) * timebase / 1e9 : 0
        previousTime = now
        let ps = psTable()
        var next: [pid_t: Previous] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(ps.count + 32)

        for pid in allPids() {
            var row = ProcessRow(pid: pid)
            var bsd = proc_bsdinfo()
            let haveBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            row.path = Self.path(pid)
            if haveBSD {
                row.ppid = pid_t(bsd.pbi_ppid)
                row.uid = bsd.pbi_uid
                row.started = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec))
            } else if let p = ps[pid] {
                row.ppid = p.ppid
                row.uid = p.uid
            }
            row.name = !row.path.isEmpty ? (row.path as NSString).lastPathComponent
                : (haveBSD ? Self.string(bsd.pbi_name) : (ps[pid]?.command ?? "\(pid)"))
            if row.name.isEmpty { row.name = ps[pid]?.command ?? "\(pid)" }
            if pid == 0 { row.name = "kernel_task" }
            row.responsible = responsibleFn?(pid) ?? pid
            if row.responsible <= 0 { row.responsible = pid }

            if let ru = Self.rusage(pid) {
                let cpu = ru.ri_user_time + ru.ri_system_time
                let wake = ru.ri_pkg_idle_wkups + ru.ri_interrupt_wkups
                row.cpuTime = Double(cpu) * timebase / 1e9
                row.memory = ru.ri_phys_footprint
                row.realMemory = ru.ri_resident_size
                row.diskReadTotal = ru.ri_diskio_bytesread
                row.diskWriteTotal = ru.ri_diskio_byteswritten
                let mine = Previous(start: ru.ri_proc_start_abstime, cpu: cpu, diskRead: ru.ri_diskio_bytesread,
                                    diskWrite: ru.ri_diskio_byteswritten, wakeups: wake, energy: ru.ri_billed_energy)
                // A reused pid is a new process: no rate until the next sample.
                if elapsed > 0, let p = previous[pid], p.start == mine.start {
                    row.cpu = Double(cpu &- p.cpu) * timebase / 1e9 / elapsed * 100
                    row.diskRead = Double(mine.diskRead &- p.diskRead) / elapsed
                    row.diskWrite = Double(mine.diskWrite &- p.diskWrite) / elapsed
                    row.wakeups = Double(wake &- p.wakeups) / elapsed
                    row.energy = Double(mine.energy &- p.energy) / elapsed / 1e6
                }
                next[pid] = mine
                var task = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                    row.threads = Int(task.pti_threadnum)
                }
            } else if let p = ps[pid] {
                row.restricted = true
                row.cpu = p.cpu
                row.memory = p.rss
                row.realMemory = p.rss
            } else {
                continue
            }
            if row.name.contains("Helper") || row.name.contains("helper") { row.role = role(pid, name: row.name, start: row.started) }
            rows.append(row)
        }
        previous = next

        if gpu { applyGPU(&rows, now: now) } else { gpuPrevious = [:]; gpuTime = 0 }
        if network { applyNetwork(&rows, now: now) } else if netTime > 0 || !netPrevious.isEmpty {
            netTop.stop()
            netPrevious = [:]
            netTime = 0
        }
        return rows
    }

    // MARK: Machine-wide

    func memoryBreakdown() -> MemoryBreakdown {
        var m = MemoryBreakdown()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if ok == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let inner = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
            m.app = (inner > purgeable ? inner - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
            m.free = UInt64(stats.free_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            m.swapUsed = swap.xsu_used
            m.swapTotal = swap.xsu_total
        }
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 { m.pressure = max(0, min(1, 1 - Double(level) / 100)) }
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressureLevel = Int(level) }
        return m
    }

    func cpuLoad() -> CPULoad {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return CPULoad() }
        let t = info.cpu_ticks
        let now = (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)) // user, system, idle, nice
        defer { cpuTicks = (now.0, now.1, now.2, now.3) }
        guard let p = cpuTicks else { return CPULoad() }
        let user = Double(now.0 &- p.user + now.3 &- p.nice), system = Double(now.1 &- p.system), idle = Double(now.2 &- p.idle)
        let total = user + system + idle
        guard total > 0 else { return CPULoad() }
        return CPULoad(user: user / total, system: system / total, idle: idle / total)
    }

    // MARK: GPU (per-client time in the GPU driver's registry entries, as Activity Monitor reads it)

    private func applyGPU(_ rows: inout [ProcessRow], now: UInt64) {
        var totals: [pid_t: UInt64] = [:]
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let accel = IOIteratorNext(it), accel != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let client = IOIteratorNext(children), client != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]],
                       let pid = Self.creatorPid(creator) {
                        let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                        totals[pid, default: 0] += ns
                    }
                    IOObjectRelease(client)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accel)
        }
        let elapsed = gpuTime > 0 ? Double(now - gpuTime) * timebase / 1e9 : 0
        for i in rows.indices {
            guard let ns = totals[rows[i].pid] else { continue }
            rows[i].gpuTime = Double(ns) / 1e9
            if elapsed > 0, let p = gpuPrevious[rows[i].pid], ns >= p {
                rows[i].gpu = min(100, Double(ns - p) / 1e9 / elapsed * 100)
            }
        }
        gpuPrevious = totals
        gpuTime = now
    }

    /// "pid 409, WindowServer" → 409.
    private static func creatorPid(_ s: String) -> pid_t? {
        guard s.hasPrefix("pid ") else { return nil }
        let digits = s.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    // MARK: Network (nettop's per-process byte counters; macOS has no API for them)

    private let netTop = NetTop()

    private func applyNetwork(_ rows: inout [ProcessRow], now: UInt64) {
        netTop.start()
        let totals = netTop.latest
        let elapsed = netTime > 0 ? Double(now - netTime) * timebase / 1e9 : 0
        for i in rows.indices {
            guard let t = totals[rows[i].pid] else { continue }
            rows[i].netInTotal = t.0
            rows[i].netOutTotal = t.1
            if elapsed > 0, let p = netPrevious[rows[i].pid], t.0 >= p.0, t.1 >= p.1 {
                rows[i].netIn = Double(t.0 - p.0) / elapsed
                rows[i].netOut = Double(t.1 - p.1) / elapsed
            }
        }
        if !totals.isEmpty {
            netPrevious = totals
            netTime = now
        }
    }

    func stopNetwork() { netTop.stop() }

    // MARK: Per-process reads

    private func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let c = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return Array(buf.prefix(Int(max(0, c)))).filter { $0 >= 0 }
    }

    private struct PSEntry { var ppid: pid_t; var uid: uid_t; var cpu: Double; var rss: UInt64; var command: String }

    /// `ps` is allowed to read every process (it's setuid), so it fills in the ones libproc can't.
    private func psTable() -> [pid_t: PSEntry] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,pcpu=,rss=,comm="]).output
        var table: [pid_t: PSEntry] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard cols.count == 6, let pid = pid_t(cols[0]) else { continue }
            let command = String(cols[5])
            table[pid] = PSEntry(ppid: pid_t(cols[1]) ?? 0, uid: uid_t(cols[2]) ?? 0, cpu: Double(cols[3]) ?? 0,
                                 rss: (UInt64(cols[4]) ?? 0) * 1024, command: (command as NSString).lastPathComponent)
        }
        return table
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v6? {
        var r = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &r) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return ok == 0 ? r : nil
    }

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// What kind of helper a Chromium/Electron child is, from its command line. Read once per process.
    private func role(_ pid: pid_t, name: String, start: Date?) -> String? {
        let key = "\(pid)-\(start?.timeIntervalSince1970 ?? 0)"
        if let cached = roles[key] { return cached }
        let args = Self.arguments(pid)
        var role: String?
        if let sub = args.first(where: { $0.hasPrefix("--utility-sub-type=") }) {
            let service = sub.dropFirst("--utility-sub-type=".count).split(separator: ".").last.map(String.init) ?? ""
            role = Self.readable(service)
        } else if let type = args.first(where: { $0.hasPrefix("--type=") }) {
            let t = String(type.dropFirst("--type=".count))
            role = ["renderer": "Renderer", "gpu-process": "GPU", "utility": "Utility", "zygote": "Zygote",
                    "crashpad-handler": "Crash reporter", "broker": "Broker"][t] ?? t
            if t == "renderer", args.contains(where: { $0.hasPrefix("--extension-process") }) { role = "Extension" }
        }
        if roles.count > 4000 { roles.removeAll() }
        roles[key] = role
        return role
    }

    /// "NetworkService" → "Network Service".
    private static func readable(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// The command line, from the kernel's saved argument block (your own processes only).
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 } // executable path
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while i < size, args.count < Int(argc) {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

/// One long-running `nettop` streaming cumulative byte counts per process; a single run waits a full interval, this doesn't.
private final class NetTop: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var buffer = ""
    private var frame: [pid_t: (UInt64, UInt64)] = [:]
    private var last: [pid_t: (UInt64, UInt64)] = [:]

    var latest: [pid_t: (UInt64, UInt64)] { lock.withLock { last } }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard process == nil else { return }
        let p = Process()
        // Through a pseudo-terminal: into a plain pipe nettop buffers for minutes.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/usr/bin/nettop", "-P", "-L", "0", "-s", "1", "-x", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice // script quits at once when its stdin is anything else
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(String(decoding: data, as: UTF8.self))
        }
        do { try p.run(); process = p } catch { out.fileHandleForReading.readabilityHandler = nil }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        buffer = ""
        frame = [:]
        last = [:]
    }

    private func consume(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        guard process != nil else { return }
        buffer += chunk
        // A terminal ends lines with "\r\n", which Swift counts as one character.
        while let nl = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = buffer[..<nl].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...nl)
            if line.hasPrefix(",") {
                // A header starts the next frame; the one before it is complete.
                if !frame.isEmpty { last = frame }
                frame = [:]
                continue
            }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = pid_t(cols[0][cols[0].index(after: dot)...]) else { continue }
            frame[pid] = (UInt64(cols[1]) ?? 0, UInt64(cols[2]) ?? 0)
        }
    }
}
