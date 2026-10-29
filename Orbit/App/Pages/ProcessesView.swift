import AppKit
import SwiftUI

/// Every process on the Mac, grouped under the app that owns it, with the numbers behind each System card.
struct ProcessesView: View {
    @State var metric: ProcessMetric
    let close: () -> Void

    private var monitor: ProcessMonitor { .shared }
    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var grouped = true
    @State private var sort: ColumnID?
    @State private var ascending = false
    @State private var expanded: Set<pid_t> = []
    @State private var selected: pid_t?
    @State private var limit = 120

    enum Scope: Hashable { case all, apps, mine, system }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            ChipPicker(selection: $metric, options: ProcessMetric.allCases.map { ($0, $0.title) })
            summary
            controls
            table
        }
        .onAppear { monitor.metric = metric; monitor.watch(true) }
        .onDisappear { monitor.watch(false) }
        .onChange(of: metric) {
            monitor.metric = metric
            sort = nil
            monitor.refreshNow()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: close) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("System".loc).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Palette.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            PageHeader(title: "Processes", subtitle: "What each app — and every helper behind it — is using right now.") {
                Text("%ld processes".loc(monitor.rows.count))
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                    .contentTransition(.numericText())
            }
        }
    }

    // MARK: Summary

    @ViewBuilder private var summary: some View {
        switch metric {
        case .cpu:
            let l = monitor.load
            SummaryCard {
                StackBar(parts: [(l.system, Palette.accent), (l.user, Palette.ink)])
                HStack(spacing: 0) {
                    Figure(title: "System", value: pct(l.system * 100), dot: Palette.accent)
                    Figure(title: "User", value: pct(l.user * 100), dot: Palette.ink)
                    Figure(title: "Idle", value: pct(l.idle * 100), dot: Palette.raised)
                    Figure(title: "Threads", value: "\(monitor.rows.reduce(0) { $0 + $1.threads })")
                }
            }
        case .memory:
            let m = monitor.memory
            let total = Double(max(1, m.total))
            SummaryCard {
                StackBar(parts: [(Double(m.wired) / total, Palette.accent), (Double(m.app) / total, Palette.ink),
                                 (Double(m.compressed) / total, Palette.inkSecondary), (Double(m.cached) / total, Palette.ink.opacity(0.18))])
                HStack(spacing: 0) {
                    Figure(title: "App memory", value: bytes(m.app), dot: Palette.ink)
                    Figure(title: "Wired", value: bytes(m.wired), dot: Palette.accent)
                    Figure(title: "Compressed", value: bytes(m.compressed), dot: Palette.inkSecondary)
                    Figure(title: "Cached files", value: bytes(m.cached), dot: Palette.ink.opacity(0.18))
                }
                HStack(spacing: 0) {
                    Figure(title: "Memory pressure", value: pressureLabel(m), accent: m.pressureLevel > 1)
                    Figure(title: "Used", value: "\(bytes(m.used)) / \(bytes(m.total))")
                    Figure(title: "Swap used", value: m.swapTotal > 0 ? bytes(m.swapUsed) : "—")
                    Figure(title: "Free", value: bytes(m.free))
                }
            }
        case .energy:
            SummaryCard {
                HStack(spacing: 0) {
                    Figure(title: "Power, all processes", value: milliwatts(sum(\.energy)))
                    Figure(title: "Wakeups / s", value: String(format: "%.0f", sum(\.wakeups)))
                    Figure(title: "Battery", value: SystemMonitor.shared.battery.map { "\($0.percent)%" } ?? "—")
                    Figure(title: "Thermal state", value: thermal)
                }
            }
        case .disk:
            SummaryCard {
                HStack(spacing: 0) {
                    Figure(title: "Reading", value: (sum(\.diskRead)).orbitRate)
                    Figure(title: "Writing", value: (sum(\.diskWrite)).orbitRate)
                    Figure(title: "Read since start", value: bytes(monitor.rows.reduce(0) { $0 &+ $1.diskReadTotal }))
                    Figure(title: "Written since start", value: bytes(monitor.rows.reduce(0) { $0 &+ $1.diskWriteTotal }))
                }
            }
        case .network:
            SummaryCard {
                HStack(spacing: 0) {
                    Figure(title: "Receiving", value: sum(\.netIn).orbitRate)
                    Figure(title: "Sending", value: sum(\.netOut).orbitRate)
                    Figure(title: "Received", value: bytes(monitor.rows.reduce(0) { $0 &+ $1.netInTotal }))
                    Figure(title: "Sent", value: bytes(monitor.rows.reduce(0) { $0 &+ $1.netOutTotal }))
                }
            }
        case .gpu:
            SummaryCard {
                HStack(spacing: 0) {
                    Figure(title: "GPU, all processes", value: pct(min(100, sum(\.gpu))))
                    Figure(title: "Using the GPU now", value: "\(monitor.rows.filter { $0.gpu >= 0.1 }.count)")
                    Figure(title: "Chip", value: Self.chipName)
                    Figure(title: "", value: "")
                }
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                TextField("Name, PID or path".loc, text: $query).textFieldStyle(.plain).font(.orbitBody)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            ChipPicker(selection: $scope, options: [(.all, "All"), (.apps, "Apps"), (.mine, "Mine"), (.system, "System")])
            Button { withAnimation(.spring(duration: 0.3)) { grouped.toggle() } } label: {
                Image(systemName: grouped ? "square.stack.3d.up.fill" : "list.bullet")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(grouped ? Palette.canvas : Palette.ink)
                    .frame(width: 30, height: 28)
                    .background(Capsule().fill(grouped ? Palette.ink : Palette.raised))
            }
            .buttonStyle(.plain)
            .help((grouped ? "Showing apps with their helpers" : "Showing every process on its own").loc)
        }
    }

    // MARK: Table

    private var columns: [Column] { Column.columns(for: metric) }

    private var table: some View {
        let groups = visibleGroups
        let peak = max(1, monitor.rows.map { primary.value($0) }.max() ?? 1)
        return VStack(spacing: 0) {
            headerRow
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if monitor.rows.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
            } else if groups.isEmpty {
                Text("No process matches.".loc).font(.orbitBody).foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity).padding(30)
            }
            LazyVStack(spacing: 0) {
                ForEach(groups.prefix(limit)) { g in
                    let open = expanded.contains(g.id) || (!query.isEmpty && g.children.count > 1)
                    let lead = g.leader ?? g.children[0]
                    ProcessLine(row: lead, name: g.name, subtitle: g.subtitle, icon: g.icon, count: g.children.count,
                                values: columns.map { $0.text(groupValue(g, $0)) }, widths: columns.map(\.width),
                                bar: share(groupValue(g, primary), primary, peak: peak),
                                open: open, selected: selected == lead.pid && g.children.count == 1,
                                toggle: { withAnimation(.spring(duration: 0.28)) { expanded.formSymmetricDifference([g.id]) } },
                                select: { select(g.children.count == 1 ? lead.pid : nil, group: g) })
                    if g.children.count == 1, selected == lead.pid { ProcessDetail(row: lead) { selected = nil } }
                    if open && g.children.count > 1 {
                        ForEach(g.children) { r in
                            ProcessLine(row: r, name: r.name, subtitle: Self.subtitle(r), icon: nil, count: 0,
                                        values: columns.map { $0.text($0.value(r)) }, widths: columns.map(\.width),
                                        bar: share(primary.value(r), primary, peak: peak), indent: true, open: false, selected: selected == r.pid,
                                        toggle: {}, select: { select(r.pid, group: nil) })
                            if selected == r.pid { ProcessDetail(row: r) { selected = nil } }
                        }
                    }
                }
            }
            if groups.count > limit {
                Button("Show all %ld".loc(groups.count)) { limit = .max }
                    .buttonStyle(PillButtonStyle(prominent: false)).padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            headerCell("Name", id: .name, width: nil, alignment: .leading).padding(.leading, 40)
            ForEach(columns) { c in headerCell(c.title, id: c.id, width: c.width, alignment: .trailing) }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private func headerCell(_ title: String, id: ColumnID, width: CGFloat?, alignment: Alignment) -> some View {
        let active = (sort ?? primary.id) == id
        return Button {
            if active { ascending.toggle() } else { sort = id; ascending = id == .name }
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title.loc).font(.system(size: 11, weight: active ? .bold : .semibold)).lineLimit(1)
                if active { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(active ? Palette.ink : Palette.inkSecondary)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ pid: pid_t?, group: ProcessGroup?) {
        withAnimation(.spring(duration: 0.28)) {
            if let pid { selected = selected == pid ? nil : pid } else if let group { expanded.formSymmetricDifference([group.id]) }
        }
    }

    // MARK: Grouping

    private var primary: Column { columns.first { $0.id == (sort ?? columns[0].id) } ?? columns[0] }

    private func groupValue(_ g: ProcessGroup, _ c: Column) -> Double {
        c.id == .pid ? Double(g.leader?.pid ?? g.children[0].pid) : g.children.reduce(0) { $0 + c.value($1) }
    }

    /// The bar behind a row: its share of the busiest row's value.
    private func share(_ v: Double, _ c: Column, peak: Double) -> Double {
        guard c.bar else { return 0 }
        switch c.id {
        case .cpu: return min(1, v / (100 * Double(ProcessInfo.processInfo.activeProcessorCount)) * 4)
        case .memory: return min(1, v / Double(max(1, monitor.memory.total)) * 4)
        case .gpu: return min(1, v / 100)
        default: return min(1, v / peak)
        }
    }

    private var visibleGroups: [ProcessGroup] {
        let me = getuid()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let alive = Set(monitor.rows.map(\.pid))
        var byOwner: [pid_t: [ProcessRow]] = [:]
        for r in monitor.rows {
            switch scope {
            case .all: break
            case .apps: if !isAppFamily(r) { continue }
            case .mine: if r.uid != me { continue }
            case .system: if r.uid == me { continue }
            }
            if !q.isEmpty, !matches(r, q) { continue }
            byOwner[grouped ? owner(of: r, alive: alive) : r.pid, default: []].append(r)
        }
        let col = primary
        var groups = byOwner.map { id, kids -> ProcessGroup in
            let sortedKids = kids.sorted { col.value($0) != col.value($1) ? col.value($0) > col.value($1) : $0.pid < $1.pid }
            let leader = kids.first { $0.pid == id }
            return ProcessGroup(id: id, leader: leader, children: sortedKids, monitor: monitor)
        }
        groups.sort { a, b in
            if col.id == .name {
                let c = a.name.localizedStandardCompare(b.name)
                return ascending ? c == .orderedAscending : c == .orderedDescending
            }
            let x = groupValue(a, col), y = groupValue(b, col)
            if x == y { return a.id < b.id }
            return ascending ? x < y : x > y
        }
        return groups
    }

    /// Whose process this is: the app it works for, or itself.
    private func owner(of r: ProcessRow, alive: Set<pid_t>) -> pid_t {
        if r.responsible != r.pid, r.responsible > 1, alive.contains(r.responsible) { return r.responsible }
        return r.pid
    }

    private func isAppFamily(_ r: ProcessRow) -> Bool {
        if let app = monitor.apps[r.pid] ?? monitor.apps[r.responsible], app.activationPolicy == .regular { return true }
        return false
    }

    private func matches(_ r: ProcessRow, _ q: String) -> Bool {
        if r.name.lowercased().contains(q) || r.path.lowercased().contains(q) || "\(r.pid)" == q { return true }
        if let role = r.role, role.lowercased().contains(q) { return true }
        if let app = monitor.app(for: r), app.localizedName?.lowercased().contains(q) == true { return true }
        return false
    }

    static func subtitle(_ r: ProcessRow) -> String? {
        if let role = r.role { return role.loc }
        if let d = ProcessDescriptions.text[r.name] { return d.loc }
        return nil
    }

    // MARK: Formatting

    private func sum(_ key: KeyPath<ProcessRow, Double>) -> Double { monitor.rows.reduce(0) { $0 + $1[keyPath: key] } }
    private func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }
    private func bytes(_ v: UInt64) -> String { Double(v).orbitBytes }
    private func milliwatts(_ v: Double) -> String { v >= 1000 ? String(format: "%.2f W", v / 1000) : String(format: "%.0f mW", v) }

    private func pressureLabel(_ m: MemoryBreakdown) -> String {
        switch m.pressureLevel {
        case 4: "Critical".loc
        case 2: "Elevated".loc
        default: "%ld%% · Normal".loc(Int((m.pressure * 100).rounded()))
        }
    }

    private var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Cool".loc
        case .fair: "Warm".loc
        case .serious: "Hot".loc
        case .critical: "Critical".loc
        @unknown default: "—"
        }
    }

    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }()
}

