import ServiceManagement
import SwiftUI

/// Charge limit and battery care, AlDente Pro–style.
struct BatteryPage: View {
    @Bindable private var b = BatteryManager.shared
    private var fans: FanControl { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Battery", subtitle: "Keep your battery young: stop charging at a limit.") {
                if b.limitOn || b.toppingUp || b.discharging || b.calibration != nil || b.heatOn {
                    Button("Charge Normally") { b.restoreNormal() }.buttonStyle(PillButtonStyle(prominent: false))
                        .hoverHint("Turns every battery option off and lets macOS charge as usual".loc)
                }
            }

            if !b.hasBattery {
                Notice(symbol: "powerplug", title: "This Mac has no battery", detail: "Battery care is for MacBooks.")
            } else {
                if !b.helperReady { helperBanner }
                if b.control == .none {
                    Notice(symbol: "exclamationmark.triangle.fill", title: "This Mac can't be told to stop charging",
                           detail: "Its firmware doesn't offer the switch Orbit uses. The battery stats below still work.")
                }
                if b.status == .macOSHolding { macOSBanner }

                BatteryHero(b: b)
                limitGroup
                actions
                smarterGroup
                schedulesGroup
                healthGroup
                quitGroup
            }
        }
        .task { await b.connect() }
        .onChange(of: fans.helper) { Task { await b.connect() } }
    }

    // MARK: Banners

    private var helperBanner: some View {
        Banner(symbol: "key.fill", title: "Turn on Orbit Helper",
               detail: "Stopping the charge needs the helper (approved once in Login Items). It keeps your limit even while Orbit is closed.") {
            switch fans.helper {
            case .ready:
                Button("Check Again") { Task { await b.connect() } }.buttonStyle(PillButtonStyle(prominent: false))
            case .needsApproval:
                Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(PillButtonStyle(prominent: true))
            case .off:
                Button("Turn On") { fans.installHelper() }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }

    private var macOSBanner: some View {
        Banner(symbol: "apple.logo", title: "macOS is holding the charge",
               detail: "Optimized Battery Charging (or macOS's own charge limit) paused it. Turn those off so they don't fight with Orbit.") {
            Button("Battery Settings") { BatteryManager.openMacOSBatterySettings() }.buttonStyle(PillButtonStyle(prominent: false))
        }
    }

    // MARK: Limit

    private var limitGroup: some View {
        SettingsGroup(title: "Charge Limit", footer: b.control == .adapterOnly
                      ? "This Mac has no charge-only switch, so Orbit holds the limit by running from the battery for a moment, then charging back up."
                      : nil) {
            SettingsRow(title: "Stop charging at a limit",
                        subtitle: "Lithium batteries age fastest when kept full. 80% is the sweet spot for a Mac that's plugged in most of the day.",
                        symbol: "battery.75percent") {
                Toggle("", isOn: $b.limitOn).toggleStyle(.switch).labelsHidden().disabled(b.control == .none)
            }
            if b.limitOn {
                RowDivider()
                HStack(spacing: 14) {
                    Text("20%").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    Slider(value: Binding(get: { Double(b.limit) }, set: { b.limit = Int($0.rounded()) }), in: 20...100, step: 5)
                    Text("100%").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    Text("\(b.limit)%")
                        .font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Palette.accent)
                        .frame(width: 56, alignment: .trailing)
                }
                .padding(.horizontal, Space.standard).padding(.vertical, 12)
                RowDivider()
                SettingsRow(title: "Optimized Battery Charging",
                            subtitle: "macOS's own version stops at 80% when it guesses you'll unplug later. Turn it off so the two don't fight.",
                            symbol: "apple.logo") {
                    Button("Battery Settings") { BatteryManager.openMacOSBatterySettings() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
    }

    // MARK: One-off actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Right now")
            HStack(alignment: .top, spacing: 12) {
                ChargeActionCard(symbol: "battery.100percent.bolt", title: "Top Up",
                           detail: "Charge to 100% once — before a trip. Then it goes back to your limit.",
                           active: b.toppingUp, progress: b.toppingUp ? Double(b.reading?.percent ?? 0) / 100 : nil,
                           start: "Top Up", stop: "Cancel", disabled: b.control == .none) {
                    b.toppingUp ? b.cancelTopUp() : b.topUp()
                }
                ChargeActionCard(symbol: "arrow.down.right.circle", title: "Discharge",
                           detail: "Run from the battery while plugged in, down to %ld%%. Orbit must stay open.".loc(b.limitOn ? b.limit : 50),
                           active: b.discharging, progress: nil,
                           start: "Discharge", stop: "Stop", disabled: !b.canDischarge || b.reading?.plugged != true) {
                    b.discharging ? b.stopDischarge() : b.discharge()
                }
                ChargeActionCard(symbol: "gauge.with.dots.needle.67percent", title: "Calibrate",
                           detail: "Down to 15%, up to 100%, an hour's rest, then back to your limit. Refreshes the battery's percentage. Takes a few hours.",
                           active: b.calibration != nil, progress: b.calibration != nil ? b.calibrationProgress : nil,
                           start: "Calibrate", stop: "Cancel", disabled: !b.canDischarge) {
                    b.calibration != nil ? b.cancelCalibration() : b.startCalibration()
                }
            }
        }
    }

    // MARK: Smarter charging

    private var smarterGroup: some View {
        SettingsGroup(title: "Smarter Charging") {
            SettingsRow(title: "Sailing", subtitle: "Let it drift down a little before charging again — fewer tiny top-ups.", symbol: "sailboat") {
                if b.sailing {
                    ChipPicker(selection: $b.sailingRange, options: [3, 5, 10, 15].map { ($0, "−\($0)%") })
                }
                Toggle("", isOn: $b.sailing).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingsRow(title: "Heat protection", subtitle: "Pauses charging while the battery is warmer than this. Heat ages it fastest.", symbol: "thermometer.medium") {
                if b.heatOn {
                    ChipPicker(selection: $b.heatLimit, options: [32.0, 35, 38, 40].map { ($0, "\(Int($0))°") })
                }
                Toggle("", isOn: $b.heatOn).toggleStyle(.switch).labelsHidden().disabled(b.control == .none)
            }
            RowDivider()
            SettingsRow(title: "Stay awake until the limit",
                        subtitle: "With a limit on, charging pauses whenever the Mac sleeps so it can't overshoot. This keeps the Mac awake instead, so it finishes charging to the limit.",
                        symbol: "cup.and.saucer") {
                Toggle("", isOn: $b.awakeUntilLimit).toggleStyle(.switch).labelsHidden()
            }
            if b.hasLED {
                RowDivider()
                SettingsRow(title: "MagSafe light", subtitle: "Show state: orange while charging, green when paused, off on battery.", symbol: "light.beacon.max") {
                    ChipPicker(selection: $b.led, options: BatteryManager.LED.allCases.map { ($0, $0.title) })
                }
            }
        }
    }

    // MARK: Schedules

    private var schedulesGroup: some View {
        SettingsGroup(title: "Schedule", footer: "Runs while Orbit is open. Top up every Friday morning before you head out, for example.") {
            ForEach($b.schedules) { $s in
                ScheduleRow(schedule: $s) { b.schedules.removeAll { $0.id == s.id } }
                RowDivider()
            }
            SettingsRow(title: b.schedules.isEmpty ? "No schedules yet" : "Add another", symbol: "calendar.badge.plus") {
                Button("Add Schedule") {
                    withAnimation(Motion.reflow) { b.schedules.append(BatteryManager.Schedule()) }
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    // MARK: Health

    private var healthGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Battery Health")
            let r = b.reading ?? BatteryReading()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                Stat(symbol: "heart", title: "Health", value: r.health.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                     detail: healthWord(r.health))
                Stat(symbol: "battery.100percent", title: "Capacity", value: r.fullCharge > 0 ? "\(r.fullCharge) mAh" : "—",
                     detail: r.design > 0 ? "Designed for %ld mAh".loc(r.design) : nil)
                Stat(symbol: "arrow.triangle.2.circlepath", title: "Cycles", value: "\(r.cycles)",
                     detail: "of about %ld".loc(r.designCycles))
                Stat(symbol: "thermometer.medium", title: "Temperature", value: b.temperature.map { String(format: "%.1f°", $0) } ?? "—",
                     detail: (b.temperature ?? 0) >= 40 ? "Warm".loc : "Looks good".loc)
                Stat(symbol: "bolt", title: "Voltage", value: r.voltage > 0 ? String(format: "%.2f V", Double(r.voltage) / 1000) : "—",
                     detail: r.amperage != 0 ? String(format: "%+.2f A", Double(r.amperage) / 1000) : nil)
                Stat(symbol: "powerplug", title: "Adapter", value: r.plugged && r.adapterWatts > 0 ? "\(r.adapterWatts) W" : "—",
                     detail: r.plugged ? (r.adapterName.isEmpty ? nil : r.adapterName) : "Not plugged in".loc)
            }
        }
    }

    private func healthWord(_ h: Double?) -> String? {
        guard let h else { return nil }
        return h >= 0.8 ? "Looks good".loc : "Service recommended".loc
    }

    // MARK: Quit

    private var quitGroup: some View {
        SettingsGroup(title: "When Orbit Quits",
                      footer: "Orbit Helper keeps the limit on its own. Discharging always stops when Orbit quits.") {
            SettingsRow(title: "After quitting", symbol: "power") {
                ChipPicker(selection: $b.onQuit, options: BatteryManager.OnQuit.allCases.map { ($0, $0.title) })
            }
            RowDivider()
            SettingsRow(title: "Charge normally now", subtitle: "Turns every option on this page off and hands charging back to macOS.",
                        symbol: "arrow.uturn.backward") {
                Button("Charge Normally") { b.restoreNormal() }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }
}

// MARK: - Hero

private struct BatteryHero: View {
    let b: BatteryManager

    var body: some View {
        let r = b.reading ?? BatteryReading()
        HStack(alignment: .center, spacing: 28) {
            BatteryGauge(percent: r.percent, limit: b.effectiveLimit < 100 ? b.effectiveLimit : nil,
                         floor: b.limitOn && b.sailing && b.effectiveLimit < 100 ? max(15, b.effectiveLimit - b.sailingRange) : nil,
                         charging: r.charging)
                .frame(width: 230, height: 104)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(r.percent)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                }
                .foregroundStyle(Palette.ink)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(b.statusTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                PowerFlow(r: r)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var statusColor: Color {
        switch b.status {
        case .charging, .toppingUp, .calibrating, .discharging: Palette.accent
        case .holding, .sailing, .full: Palette.ink
        default: Palette.inkSecondary
        }
    }
}

/// A big battery: the charge in ink, the limit as an orange line, the sailing range as a faint band.
private struct BatteryGauge: View {
    let percent: Int
    let limit: Int?
    let floor: Int?
    let charging: Bool

    var body: some View {
        GeometryReader { geo in
            let nub: CGFloat = 8
            let w = geo.size.width - nub - 4, h = geo.size.height
            let inset: CGFloat = 6
            let inner = w - inset * 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 2.5)
                    .frame(width: w, height: h)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Palette.ink.opacity(0.35))
                    .frame(width: nub, height: h * 0.34)
                    .offset(x: w + 4, y: h * 0.33)
                if let floor, let limit {
                    Rectangle().fill(Palette.accent.opacity(0.14))
                        .frame(width: inner * CGFloat(limit - floor) / 100, height: h - inset * 2)
                        .offset(x: inset + inner * CGFloat(floor) / 100, y: inset)
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.ink)
                    .frame(width: max(4, inner * CGFloat(percent) / 100), height: h - inset * 2)
                    .offset(x: inset, y: inset)
                    .animation(.spring(duration: 0.6), value: percent)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .frame(width: w, height: h)
                }
                if let limit {
                    let x = inset + inner * CGFloat(limit) / 100
                    Capsule().fill(Palette.accent)
                        .frame(width: 3, height: h + 10)
                        .offset(x: x - 1.5, y: -5)
                    Text("\(limit)%")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.accent)
                        .fixedSize()
                        .offset(x: x - 12, y: -22)
                }
            }
        }
        .padding(.top, 16)
    }
}

/// Wall → Mac → battery, in watts.
private struct PowerFlow: View {
    let r: BatteryReading

    var body: some View {
        HStack(spacing: 8) {
            node("powerplug", r.plugged ? watts(r.wallWatts) : "—", "Adapter")
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                .foregroundStyle(r.plugged ? Palette.accent : Palette.inkSecondary.opacity(0.5))
            node("laptopcomputer", watts(r.systemWatts), "Mac")
            Image(systemName: r.batteryWatts < -0.05 ? "chevron.left" : "chevron.right").font(.system(size: 9, weight: .bold))
                .foregroundStyle(abs(r.batteryWatts) > 0.05 ? Palette.accent : Palette.inkSecondary.opacity(0.5))
            node("battery.75percent", abs(r.batteryWatts) > 0.05 ? String(format: "%+.1f W", r.batteryWatts) : "0 W", "Battery")
        }
    }

    private func watts(_ w: Double) -> String { w > 0 ? String(format: "%.1f W", w) : "—" }

    private func node(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Palette.ink)
                Text(label.loc).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
            }
            .fixedSize()
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Palette.raised))
    }
}

