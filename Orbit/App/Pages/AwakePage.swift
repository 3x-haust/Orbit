import ServiceManagement
import AppKit
import SwiftUI

struct AwakePage: View {
    private var awake: KeepAwake { .shared }
    @AppStorage(Pref.awakeDisplay) private var keepDisplay = true
    @AppStorage(Pref.awakeClosedLid) private var closedLid = false
    @AppStorage(Pref.awakeBatteryFloor) private var batteryFloor = 20
    @AppStorage(Pref.awakeThermal) private var stopWhenHot = true
    @State private var untilTime = Calendar.current.date(byAdding: .hour, value: 2, to: Date()) ?? Date()

    private static let durations: [(String, TimeInterval?)] = [
        ("15m", 900), ("30m", 1800), ("1h", 3600), ("2h", 7200), ("4h", 14400), ("8h", 28800), ("∞", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Awake", subtitle: "Keep your Mac from sleeping — even with the lid closed.")

            AwakeHero()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Start a session")
                HStack(spacing: 8) {
                    ForEach(Self.durations, id: \.0) { label, interval in
                        DurationButton(label: label, active: isActive(interval)) {
                            awake.start(interval.map { .duration($0) } ?? .indefinite)
                        }
                    }
                }
                SettingsGroup {
                    SettingsRow(title: "Until a time", symbol: "clock") {
                        TimeField(date: $untilTime)
                            .fixedSize()
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(Palette.raised))
                        Button("Start") { awake.start(.until(nextOccurrence(of: untilTime))) }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    RowDivider()
                    SettingsRow(title: "While an app is open", subtitle: "Ends when the app quits — great for downloads and renders.", symbol: "app.badge.checkmark") {
                        Menu("Choose App") {
                            ForEach(runningApps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? "App") {
                                    awake.start(.whileApp(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "App"))
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("How to stay awake")
                // Each level includes the one before it: a screen that's on means the Mac is awake too.
                HStack(spacing: 12) {
                    ForEach(Mode.allCases, id: \.self) { m in
                        ModeCard(level: m.rawValue + 1, title: m.title, detail: m.detail, symbol: m.symbol,
                                 keeps: Mode.allCases.map { ($0.keeps, $0.rawValue <= m.rawValue) },
                                 selected: mode == m, included: m.rawValue < mode.rawValue,
                                 busy: m == .lid && awake.changingLid,
                                 badge: m == .lid && awake.lidDisabledElsewhere ? "Set by another app".loc : nil) { setMode(m) }
                    }
                }
                if mode == .lid, FanControl.shared.helper != .ready {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                            .frame(width: 30, height: 30).background(Circle().fill(Palette.accent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stop asking for the password").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                            Text("Allow Orbit Helper once in Login Items and lid mode switches without a password.")
                                .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(FanControl.shared.helper == .needsApproval ? "Open Settings" : "Turn On") {
                            FanControl.shared.helper == .needsApproval ? SMAppService.openSystemSettingsLoginItems() : FanControl.shared.installHelper()
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    }
                    .padding(14).card()
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Text(modeFootnote).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .contentTransition(.opacity)
            }
            .animation(.spring(duration: 0.3, bounce: 0.2), value: mode)

            SettingsGroup(title: "Safety") {
                SettingsRow(title: "Stop when battery is low", subtitle: "Only while running on battery.", symbol: "battery.25percent") {
                    ChipPicker(selection: $batteryFloor, options: [(0, "Off"), (10, "10%"), (20, "20%"), (30, "30%"), (50, "50%")])
                }
                RowDivider()
                SettingsRow(title: "Stop if your Mac gets hot", subtitle: "Ends the session when macOS reports serious thermal pressure.", symbol: "thermometer.medium") {
                    Toggle("", isOn: $stopWhenHot).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    /// Levels, weakest first. Each one keeps everything the one before it does.
    private enum Mode: Int, CaseIterable {
        case system, display, lid

        var title: String {
            switch self {
            case .system: "Mac only"
            case .display: "Screen stays on"
            case .lid: "Even with the lid closed"
            }
        }
        var detail: String {
            switch self {
            case .system: "The screen sleeps as usual; downloads and renders keep going."
            case .display: "Mac and screen both stay awake. For talks, videos, reading."
            case .lid: "Keeps working with the lid shut, like on an external display. Asks for your password."
            }
        }
        var symbol: String {
            switch self {
            case .system: "moon.zzz"
            case .display: "display"
            case .lid: "laptopcomputer"
            }
        }
        /// What this level adds on top of the one before it.
        var keeps: String {
            switch self {
            case .system: "Mac awake"
            case .display: "Screen on"
            case .lid: "Lid closed"
            }
        }
    }

    private var mode: Mode { closedLid ? .lid : keepDisplay ? .display : .system }

    /// One choice instead of two overlapping switches: lid mode keeps the screen on while it's open.
    private func setMode(_ m: Mode) {
        guard m != mode else { return }
        if (m == .lid) != closedLid {
            awake.setClosedLid(m == .lid)
            closedLid = m == .lid
        }
        let display = m != .system
        if display != keepDisplay {
            keepDisplay = display
            awake.refreshAssertions()
        }
    }

    private var modeFootnote: String {
        switch mode {
        case .lid: "Don’t carry your Mac in a bag while this is on — it can overheat. Orbit turns it off when the session ends or you quit.".loc
        case .display, .system: "Each level includes the one before it — a screen that stays on keeps the Mac awake too. Applies right away if a session is running.".loc
        }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func isActive(_ interval: TimeInterval?) -> Bool {
        switch (awake.session, interval) {
        case (.indefinite?, nil): true
        case (.duration(let t)?, let i?): t == i
        default: false
        }
    }

    /// A time earlier than now means tomorrow.
    private func nextOccurrence(of time: Date) -> Date {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return Calendar.current.nextDate(after: Date(), matching: c, matchingPolicy: .nextTime) ?? time
    }
}

/// Hour and minute without AppKit's tight bezel, so it can sit in a pill like the buttons beside it.
private struct TimeField: NSViewRepresentable {
    @Binding var date: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = ClickToEditDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = .hourMinute
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.alignment = .center
        picker.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    /// Without a bezel AppKit undersizes the field (minutes got clipped); give it room for "오후 12:59".
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSDatePicker, context: Context) -> CGSize? {
        CGSize(width: nsView.intrinsicContentSize.width + 14, height: 20)
    }

    /// Doesn't grab focus (and a blue selection) just because the page opened; a click still edits it.
    final class ClickToEditDatePicker: NSDatePicker {
        private var clicked = false
        override var acceptsFirstResponder: Bool { clicked }
        override func mouseDown(with event: NSEvent) {
            clicked = true
            super.mouseDown(with: event)
        }
        override func resignFirstResponder() -> Bool {
            clicked = false
            return super.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ sender: NSDatePicker) { date.wrappedValue = sender.dateValue }
    }
}

private struct ModeCard: View {
    let level: Int
    let title: String
    let detail: String
    let symbol: String
    /// Every level's addition, and whether this card keeps it.
    let keeps: [(String, Bool)]
    let selected: Bool
    /// A stronger level is on, which already does what this one does.
    let included: Bool
    var busy = false
    var badge: String?
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Palette.ink)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selected ? Palette.accent : included ? Palette.accent.opacity(0.16) : Palette.raised))
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    else {
                        Text("Level %ld".loc(level)).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(selected ? Palette.accent : Palette.inkSecondary)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(selected ? Palette.accent.opacity(0.14) : Palette.raised))
                    }
                }
                Text(title.loc).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                Text(detail.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(keeps, id: \.0) { name, on in
                        HStack(spacing: 6) {
                            Image(systemName: on ? "checkmark" : "minus")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(on ? (selected ? Palette.accent : Palette.ink) : Palette.inkSecondary.opacity(0.4))
                                .frame(width: 12)
                            Text(name.loc).font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Palette.ink : Palette.inkSecondary.opacity(0.55))
                        }
                    }
                }
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Palette.raised))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 212, alignment: .topLeading)
            .card(active: selected)
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }
}

