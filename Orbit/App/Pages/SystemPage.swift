import AppKit
import SwiftUI

struct SystemPage: View {
    private var monitor: SystemMonitor { .shared }

    private static let tools: [OrbitAction] = [.colorPicker, .shelf, .captureTimed, .keepAwake]
    private static let system: [OrbitAction] = [.lockScreen, .sleepDisplay, .darkMode, .desktopIcons, .hiddenFiles, .emptyTrash, .ejectAll, .cleanKeyboard]

    @State private var detail: ProcessMetric?

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if let detail {
                    ProcessesView(metric: detail) { open(nil, proxy) }
                        .transition(.opacity.combined(with: .offset(x: 24)))
                } else {
                    overview(proxy).transition(.opacity.combined(with: .offset(x: -24)))
                }
            }
        }
        .onAppear { monitor.watch(true) }
        .onDisappear { monitor.watch(false) }
    }

    private func open(_ metric: ProcessMetric?, _ proxy: ScrollViewProxy) {
        withAnimation(.spring(duration: 0.35, bounce: 0.05)) { detail = metric }
        proxy.scrollTo("page-top", anchor: .top)
    }

    private func overview(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "System", subtitle: "Live stats and one-click Mac utilities. Click a card to see what's using it.") {
                Button("Processes") { open(.cpu, proxy) }.buttonStyle(PillButtonStyle(prominent: false))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                StatTile(title: "CPU", symbol: "cpu", value: percent(monitor.cpu.last),
                         detail: "%ld cores".loc(ProcessInfo.processInfo.activeProcessorCount), history: monitor.cpu) { open(.cpu, proxy) }
                StatTile(title: "Memory", symbol: "memorychip", value: monitor.memoryUsed.orbitBytes,
                         detail: "of %@".loc(monitor.memoryTotal.orbitBytes), history: monitor.memoryHistory) { open(.memory, proxy) }
                StatTile(title: "Network", symbol: "arrow.up.arrow.down", value: "↓ \(monitor.download.orbitRate)",
                         detail: "↑ \(monitor.upload.orbitRate)", history: normalized(monitor.downloadHistory)) { open(.network, proxy) }
                StatTile(title: "Disk", symbol: "internaldrive", value: "%@ free".loc(monitor.diskFree.orbitBytes),
                         detail: "of %@".loc(monitor.diskTotal.orbitBytes),
                         fill: monitor.diskTotal > 0 ? 1 - monitor.diskFree / monitor.diskTotal : nil) { open(.disk, proxy) }
            }

            HStack(spacing: 12) {
                MiniStat(symbol: monitor.battery?.charging == true ? "battery.100percent.bolt" : "battery.75percent",
                         value: monitor.battery.map { "\($0.percent)%" } ?? "—",
                         label: monitor.battery.map { $0.onAC ? "Power adapter" : "On battery" } ?? "No battery")
                MiniStat(symbol: "thermometer.medium", value: thermalLabel, label: "Thermal state")
                MiniStat(symbol: "clock.arrow.circlepath", value: KeepAwake.format(monitor.uptime), label: "Uptime")
            }

            if !monitor.fans.isEmpty || monitor.temperatures.chip != nil {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Fans & temperature")
                    FanCard(fans: monitor.fans, temps: monitor.temperatures, history: monitor.chipHistory)
                    if !monitor.fans.isEmpty { FanControlCard(fans: monitor.fans, chip: monitor.temperatures.chip) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Tools")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(Self.tools) { ActionCard(action: $0) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Mac")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(Self.system) { ActionCard(action: $0) }
                }
            }

            ScrollingSection()
        }
    }

    private func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    private func normalized(_ values: [Double]) -> [Double] {
        let peak = max(values.max() ?? 0, 64 * 1024)
        return values.map { $0 / peak }
    }

    private var thermalLabel: String {
        switch monitor.thermal {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        @unknown default: "—"
        }
    }
}