// MARK: - Model

struct ProcessGroup: Identifiable {
    let id: pid_t
    let leader: ProcessRow?
    let children: [ProcessRow]
    let name: String
    let subtitle: String?
    let icon: NSImage

    @MainActor init(id: pid_t, leader: ProcessRow?, children: [ProcessRow], monitor: ProcessMonitor) {
        self.id = id
        self.leader = leader
        self.children = children
        let lead = leader ?? children[0]
        let app = monitor.apps[lead.pid]
        name = app?.localizedName ?? ProcessMonitor.bundlePath(of: lead.path).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? lead.name
        if children.count > 1 {
            subtitle = "%ld processes".loc(children.count)
        } else {
            subtitle = ProcessesView.subtitle(lead)
        }
        icon = monitor.icon(for: lead)
    }
}

enum ColumnID: Hashable { case name, cpu, cpuTime, threads, wakeups, pid, memory, realMemory, energy, gpu, gpuTime, read, write, readTotal, writeTotal, netIn, netOut, inTotal, outTotal, user }

struct Column: Identifiable {
    let id: ColumnID
    let title: String
    var width: CGFloat = 82
    var bar = false
    let value: (ProcessRow) -> Double
    let text: (Double) -> String

    static func columns(for m: ProcessMetric) -> [Column] {
        switch m {
        case .cpu: [cpu, cpuTime, threads, wakeups, pid]
        case .memory: [memory, realMemory, threads, pid]
        case .energy: [energy, wakeups, gpu, cpu, pid]
        case .disk: [read, write, readTotal, writeTotal, pid]
        case .network: [netIn, netOut, inTotal, outTotal, pid]
        case .gpu: [gpu, gpuTime, cpu, pid]
        }
    }