private struct DurationButton: View {
    let label: String
    let active: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            Text(label.loc)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(active ? Color.white : Palette.ink)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? Palette.accent : (hovering ? Palette.raised : Palette.surface)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(active ? .clear : Palette.hairline, lineWidth: 1))
                .scaleEffect(hovering ? 1.03 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hovering = h } }
        .animation(.spring(duration: 0.3), value: active)
    }
}

private struct AwakeHero: View {
    private var awake: KeepAwake { .shared }
    @State private var pressed = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 28) {
                Button {
                    pressed += 1
                    awake.toggle()
                } label: { dial }
                .buttonStyle(.plain)
                .help(awake.isOn ? "Turn off" : "Stay awake until you turn it off")

                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.inkSecondary)
                    HStack(spacing: 6) {
                        if awake.closedLidActive || awake.lidDisabledElsewhere { badge("Lid can close", "laptopcomputer", accent: true) }
                        badge(KeepAwake.keepDisplayOn ? "Display on" : "Display may sleep", "display")
                        if let b = Battery.read() {
                            badge("\(b.percent)%" + (b.onAC ? " · " + "Power adapter".loc : ""), b.charging ? "battery.100percent.bolt" : "battery.75percent")
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .card(active: awake.isOn, radius: 18)
        }
        .animation(.spring(duration: 0.45, bounce: 0.25), value: awake.isOn)
    }

    private var dial: some View {
        ZStack {
            Circle().fill(awake.isOn ? Palette.ink : Palette.raised)
            Circle().strokeBorder(Palette.hairline, lineWidth: 1)
            if awake.isOn {
                if let remaining = awake.remaining, let total = awake.total, total > 0 {
                    Circle()
                        .trim(from: 0, to: remaining / total)
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(6)
                        .animation(.linear(duration: 1), value: remaining)
                } else {
                    OrbitingDot()
                }
            }
            Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "moon.zzz")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(awake.isOn ? Palette.canvas : Palette.ink)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: pressed)
        }
        .frame(width: 128, height: 128)
        .shadow(color: awake.isOn ? Palette.accent.opacity(0.25) : .clear, radius: 18, y: 6)
    }

    private var title: String {
        guard awake.isOn else { return "Sleeping normally".loc }
        if let remaining = awake.remaining { return "Awake · %@ left".loc(KeepAwake.format(remaining)) }
        return "Awake".loc
    }

    private var subtitle: String {
        guard awake.isOn, let session = awake.session else {
            return awake.lastStopReason ?? "Tap the dial to stay awake, or pick a session below.".loc
        }
        return KeepAwake.describe(session) + (awake.startedAt.map { " · " + "started %@".loc($0.formatted(date: .omitted, time: .shortened)) } ?? "")
    }

    private func badge(_ text: String, _ symbol: String, accent: Bool = false) -> some View {
        Label(text.loc, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? Color.white : Palette.ink)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(accent ? Palette.accent : Palette.raised))
    }
}

/// The satellite circling the dial while an open-ended session runs.
private struct OrbitingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = t.truncatingRemainder(dividingBy: 6) / 6 * 2 * .pi
            ZStack {
                Circle().stroke(Palette.canvas.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [2, 4])).padding(8)
                Circle().fill(Palette.accent).frame(width: 10, height: 10)
                    .offset(x: sin(angle) * 56, y: -cos(angle) * 56)
            }
        }
    }
}