private struct StatTile: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String
    var history: [Double] = []
    var fill: Double?
    var action: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title.loc.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                Spacer()
                HStack(spacing: 2) {
                    Text("Details".loc).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .opacity(hovering ? 1 : 0.45)
            }
            .foregroundStyle(Palette.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.loc).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(detail.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            Group {
                if let fill {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Palette.raised)
                            Capsule().fill(fill > 0.9 ? Palette.accent : Palette.ink).frame(width: max(6, g.size.width * fill))
                        }
                    }
                    .frame(height: 8)
                    .padding(.top, 22)
                } else {
                    Sparkline(values: history)
                }
            }
            .frame(height: 38)
        }
        .padding(16)
        .card(hovering: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: action)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// History line with a soft fill; the latest point is the orange satellite.
struct Sparkline: View {
    let values: [Double]
    var length = SystemMonitor.historyLength

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Palette.ink.opacity(0.12), Palette.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(Palette.accent).frame(width: 7, height: 7).position(pts.last!)
                } else {
                    Rectangle().fill(Palette.hairline).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let n = length
        let step = size.width / CGFloat(max(1, n - 1))
        let start = CGFloat(n - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: start + CGFloat(i) * step, y: size.height - 3 - CGFloat(min(1, max(0, v))) * (size.height - 6))
        }
    }
}

private struct MiniStat: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 1) {
                Text(value.loc).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                Text(label.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .card()
    }
}

/// Live fan speed and the hottest sensors, read straight from the SMC.
private struct FanCard: View {
    let fans: [SMC.Fan]
    let temps: SMC.Temperatures
    let history: [Double]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(fans) { fan in
                    HStack(spacing: 14) {
                        FanGlyph(level: fan.level)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fans.count > 1 ? "Fan %ld".loc(fan.id + 1) : "Fan".loc)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int(fan.rpm.rounded()))").font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundStyle(Palette.ink).contentTransition(.numericText())
                                Text("rpm").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                            }
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Palette.raised)
                                    Capsule().fill(fan.level > 0.8 ? Palette.accent : Palette.ink)
                                        .frame(width: max(6, g.size.width * fan.level))
                                }
                            }
                            .frame(height: 6)
                            Text("%ld – %ld rpm".loc(Int(fan.min), Int(fan.max)))
                                .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary.opacity(0.7))
                        }
                    }
                }
                if fans.isEmpty {
                    Text("No fans — this Mac is cooled passively.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(Palette.hairline).frame(width: 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    reading("Chip", temps.chip)
                    reading("Battery", temps.battery)
                    reading("SSD", temps.storage)
                }
                Sparkline(values: history).frame(height: 38)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .card()
        .animation(.easeOut(duration: 0.4), value: fans)
    }

    private func reading(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.map { "\(Int($0.rounded()))°" } ?? "—")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle((value ?? 0) >= 90 ? Palette.accent : Palette.ink)
                .contentTransition(.numericText())
            Text(label.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// Manual fan control: set up the helper once, then pick how the fans should behave.
private struct FanControlCard: View {
    let fans: [SMC.Fan]
    let chip: Double?
    @Bindable private var control = FanControl.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch control.helper {
            case .off: setup
            case .needsApproval: approval
            case .ready: controls
            }
            if let error = control.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Palette.accent)
            }
        }
        .padding(18)
        .card()
        .animation(.spring(duration: 0.35, bounce: 0.15), value: control.helper)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: control.mode)
        .onAppear { control.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if control.helper != .ready { control.refresh() }
        }
    }

    private var setup: some View {
        HStack(spacing: 14) {
            icon("fan.badge.automatic")
            VStack(alignment: .leading, spacing: 3) {
                Text("Control the fans yourself").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                Text("Orbit needs a small helper that runs with administrator rights to set fan speeds. You allow it once.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Turn On") { control.installHelper() }.buttonStyle(PillButtonStyle(prominent: true))
        }
    }

    private var approval: some View {
        HStack(spacing: 14) {
            icon("lock.shield")
            VStack(alignment: .leading, spacing: 3) {
                Text("Allow Orbit in System Settings").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                Text("General → Login Items & Extensions → turn on Orbit under “Allow in the Background”.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Open Settings") { SMAppServiceOpener.open() }.buttonStyle(PillButtonStyle(prominent: true))
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            Text("Fan control").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
            if let target = control.target {
                Text("Aiming for %ld rpm".loc(Int(target.rounded())))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Palette.accent.opacity(0.14)))
                    .contentTransition(.numericText())
            }
            Spacer()
            ChipPicker(selection: $control.mode, options: FanControl.Mode.allCases.map { ($0, $0.title) })
        }

        switch control.mode {
        case .auto:
            caption("macOS decides, like it always has.")
        case .max:
            caption("Every fan at its top speed — loud, but the coolest your Mac gets.")
        case .fixed:
            HStack(spacing: 12) {
                Image(systemName: "fan").foregroundStyle(Palette.inkSecondary)
                Slider(value: $control.fixedLevel, in: 0...1)
                Text("%ld rpm".loc(Int(fixedRPM.rounded())))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                    .frame(width: 80, alignment: .trailing).contentTransition(.numericText())
            }
        case .curve:
            CurveGraph(low: control.curveLow, high: control.curveHigh, chip: chip,
                       minRPM: fans.first?.min ?? 0, maxRPM: fans.first?.max ?? 0)
                .frame(height: 96)
            HStack(spacing: 18) {
                labeled("Starts at") {
                    ChipPicker(selection: $control.curveLow, options: [(45.0, "45°"), (55.0, "55°"), (65.0, "65°"), (75.0, "75°")])
                }
                labeled("Full speed at") {
                    ChipPicker(selection: $control.curveHigh, options: [(80.0, "80°"), (85.0, "85°"), (90.0, "90°")])
                }
                Spacer()
            }
            caption("Below the start temperature macOS stays in charge, so a cool Mac stays quiet.")
        }

        HStack {
            Text("Above 95° the fans always run at full speed. If Orbit quits, they go back to macOS within 15 seconds.")
                .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Remove Helper") { control.removeHelper() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
        }
    }

    private var fixedRPM: Double {
        guard let f = fans.first else { return 0 }
        return f.min + (f.max - f.min) * control.fixedLevel
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.ink)
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.raised))
    }

    private func caption(_ text: String) -> some View {
        Text(text.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            content()
        }
    }
}