    static let cpu = Column(id: .cpu, title: "% CPU", bar: true, value: \.cpu) { String(format: "%.1f", $0) }
    static let cpuTime = Column(id: .cpuTime, title: "CPU time", width: 90, value: \.cpuTime) { duration($0) }
    static let threads = Column(id: .threads, title: "Threads", width: 64, value: { Double($0.threads) }) { $0 > 0 ? "\(Int($0))" : "—" }
    static let wakeups = Column(id: .wakeups, title: "Wakeups", width: 70, value: \.wakeups) { String(format: "%.0f", $0) }
    static let pid = Column(id: .pid, title: "PID", width: 62, value: { Double($0.pid) }) { "\(Int($0))" }
    static let memory = Column(id: .memory, title: "Memory", width: 90, bar: true, value: { Double($0.memory) }) { $0.orbitBytes }
    static let realMemory = Column(id: .realMemory, title: "Real memory", width: 96, value: { Double($0.realMemory) }) { $0.orbitBytes }
    static let energy = Column(id: .energy, title: "Power", width: 80, bar: true, value: \.energy) {
        $0 >= 1000 ? String(format: "%.2f W", $0 / 1000) : String(format: "%.0f mW", $0)
    }
    static let gpu = Column(id: .gpu, title: "% GPU", width: 64, bar: true, value: \.gpu) { String(format: "%.1f", $0) }
    static let gpuTime = Column(id: .gpuTime, title: "GPU time", width: 90, value: \.gpuTime) { $0 > 0 ? duration($0) : "—" }
    static let read = Column(id: .read, title: "Read / s", width: 88, bar: true, value: \.diskRead) { rate($0) }
    static let write = Column(id: .write, title: "Write / s", width: 88, value: \.diskWrite) { rate($0) }
    static let readTotal = Column(id: .readTotal, title: "Read", width: 80, value: { Double($0.diskReadTotal) }) { $0.orbitBytes }
    static let writeTotal = Column(id: .writeTotal, title: "Written", width: 80, value: { Double($0.diskWriteTotal) }) { $0.orbitBytes }
    static let netIn = Column(id: .netIn, title: "In / s", width: 84, bar: true, value: \.netIn) { rate($0) }
    static let netOut = Column(id: .netOut, title: "Out / s", width: 84, value: \.netOut) { rate($0) }
    static let inTotal = Column(id: .inTotal, title: "Received", width: 80, value: { Double($0.netInTotal) }) { $0 > 0 ? $0.orbitBytes : "—" }
    static let outTotal = Column(id: .outTotal, title: "Sent", width: 80, value: { Double($0.netOutTotal) }) { $0 > 0 ? $0.orbitBytes : "—" }

