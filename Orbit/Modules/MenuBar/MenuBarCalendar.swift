import AppKit
import EventKit
import SwiftUI

/// The date in the menu bar, with a month view and the day's events one click away.
@MainActor @Observable
final class MenuBarCalendar: NSObject {
    static let shared = MenuBarCalendar()

    /// The glyph, like Itsycal's: today's number in a filled or outlined box, or a little month grid.
    enum IconShape: String, CaseIterable { case filled, outline, grid, none }
    /// Text beside the glyph. "icon" is the old name for no text.
    enum Style: String, CaseIterable { case none, weekday, date, dateTime, custom

        init(stored: String?) { self = Style(rawValue: stored ?? "") ?? (stored == "icon" ? .none : .date) }

        /// A localized template (or, for custom, the user's own pattern).
        func pattern(custom: String) -> String? {
            switch self {
            case .none: nil
            case .weekday: "EEEd"
            case .date: "MMMdEEE"
            case .dateTime: "MMMdEEEjmm"
            case .custom: custom.trimmingCharacters(in: .whitespaces).isEmpty ? nil : custom
            }
        }
    }

    var month = Date()
    var selected = Date()
    /// The selected day and the six after it, days without events left out (like Itsycal's agenda).
    private(set) var agenda: [(day: Date, events: [EKEvent])] = []
    /// Up to three calendar colors per day, for the dots under the grid numbers.
    private(set) var dayColors: [DateComponents: [NSColor]] = [:]
    /// Pinned: the popover stays open when you click elsewhere.
    var pinned = false {
        didSet { popover.behavior = pinned ? .applicationDefined : .transient }
    }
    private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    @ObservationIgnored private var item: NSStatusItem?
    var button: NSStatusBarButton? { item?.button }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView: CalendarPopover(model: self).orbitTint())
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        return p
    }()

    var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = Pref.defaults.bool(forKey: Pref.calendarWeekStart) ? 2 : 1
        return c
    }

    func apply() {
        if Pref.defaults.bool(forKey: Pref.calendarEnabled) {
            if item == nil {
                Pref.seedMenuBarPosition("OrbitCalendar", 1)
                let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                i.autosaveName = "OrbitCalendar"
                i.button?.target = self
                i.button?.action = #selector(toggle(_:))
                item = i
                NotificationCenter.default.addObserver(self, selector: #selector(storeChanged), name: .EKEventStoreChanged, object: store)
                NotificationCenter.default.addObserver(self, selector: #selector(dayChanged), name: .NSCalendarDayChanged, object: nil)
            }
            render()
            scheduleTick()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            timer?.invalidate()
            timer = nil
        }
    }

    /// Re-renders on each minute boundary so a time style never lags.
    private func scheduleTick() {
        timer?.invalidate()
        let next = calendar.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        timer = Timer(fire: next, interval: 60, repeats: true) { _ in MainActor.assumeIsolated { MenuBarCalendar.shared.render() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func render() {
        guard let button = item?.button else { return }
        let d = Pref.defaults
        let now = Date()
        var shape = IconShape(rawValue: d.string(forKey: Pref.calendarIcon) ?? "") ?? .outline
        let text = Self.text(for: now, style: Style(stored: d.string(forKey: Pref.calendarStyle)),
                             custom: d.string(forKey: Pref.calendarFormat) ?? "")
        if shape == .none, text == nil { shape = .outline } // never an empty, unclickable item
        button.image = Self.icon(shape, date: now, month: d.bool(forKey: Pref.calendarIconMonth),
                                 weekday: d.bool(forKey: Pref.calendarIconWeekday), calendar: calendar)
        button.title = text ?? ""
        button.imagePosition = text == nil ? .imageOnly : button.image == nil ? .noImage : .imageLeading
        button.toolTip = now.formatted(date: .complete, time: .omitted)
    }

    static func text(for date: Date, style: Style, custom: String) -> String? {
        guard let pattern = style.pattern(custom: custom) else { return nil }
        let f = DateFormatter()
        f.locale = .current
        if style == .custom { f.dateFormat = pattern } else { f.setLocalizedDateFormatFromTemplate(pattern) }
        return f.string(from: date)
    }

    /// Template glyphs, so they follow the menu bar in light, dark and tinted modes.
    static func icon(_ shape: IconShape, date: Date, month: Bool, weekday: Bool, calendar: Calendar = .current) -> NSImage? {
        switch shape {
        case .none: return nil
        case .grid: return gridIcon()
        case .filled, .outline:
            // Just the number, or the localized date ("10월 28일 (수)") when month or weekday is on.
            guard month || weekday else {
                return dayIcon("\(calendar.component(.day, from: date))", filled: shape == .filled, compact: true)
            }
            let f = DateFormatter()
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate((month ? "MMM" : "") + "d" + (weekday ? "EEE" : ""))
            return dayIcon(f.string(from: date), filled: shape == .filled, compact: false)
        }
    }

    /// Box metrics measured against Itsycal: 12 pt medium text, 3 pt either side, 15 pt tall.
    private static func dayIcon(_ label: String, filled: Bool, compact: Bool) -> NSImage {
        // Non-compact metrics measured from Itsycal on a 2× screen: 84 × 15.5 pt box for "10월 28일 (수)",
        // a 1 pt line, text 5.5 pt from the left and 6.5 pt from the right.
        let font = compact ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
                           : NSFont.systemFont(ofSize: 11.6, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        let width = max(20, ceil(textSize.width) + (compact ? 8 : 9))
        let size = NSSize(width: width, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let line: CGFloat = compact ? 1.3 : 1
            // 15.5 pt tall box sitting on the bottom; the image is a whole 16 pt so it lands on the pixel grid.
            let frame = compact ? rect : NSRect(x: 0, y: 0, width: rect.width, height: 15.5)
            let box = NSBezierPath(roundedRect: frame.insetBy(dx: line / 2, dy: line / 2), xRadius: 3, yRadius: 3)
            let origin = NSPoint(x: (rect.width - textSize.width) / 2,
                                 y: (frame.height - textSize.height) / 2 + (compact ? 0.5 : 0))
            NSColor.black.set()
            if filled {
                box.fill()
                // Knock the number out of the box so the menu bar shows through.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                text.draw(at: origin, withAttributes: attrs)
            } else {
                box.lineWidth = line
                box.stroke()
                text.draw(at: origin, withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func gridIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            body.lineWidth = 1.3
            body.stroke()
            NSBezierPath(rect: NSRect(x: 1.5, y: rect.height - 4.6, width: rect.width - 3, height: 3.4)).fill()
            for row in 0..<2 {
                for col in 0..<4 {
                    NSBezierPath(rect: NSRect(x: 3.5 + CGFloat(col) * 3, y: 7.4 - CGFloat(row) * 3.4, width: 2, height: 2)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        month = Date()
        selected = Date()
        reload()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if access == .notDetermined && Pref.defaults.bool(forKey: Pref.calendarEvents) { requestAccess() }
    }

    func close() { popover.performClose(nil) }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            access = EKEventStore.authorizationStatus(for: .event)
            reload()
        }
    }

    @objc private func storeChanged() { reload() }
    @objc private func dayChanged() { render() }

    func reload() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard access == .fullAccess, Pref.defaults.bool(forKey: Pref.calendarEvents) else {
            agenda = []
            dayColors = [:]
            return
        }
        let cal = calendar
        let start = cal.startOfDay(for: selected)
        agenda = (0..<7).compactMap { offset -> (day: Date, events: [EKEvent])? in
            let day = cal.date(byAdding: .day, value: offset, to: start)!
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let list = store.events(matching: store.predicateForEvents(withStart: day, end: next, calendars: nil))
                // Past events of today drop off, the way Itsycal does it.
                .filter { offset > 0 || !cal.isDateInToday(day) || $0.isAllDay || ($0.endDate ?? day) > Date() }
                .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            return list.isEmpty && offset > 0 ? nil : (day, list)
        }

        let grid = days(for: month)
        guard let first = grid.first, let last = grid.last else { return }
        let all = store.events(matching: store.predicateForEvents(withStart: first, end: cal.date(byAdding: .day, value: 1, to: last)!, calendars: nil))
        var colors: [DateComponents: [NSColor]] = [:]
        for e in all {
            var d = cal.startOfDay(for: e.startDate)
            let end: Date = e.endDate ?? e.startDate ?? d
            let color = e.calendar?.color ?? .systemGray
            repeat {
                let key = cal.dateComponents([.year, .month, .day], from: d)
                if colors[key, default: []].count < 3, !colors[key, default: []].contains(color) { colors[key, default: []].append(color) }
                d = cal.date(byAdding: .day, value: 1, to: d)!
            } while d < end && colors.count < 400
        }
        dayColors = colors
    }

    /// Six full weeks that contain `month`.
    func days(for month: Date) -> [Date] {
        let cal = calendar
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let weekday = cal.component(.weekday, from: interval.start)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: interval.start)!
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    func colors(on day: Date) -> [NSColor] { dayColors[calendar.dateComponents([.year, .month, .day], from: day)] ?? [] }

    /// "Today", "Tomorrow", or the date.
    func heading(for day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today".loc }
        if calendar.isDateInTomorrow(day) { return "Tomorrow".loc }
        return day.formatted(.dateTime.weekday(.wide))
    }

    /// Calendar.app on the selected day, ready for ⌘N.
    func newEvent() {
        let script = "tell application \"Calendar\"\nactivate\nswitch view to day view\nview calendar at (current date) + (\(Int(selected.timeIntervalSinceNow / 86_400)) * days)\nend tell"
        close()
        DispatchQueue.global().async { NSAppleScript(source: script)?.executeAndReturnError(nil) }
    }

    func shiftMonth(_ by: Int) {
        month = calendar.date(byAdding: .month, value: by, to: month) ?? month
        reload()
    }

    func goToday() {
        month = Date()
        selected = Date()
        reload()
    }

    func select(_ day: Date) {
        selected = day
        if !calendar.isDate(day, equalTo: month, toGranularity: .month) { month = day }
        reload()
    }

    func openCalendarApp() {
        close()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

// MARK: - Popover

private struct CalendarPopover: View {
    @Bindable var model: MenuBarCalendar
    @AppStorage(Pref.calendarEvents) private var showEvents = true

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdays
            grid
            if showEvents {
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.top, 10)
                agenda
            }
            footer
        }
        .frame(width: 300)
        .background(Palette.canvas)
        .focusEffectDisabled() // the popover becomes key; no focus ring on whichever button comes first
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(model.month.formatted(.dateTime.year().month(.wide)))
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Spacer()
            navButton("chevron.left") { model.shiftMonth(-1) }
            Button { withAnimation(.spring(duration: 0.3)) { model.goToday() } } label: {
                Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 9).frame(height: 24).background(Capsule().fill(Palette.raised))
            }
            .buttonStyle(.plain)
            navButton("chevron.right") { model.shiftMonth(1) }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(duration: 0.3)) { action() } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdays: some View {
        let cal = model.calendar
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let ordered = (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { i, s in
                let weekday = (cal.firstWeekday - 1 + i) % 7 + 1
                Text(s).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(weekday == 1 ? Palette.accent.opacity(0.85) : Palette.inkSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 4)
    }

    private var grid: some View {
        let cal = model.calendar
        let days = model.days(for: model.month)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
            ForEach(days, id: \.self) { day in
                let inMonth = cal.isDate(day, equalTo: model.month, toGranularity: .month)
                let today = cal.isDateInToday(day)
                let selected = cal.isDate(day, inSameDayAs: model.selected)
                Button { withAnimation(.spring(duration: 0.25)) { model.select(day) } } label: {
                    VStack(spacing: 2) {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 12, weight: today || selected ? .bold : .regular, design: .rounded))
                            .foregroundStyle(today ? Color.white : selected ? Palette.canvas : inMonth ? Palette.ink : Palette.inkSecondary.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .background {
                                if today { Circle().fill(Palette.accent) }
                                else if selected { Circle().fill(Palette.ink) }
                            }
                        HStack(spacing: 2) {
                            ForEach(Array((showEvents ? model.colors(on: day) : []).enumerated()), id: \.offset) { _, c in
                                Circle().fill(Color(nsColor: c)).frame(width: 4, height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                    .frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var agenda: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.access {
            case .fullAccess:
                if model.agenda.allSatisfy(\.events.isEmpty) {
                    dayHeading(model.selected)
                    Text("Nothing in the next 7 days").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).padding(.vertical, 2)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.agenda.filter { !$0.events.isEmpty }, id: \.day) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    dayHeading(entry.day)
                                    ForEach(entry.events, id: \.eventIdentifier) { EventRow(event: $0) }
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.never)
                }
            case .notDetermined:
                Button("Show events from Calendar") { model.requestAccess() }.buttonStyle(PillButtonStyle(prominent: false))
            default:
                Text("Allow Calendar access in System Settings › Privacy › Calendars to see events.")
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func dayHeading(_ day: Date) -> some View {
        HStack {
            Text(model.heading(for: day)).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
            Spacer()
            Text(day.formatted(.dateTime.month().day())).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
        }
        .padding(.bottom, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            footerButton("plus", help: "New event") { model.newEvent() }
            Spacer()
            footerButton(model.pinned ? "pin.fill" : "pin", help: "Keep open", tint: model.pinned ? Palette.accent : nil) { model.pinned.toggle() }
            footerButton("calendar", help: "Open Calendar") { model.openCalendarApp() }
            footerButton("gearshape", help: "Menu bar settings") { model.close(); MainWindow.show(.menubar) }
        }
        .padding(.horizontal, 14).frame(height: 36)
        .background(Palette.surface)
    }
}

private extension CalendarPopover {
    func footerButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? Palette.inkSecondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help.loc)
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: event.calendar?.color ?? .systemGray)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(time).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var time: String {
        if event.isAllDay { return "All day".loc }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return [start + " – " + end, event.location].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}