private enum SMAppServiceOpener {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

/// Fan speed against chip temperature for the by-temperature mode, with where the chip is now.
private struct CurveGraph: View {
    let low: Double
    let high: Double
    let chip: Double?
    let minRPM: Double
    let maxRPM: Double

    private let range = 30.0...100.0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height - 16
            let x = { (t: Double) in CGFloat((t - range.lowerBound) / (range.upperBound - range.lowerBound)) * w }
            ZStack(alignment: .topLeading) {
                // macOS-controlled stretch, then Orbit's ramp, then flat out.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: x(low), y: h))
                }
                .stroke(Palette.inkSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
                Path { p in
                    p.move(to: CGPoint(x: x(low), y: h * 0.8))
                    p.addLine(to: CGPoint(x: x(high), y: 2))
                    p.addLine(to: CGPoint(x: w, y: 2))
                }
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let chip {
                    let t = min(range.upperBound, max(range.lowerBound, chip))
                    let level = chip < low ? nil : min(1, (chip - low) / max(1, high - low))
                    Circle().fill(Palette.accent).frame(width: 10, height: 10)
                        .position(x: x(t), y: level.map { h * 0.8 - CGFloat($0) * (h * 0.8 - 2) } ?? h)
                        .animation(.easeOut(duration: 0.6), value: chip)
                }
                HStack {
                    Text("30°"); Spacer(); Text("\(Int(low))°").foregroundStyle(Palette.ink); Spacer(); Text("\(Int(high))°").foregroundStyle(Palette.ink); Spacer(); Text("100°")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                .offset(y: h + 4)
                Text("%ld rpm".loc(Int(maxRPM))).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary).offset(y: -2).padding(.leading, 2)
            }
        }
    }
}

/// A fan that spins faster the harder it's working.
private struct FanGlyph: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Image(systemName: "fan")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.ink)
                .rotationEffect(.degrees((t * (60 + level * 540)).truncatingRemainder(dividingBy: 360)))
        }
        .frame(width: 46, height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
    }
}