    static func rate(_ v: Double) -> String { v < 1 ? "—" : v.orbitRate }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
        return String(format: "%d:%05.2f", t / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Rows

private struct ProcessLine: View {
    let row: ProcessRow
    let name: String
    let subtitle: String?
    let icon: NSImage?
    let count: Int
    let values: [String]
    let widths: [CGFloat]
    let bar: Double
    var indent = false
    let open: Bool
    let selected: Bool
    let toggle: () -> Void
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                if count > 1 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggle)
                } else {
                    Color.clear.frame(width: 12)
                }
                if indent {
                    Rectangle().fill(Palette.hairline).frame(width: 1, height: 18).padding(.leading, 8)
                } else {
                    Image(nsImage: icon ?? NSImage()).resizable().interpolation(.high).frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(name).font(indent ? .orbitCaption : .orbitBodyEmphasized).foregroundStyle(Palette.ink).lineLimit(1)
                        if row.restricted {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Palette.inkSecondary)
                                .help("macOS shares only CPU and memory for processes of other users.".loc)
                        }
                    }
                    if let subtitle {
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                Text(v)
                    .font(.system(size: indent ? 11 : 12, weight: i == 0 ? .semibold : .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(i == 0 ? Palette.ink : Palette.inkSecondary)
                    .lineLimit(1)
                    .frame(width: widths[i], alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: indent ? 34 : 42)
        .background(alignment: .leading) {
            GeometryReader { g in
                Rectangle().fill(Palette.ink.opacity(0.05)).frame(width: g.size.width * bar)
            }
        }
        .background(selected ? Palette.accent.opacity(0.12) : Palette.ink.opacity(hovering ? 0.035 : 0))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1).opacity(0.6) }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .animation(.easeOut(duration: 0.25), value: bar)
    }
}

