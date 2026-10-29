import AppKit
import CoreWLAN
import IOKit
import SwiftUI

/// Readings the runner's popover shows on top of SystemMonitor's: things only worth reading while it's open.
@MainActor @Observable
final class RunnerStats {
    static let shared = RunnerStats()

    struct BatteryDetail: Equatable {
        var cycles: Int?
        /// Max capacity as a share of the design capacity.
        var health: Double?
        var temperature: Double?
        var adapter: String?
    }

    private(set) var pressure: Double?
    private(set) var battery = BatteryDetail()
    private(set) var interface = ""
    private(set) var address: String?
    private(set) var uploadHistory: [Double] = []
    private(set) var gpuHistory: [Double] = []
    private(set) var gpu = GPUUsage.Detail()

    func refresh() {
        pressure = Self.memoryPressure()
        battery = Self.batteryDetail()
        (interface, address) = Self.network()
        gpu = GPUUsage.detail()
        if let g = MenuBarRunner.shared.gpu { gpuHistory = Array((gpuHistory + [g]).suffix(SystemMonitor.historyLength)) }
        let up = SystemMonitor.shared.upload
        uploadHistory = Array((uploadHistory + [up]).suffix(SystemMonitor.historyLength))
    }

    /// The kernel's "memory available" level, turned around into pressure.
    private static func memoryPressure() -> Double? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return max(0, min(1, 1 - Double(level) / 100))
    }

    private static func batteryDetail() -> BatteryDetail {
        var d = BatteryDetail()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return d }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = props?.takeRetainedValue() as? [String: Any] else { return d }
        d.cycles = p["CycleCount"] as? Int
        if let max = (p["AppleRawMaxCapacity"] ?? p["NominalChargeCapacity"]) as? Int, let design = p["DesignCapacity"] as? Int, design > 0 {
            d.health = min(1, Double(max) / Double(design))
        }
        if let t = (p["VirtualTemperature"] ?? p["Temperature"]) as? Int, t > 0 { d.temperature = Double(t) / 100 }
        if let adapter = p["AdapterDetails"] as? [String: Any] {
            if let name = adapter["Name"] as? String, !name.isEmpty { d.adapter = name }
            else if let watts = adapter["Watts"] as? Int, watts > 0 { d.adapter = "%ldW adapter".loc(watts) }
        }
        return d
    }

    /// The interface carrying traffic (Wi-Fi, Ethernet…) and its IPv4 address.
    private static func network() -> (String, String?) {
        let wifi = CWWiFiClient.shared().interface()?.interfaceName
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ("", nil) }
        defer { freeifaddrs(head) }
        var found: (String, String)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  a.ifa_flags & UInt32(IFF_UP) != 0, a.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if found == nil || name == wifi { found = (name, ip) }
        }
        guard let found else { return ("Offline".loc, nil) }
        return (found.0 == wifi ? "Wi-Fi" : "Ethernet".loc, found.1)
    }
}

/// Which sections the status card shows (RunCat's "System Info" switches).
enum RunnerStatSection: String, CaseIterable {
    case cpu, gpu, memory, storage, battery, network

    var key: String { "runner.card.\(rawValue)" }
    var on: Bool { Pref.defaults.object(forKey: key) as? Bool ?? true }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .battery: "Battery"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "cube.transparent"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .battery: "battery.75percent"
        case .network: "network"
        }
    }
}

/// The switches for the runner page.
struct RunnerStatToggles: View {
    var body: some View {
        ForEach(Array(RunnerStatSection.allCases.enumerated()), id: \.element) { i, card in
            if i > 0 { RowDivider() }
            CardToggle(card: card)
        }
    }

    private struct CardToggle: View {
        let card: RunnerStatSection
        @AppStorage private var on: Bool

        init(card: RunnerStatSection) {
            self.card = card
            _on = AppStorage(wrappedValue: true, card.key)
        }

        var body: some View {
            SettingsRow(title: card.title.loc, symbol: card.symbol) {
                Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden()
            }
        }
    }
}