// MARK: - Pieces

private struct ChargeActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let active: Bool
    let progress: Double?
    let start: String
    let stop: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? Palette.accent : Palette.ink)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? Palette.accent.opacity(0.14) : Palette.raised))
            Text(title.loc).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
            Text(detail.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let progress {
                ProgressView(value: progress).tint(Palette.accent)
            }
            Button(active ? stop.loc : start.loc, action: action)
                .buttonStyle(PillButtonStyle(prominent: !active))
                .disabled(disabled && !active)
                .opacity(disabled && !active ? 0.4 : 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(active ? Palette.accent.opacity(0.6) : Palette.hairline, lineWidth: active ? 1.5 : 1))
    }
}

private struct Stat: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title.loc).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Palette.inkSecondary)
            Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.ink).lineLimit(1).minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

private struct ScheduleRow: View {
    @Binding var schedule: BatteryManager.Schedule
    let remove: () -> Void

    private static let dayLetters: [(Int, String)] = {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday
        return (0..<7).map { i in let d = (first - 1 + i) % 7 + 1; return (d, symbols[d - 1]) }
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
            DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.field).fixedSize()
            Menu(schedule.action.title.loc) {
                ForEach(BatteryManager.Schedule.Action.allCases) { a in
                    Button(a.title.loc) { schedule.action = a }
                }
            }
            .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                ForEach(Self.dayLetters, id: \.0) { day, letter in
                    let on = schedule.days.isEmpty || schedule.days.contains(day)
                    Button {
                        var days = schedule.days.isEmpty ? Set(1...7) : schedule.days
                        if days.contains(day) { days.remove(day) } else { days.insert(day) }
                        schedule.days = days.count == 7 || days.isEmpty ? [] : days
                    } label: {
                        Text(letter).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(on ? Palette.canvas : Palette.inkSecondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(on ? Palette.ink : Palette.raised))
                    }
                    .buttonStyle(.plain)
                }
            }
            Toggle("", isOn: $schedule.enabled).toggleStyle(.switch).labelsHidden()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.inkSecondary)
            }
            .buttonStyle(.plain)
            .help("Remove".loc)
        }
        .padding(.horizontal, Space.standard).padding(.vertical, 10)
    }

    private var time: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            schedule.hour = c.hour ?? 7
            schedule.minute = c.minute ?? 0
        })
    }
}

private struct Banner<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).background(Circle().fill(Palette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                Text(detail.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.accent.opacity(0.25), lineWidth: 1))
    }
}

private struct Notice: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        Banner(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}