/// Everything known about one process, with the ways to deal with it.
private struct ProcessDetail: View {
    let row: ProcessRow
    let dismiss: () -> Void
    private var monitor: ProcessMonitor { .shared }
    @State private var args: [String] = []
    @State private var files: Int?
    @State private var ports: [String]?
    @State private var sampling = false
    @State private var message: String?

    var body: some View {
        let app = monitor.app(for: row)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    MiniChart(title: "CPU", value: String(format: "%.1f%%", row.cpu),
                              values: (monitor.history[row.pid] ?? []).map { $0 / 100 })
                    MiniChart(title: "Memory", value: Double(row.memory).orbitBytes, values: normalized(monitor.memoryHistory[row.pid] ?? []))
                }
                .frame(width: 210)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    fact("Process", "\(row.name) · PID \(row.pid)")
                    if let app { fact("App", [app.localizedName, app.bundleIdentifier].compactMap { $0 }.joined(separator: " · ")) }
                    if let d = ProcessDescriptions.text[row.name] { fact("What it does", d.loc) }
                    if !row.path.isEmpty { fact("Path", row.path) }
                    fact("User", Self.user(row.uid))
                    fact("Parent", parentText)
                    if row.responsible != row.pid, let owner = monitor.rows.first(where: { $0.pid == row.responsible }) {
                        fact("Works for", "\(monitor.app(for: owner)?.localizedName ?? owner.name) · PID \(owner.pid)")
                    }
                    if let started = row.started { fact("Started", started.formatted(date: .abbreviated, time: .standard)) }
                    if row.threads > 0 { fact("Threads", "\(row.threads)" + (files.map { " · " + "%ld open files".loc($0) } ?? "")) }
                    fact("Disk", "↓ \(Double(row.diskReadTotal).orbitBytes)  ↑ \(Double(row.diskWriteTotal).orbitBytes)")
                    if row.energy > 0 || row.wakeups > 0 { fact("Energy", String(format: "%.0f mW · %.0f wakeups/s", row.energy, row.wakeups)) }
                    if !args.isEmpty { fact("Command", args.joined(separator: " ")) }
                    if let ports, !ports.isEmpty { fact("Network", ports.prefix(6).joined(separator: "\n")) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if monitor.canEnd(row) {
                    Button(app != nil ? "Quit" : "End") { end(force: false) }.buttonStyle(PillButtonStyle(prominent: false))
                    Button("Force Quit") { end(force: true) }.buttonStyle(PillButtonStyle(prominent: false))
                }
                if !row.path.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ProcessMonitor.bundlePath(of: row.path) ?? row.path)])
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
                Button(sampling ? "Sampling…" : "Sample") { sample() }.buttonStyle(PillButtonStyle(prominent: false)).disabled(sampling || row.restricted)
                Button("Copy info") { copy() }.buttonStyle(PillButtonStyle(prominent: false))
                Spacer()
                if let message { Text(message.loc).font(.orbitCaption).foregroundStyle(Palette.accent).lineLimit(2) }
            }
        }
        .padding(16)
        .background(Palette.ink.opacity(0.025))
        .overlay(alignment: .leading) { Rectangle().fill(Palette.accent).frame(width: 2) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .task(id: row.pid) {
            let pid = row.pid
            let restricted = row.restricted
            args = await Task.detached { ProcessMonitor.arguments(pid) }.value
            files = await Task.detached { ProcessMonitor.openFiles(pid) }.value
            if !restricted { ports = await ProcessMonitor.ports(pid) }
        }
    }

    private var parentText: String {
        guard let p = monitor.rows.first(where: { $0.pid == row.ppid }) else { return "PID \(row.ppid)" }
        return "\(p.name) · PID \(p.pid)"
    }

    @ViewBuilder private func fact(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title.loc).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary).gridColumnAlignment(.trailing)
            Text(value).font(.system(size: 11.5)).foregroundStyle(Palette.ink).textSelection(.enabled)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func normalized(_ v: [Double]) -> [Double] {
        let peak = max(v.max() ?? 1, 1)
        let floor = (v.min() ?? 0) * 0.9
        return v.map { ($0 - floor) / max(1, peak - floor) }
    }

    private func end(force: Bool) {
        let alert = NSAlert()
        let name = monitor.app(for: row).flatMap { monitor.apps[row.pid] != nil ? $0.localizedName : nil } ?? row.name
        alert.messageText = (force ? "Force quit “%@”?" : "Quit “%@”?").loc(name)
        alert.informativeText = (force ? "Unsaved changes in it are lost." : "It gets a chance to save first.").loc
        alert.addButton(withTitle: (force ? "Force Quit" : "Quit").loc)
        alert.addButton(withTitle: "Cancel".loc)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        message = monitor.end(row, force: force)
        if message == nil {
            dismiss()
            monitor.refreshNow()
        }
    }

    private func sample() {
        sampling = true
        let pid = row.pid, name = row.name
        Task {
            let text = await ProcessMonitor.sample(pid)
            sampling = false
            guard let text else { message = "macOS didn’t allow sampling this process."; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sample of \(name) (\(pid)).txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        }
    }

    private func copy() {
        let lines = ["\(row.name) (PID \(row.pid))", row.path, String(format: "CPU %.1f%%", row.cpu),
                     "Memory \(Double(row.memory).orbitBytes)", args.joined(separator: " ")].filter { !$0.isEmpty }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        message = "Copied"
    }

    static func user(_ uid: uid_t) -> String {
        guard let pw = getpwuid(uid) else { return "\(uid)" }
        return String(cString: pw.pointee.pw_name) + (uid == 0 ? " (macOS)" : "")
    }
}