/// RunCat-style status card that opens from the runner in the menu bar.
struct RunnerStatsView: View {
    private var m: SystemMonitor { .shared }
    private var stats: RunnerStats { .shared }
    private var runner: MenuBarRunner { .shared }
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            VStack(spacing: 0) {
                let shown = RunnerStatSection.allCases.filter { $0.on && available($0) }
                ForEach(Array(shown.enumerated()), id: \.element) { i, card in
                    if i > 0 { divider }
                    block(card)
                }
            }
            .padding(.vertical, 4)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: 320)
        .background(Palette.canvas)
        .focusEffectDisabled()
    }

    private func available(_ card: RunnerStatSection) -> Bool {
        switch card {
        case .gpu: runner.gpu != nil
        case .battery: m.battery != nil
        default: true
        }
    }

    @ViewBuilder private func block(_ card: RunnerStatSection) -> some View {
        switch card {
        case .cpu:
            section("cpu", title: "CPU", value: pct(m.cpu.last ?? 0)) {
                detail("System", pct(m.cpuSystem))
                detail("User", pct(m.cpuUser))
                detail("Idle", pct(max(0, 1 - m.cpuUser - m.cpuSystem)))
            } chart: { StatLine(values: m.cpu, fill: true) }
        case .gpu:
            section("cube.transparent", title: "GPU", value: pct(runner.gpu ?? 0)) {
                if let r = stats.gpu.renderer { detail("Renderer", pct(r)) }
                if let t = stats.gpu.tiler { detail("Tiler", pct(t)) }
                if let mem = stats.gpu.memory, mem > 0 { detail("Memory in use", mem.orbitBytes) }
            } chart: { StatLine(values: stats.gpuHistory, fill: true) }
        case .memory:
            section("memorychip", title: "Memory".loc, value: pct(m.memoryTotal > 0 ? m.memoryUsed / m.memoryTotal : 0)) {
                if let p = stats.pressure { detail("Pressure", pct(p), tint: p > 0.7 ? Palette.accent : nil) }
                detail("App memory", m.memoryApp.orbitBytes)
                detail("Wired", m.memoryWired.orbitBytes)
                detail("Compressed", m.memoryCompressed.orbitBytes)
            } chart: { StatLine(values: m.memoryHistory, fill: true) }
        case .storage:
            section("internaldrive", title: "Storage".loc, value: pct(m.diskTotal > 0 ? 1 - m.diskFree / m.diskTotal : 0)) {
                detail("Free", "%@ of %@".loc(m.diskFree.orbitBytes, m.diskTotal.orbitBytes))
            } chart: { StatMeter(value: m.diskTotal > 0 ? 1 - m.diskFree / m.diskTotal : 0) }
        case .battery:
            if let b = m.battery {
                section(b.charging ? "battery.100percent.bolt" : "battery.75percent", title: "Battery".loc, value: "\(b.percent)%") {
                    detail("Power", b.onAC ? (stats.battery.adapter ?? "Power adapter".loc) : "Battery".loc)
                    if let h = stats.battery.health { detail("Health", pct(h)) }
                    if let c = stats.battery.cycles { detail("Cycles", "\(c)") }
                    if let t = stats.battery.temperature { detail("Temperature", String(format: "%.1f°C", t)) }
                } chart: { StatMeter(value: Double(b.percent) / 100) }
            }
        case .network:
            section("network", title: "Network".loc, value: stats.interface) {
                if let ip = stats.address { detail("Local IP", ip) }
                detail("↑ Upload", m.upload.orbitRate)
                detail("↓ Download", m.download.orbitRate)
            } chart: { StatLine(values: m.downloadHistory, fill: false) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RunnerAnimation(id: runner.selected, fps: runner.fps, height: 20, paused: runner.paused)
                .frame(width: 34, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Runner").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.ink)
                Text(runner.paused ? "Paused".loc : "Running at %ld frames a second".loc(Int(runner.fps.rounded())))
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 50)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            footerButton(runner.paused ? "play.fill" : "pause.fill", runner.paused ? "Resume" : "Pause") { runner.setPaused(!runner.paused) }
            footerButton("hare", "Runners") { close(); MainWindow.show(.runner) }
            footerButton("waveform.path.ecg", "Activity Monitor") {
                close()
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"), configuration: .init())
            }
            footerButton("cpu", "System") { close(); MainWindow.show(.system) }
        }
        .padding(8)
    }

    private var divider: some View { Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 56) }

    private func section<D: View, C: View>(_ symbol: String, title: String, value: String,
                                           @ViewBuilder details: () -> D, @ViewBuilder chart: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Text(value).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                }
                chart().frame(height: 18)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) { details() }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private func detail(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        GridRow {
            Text(label.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(tint ?? Palette.ink)
                .gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func footerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                // Two short lines rather than a shrunken or cut "활성 상태 보기".
                Text(title.loc).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// A little history line; values are 0…1 unless `fill` is false, in which case they're scaled to their max.
private struct StatLine: View {
    let values: [Double]
    let fill: Bool

    var body: some View {
        GeometryReader { geo in
            let peak = fill ? 1 : max(values.max() ?? 1, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(1, SystemMonitor.historyLength - 1)),
                        y: geo.size.height * (1 - CGFloat(min(1, v / peak))))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Palette.raised.opacity(0.6))
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                    }
                    .fill(Palette.accent.opacity(0.18))
                    Path { p in p.addLines(pts) }
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

private struct StatMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.raised)
                Capsule().fill(value > 0.9 ? Palette.accent : Palette.ink)
                    .frame(width: max(6, geo.size.width * min(1, value)))
            }
        }
        .frame(height: 6)
        .frame(maxHeight: .infinity)
        .animation(.spring(duration: 0.4), value: value)
    }
}