// MARK: - Pieces

private struct SummaryCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16)
            .card()
    }
}

private struct Figure: View {
    let title: String
    let value: String
    var dot: Color?
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(accent ? Palette.accent : Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

private struct StackBar: View {
    let parts: [(Double, Color)]
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle().fill(p.1).frame(width: max(0, (g.size.width - CGFloat(parts.count) * 2) * min(1, max(0, p.0))))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.raised)
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.4), value: parts.map(\.0))
    }
}

private struct MiniChart: View {
    let title: String
    let value: String
    let values: [Double]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.loc).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                Spacer()
                Text(value).font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Palette.ink)
            }
            Sparkline(values: values, length: ProcessMonitor.historyLength).frame(height: 30)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.page))
    }
}

/// Plain words for the macOS processes people wonder about.
enum ProcessDescriptions {
    static let text: [String: String] = [
        "kernel_task": "The macOS kernel. Also holds the CPU back on purpose when the Mac runs hot.",
        "launchd": "Starts and keeps every other process running.",
        "WindowServer": "Draws everything on screen: windows, menu bar, animations.",
        "loginwindow": "Your login session; it owns the lock screen.",
        "Dock": "The Dock, Launchpad and Mission Control.",
        "Finder": "The Finder and the desktop.",
        "SystemUIServer": "Menu bar extras macOS itself puts there.",
        "ControlCenter": "Control Center and the menu bar's system icons.",
        "MenuBarAgent": "Lays out the menu bar's icons.",
        "WindowManager": "Stage Manager and window tiling.",
        "NotificationCenter": "Notifications and widgets.",
        "mds": "Spotlight's index server.",
        "mds_stores": "Spotlight writing its index. Busy after big file changes.",
        "mdworker_shared": "Spotlight reading a file's contents to index it.",
        "mdworker": "Spotlight reading a file's contents to index it.",
        "corespotlightd": "Spotlight data from apps.",
        "photoanalysisd": "Photos finding faces, scenes and memories.",
        "mediaanalysisd": "Analyzes photos and videos on device, e.g. for Live Text and search.",
        "bird": "iCloud Drive sync.",
        "cloudd": "iCloud sync for apps.",
        "fileproviderd": "iCloud Drive and other cloud folders in Finder.",
        "nsurlsessiond": "Background downloads and uploads for apps and macOS.",
        "softwareupdated": "Checks for and downloads macOS updates.",
        "backupd": "Time Machine backup.",
        "backupd-helper": "Time Machine backup.",
        "trustd": "Checks certificates for secure connections.",
        "syspolicyd": "Gatekeeper: checks apps before they open.",
        "XProtect": "macOS's built-in malware scanner.",
        "XprotectService": "macOS's built-in malware scanner.",
        "coreaudiod": "All sound in and out of the Mac.",
        "audiomxd": "Mixes sound between apps.",
        "bluetoothd": "Bluetooth devices.",
        "airportd": "Wi-Fi.",
        "mDNSResponder": "Finds names on the network (DNS, AirDrop, AirPlay).",
        "sharingd": "AirDrop, Handoff and the Universal Clipboard.",
        "rapportd": "Talks to your other Apple devices nearby.",
        "powerd": "Sleep, wake and power settings.",
        "thermalmonitord": "Watches temperatures and slows the chip when needed.",
        "coreduetd": "Learns usage patterns to schedule background work.",
        "dasd": "Decides when background tasks may run.",
        "runningboardd": "Manages app lifecycles and their resource budgets.",
        "logd": "The system log.",
        "opendirectoryd": "User accounts and directory lookups.",
        "securityd": "Keychain and security services.",
        "secd": "Keychain sync and security.",
        "tccd": "Privacy permissions (camera, screen, files…).",
        "cfprefsd": "Reads and writes app settings.",
        "distnoted": "Delivers notifications between processes.",
        "fseventsd": "Tells apps which files changed.",
        "diskarbitrationd": "Mounts and ejects disks.",
        "hidd": "Keyboard, mouse and trackpad input.",
        "universalaccessd": "Accessibility features.",
        "siriactionsd": "Shortcuts and Siri actions.",
        "BackgroundShortcutRunner": "Runs a Shortcut in the background.",
        "ColorSampler": "The color picker sampling the screen.",
        "screencaptureui": "Screenshots and screen recording.",
        "replayd": "Screen recording.",
        "Safari": "Safari.",
        "com.apple.WebKit.WebContent": "A web page or tab in Safari or another app's web view.",
        "com.apple.WebKit.Networking": "Network loading for web views.",
        "com.apple.WebKit.GPU": "Graphics for web views.",
        "spindump": "Records why an app hung, for diagnostics.",
        "ReportCrash": "Writes a crash report.",
        "suggestd": "Siri Suggestions from your mail and messages.",
        "knowledge-agent": "Siri and system intelligence knowledge.",
        "biomed": "Collects on-device usage signals for Siri and Screen Time.",
        "triald": "Downloads Apple's feature experiments and models.",
        "amsaccountsd": "Apple ID media accounts (App Store, Music).",
        "storeuid": "App Store sign-in and purchases.",
        "akd": "Apple ID authentication.",
        "apsd": "Apple Push Notification service.",
        "identityservicesd": "iMessage and FaceTime identity.",
        "imagent": "Messages.",
        "callservicesd": "Phone and FaceTime calls.",
        "AMPDeviceDiscoveryAgent": "Finds iPhones and iPads to sync.",
        "Orbit": "This app.",
        "OrbitFanHelper": "Orbit's helper for fans and charging.",
        "Electron": "An Electron app's main process.",
        "node": "A Node.js program.",
        "python3": "A Python program.",
        "Python": "A Python program.",
        "zsh": "A shell, usually a Terminal window or a script.",
        "bash": "A shell, usually a Terminal window or a script.",
        "sshd": "A remote login session.",
        "Code Helper (Plugin)": "VS Code extensions.",
    ]
}
