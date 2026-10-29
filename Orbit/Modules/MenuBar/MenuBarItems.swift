import AppKit
import ScreenCaptureKit
import SwiftUI

/// Every app's menu bar item, which of Orbit's sections it's in, and a picture of it.
/// Status items aren't windows any more: names come from each app's Accessibility "extras menu
/// bar", and where each item really is comes from MenuBarAgent's slots (see ``MenuBarHosted``).
/// Pictures are cut from the menu bar wherever an item is laid out — on the bar, or in macOS's
/// expanded « overflow, which Orbit opens for a moment when it needs to reach what's in there.
@MainActor @Observable
final class MenuBarItems {
    static let shared = MenuBarItems()

    enum Section: String, CaseIterable, Identifiable {
        case visible, hidden, always
        var id: String { rawValue }
        var title: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .always: "Always hidden"
            }
        }
    }

    struct Item: Identifiable {
        /// Stable across launches and moves: bundle id + label (+ a count only for repeats).
        let id: String
        let name: String
        let appIcon: NSImage
        /// How to press it: another app's item through Accessibility, or one of Orbit's own buttons.
        let element: AXUIElement?
        let button: NSStatusBarButton?
        let frame: CGRect
        var section: Section
        /// Really drawn in the menu bar right now (not tucked behind macOS's « or the notch).
        let shown: Bool
        /// Left-to-right position; changed straight away when the user drops an icon somewhere new.
        var order: CGFloat
        /// A cut-out of the real menu bar icon, when Orbit has seen it on screen.
        let image: NSImage?
        let mobility: Mobility
        /// macOS's own items: `com.apple.menuextra.wifi` and so on.
        var identifier: String? = nil
    }

    enum Mobility {
        case free
        /// Orbit's own button: hiding it would leave no way to open the hidden icons.
        case visibleOnly
        /// The clock and Control Center, which macOS keeps in place.
        case fixed
    }

    private(set) var items: [Item] = []
    /// Unfolding, moving or reading — the editor shows a spinner and ignores drops.
    private(set) var busy = false {
        // Whatever Orbit did to the bar happened under a still picture of it (see MenuBarFreeze).
        didSet {
            if oldValue, !busy {
                MenuBarFreeze.release()
                // Back under the cover before the still picture fades.
                OverflowCover.shared.refreshSoon()
            }
            // The strip's lid must not catch Orbit's own drags.
            MenuBarHider.shared.placeLid()
        }
    }
    private(set) var lastError: String?
    /// macOS's own « overflow button is showing: the menu bar is too full and macOS is hiding icons itself.
    private(set) var systemOverflow = false

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var known: [String: Section] = [:]

    var hasSnapshot: Bool { !known.isEmpty }

    func items(in section: Section) -> [Item] { items.filter { $0.section == section } }

    /// Reads the menu bar again. `reveal` unfolds every section for a moment — and opens macOS's «
    /// overflow if that's where some icons are — so hidden items can be placed and photographed;
    /// without it, items out of view keep their last known section.
    func refresh(reveal: Bool) async {
        guard AXIsProcessTrusted() else {
            lastError = "Orbit needs Accessibility to read menu bar icons.".loc
            return
        }
        guard !busy else { return }
        if MenuBarRemoval.shared.active {
            // Nothing is folded away: what's on the bar is all there is to read.
            busy = true
            defer { busy = false }
            await snapshot()
            return
        }
        if reveal { await MenuBarFreeze.hold() }
        busy = true
        defer { busy = false }
        let hider = MenuBarHider.shared
        let wasRevealing = hider.revealing
        if reveal, !wasRevealing {
            OverflowCover.shared.stepAside()
            hider.reveal(true)
            try? await Task.sleep(for: .milliseconds(380))
        }
        if reveal, Self.read().contains(where: { !$0.laidOut && $0.mobility != .visibleOnly }) {
            // Some icons are stacked away behind «: open it so they get real places for a moment.
            let pointer = MenuBarDrag.pointer
            CGDisplayHideCursor(CGMainDisplayID())
            let opened = await openOverflow()
            await snapshot()
            if opened { await closeOverflow() }
            MenuBarDrag.warp(to: pointer)
            CGDisplayShowCursor(CGMainDisplayID())
        } else {
            await snapshot()
        }
        // A refresh only keeps an arrangement the user already made; the first one comes from a move.
        if reveal, Self.savedArrangement != nil { saveArrangement() }
        if reveal, !wasRevealing { hider.reveal(false) }
    }

    // MARK: Remembering the arrangement

    /// macOS 27 doesn't keep Orbit's dividers where the user put them across launches (their
    /// "Preferred Position" is never saved), so Orbit remembers the arrangement itself: the item ids
    /// of each section, left to right.
    private static let arrangementKey = "menubar.arrangement"
    @ObservationIgnored private var restored = false

    private static var savedArrangement: [String: [String]]? {
        Pref.defaults.dictionary(forKey: arrangementKey) as? [String: [String]]
    }

    private func saveArrangement() {
        // Not before the launch-time restore: the bar may have drifted, and that's not the user's doing.
        guard items.count > 2 else { return }
        var layout: [String: [String]] = [:]
        for section in Section.allCases {
            layout[section.rawValue] = items.filter { $0.section == section }.sorted { $0.order < $1.order }.map(\.id)
        }
        Pref.defaults.set(layout, forKey: Self.arrangementKey)
    }

    /// At launch, before folding: puts the divider back in front of the first icon the user had
    /// visible, then moves anything still on the wrong side of it.
    func restoreArrangement() async {
        // Saving here would record whatever the bar drifted to as if the user had chosen it.
        defer { restored = true }
        guard AXIsProcessTrusted(), let saved = Self.savedArrangement, !busy else { return }
        try? await Task.sleep(for: .milliseconds(400))
        var wanted: [String: Section] = [:]
        for (key, ids) in saved {
            guard let section = Section(rawValue: key) else { continue }
            for id in ids { wanted[id] = section }
        }
        // The ✦ belongs in view whatever was saved.
        wanted[Self.toggleID] = .visible
        for (id, section) in wanted { known[id] = section }

        var raw = Self.read()
        let visible = saved[Section.visible.rawValue] ?? []
        if let first = visible.first(where: { id in raw.contains { $0.id == id && $0.shown } }),
           let d = Self.controlFrame(.rightOfDivider, raw) {
            let next = raw.filter { $0.shown && $0.frame.minX >= d.maxX - 2 }.min { $0.frame.minX < $1.frame.minX }
            if next?.id != first {
                MenuBarLog.write("restore: divider is in front of \(next?.id ?? "nothing"), should be in front of \(first)")
                await MenuBarFreeze.hold()
                busy = true
                OverflowCover.shared.stepAside()
                let pointer = MenuBarDrag.pointer
                CGDisplayHideCursor(CGMainDisplayID())
                for attempt in 1...2 {
                    guard let d = Self.controlFrame(.rightOfDivider, raw), let target = raw.first(where: { $0.id == first && $0.shown })?.frame else { break }
                    await MenuBarDrag.drag(from: d.center, to: CGPoint(x: target.minX + 3, y: target.midY), restorePointer: false)
                    try? await Task.sleep(for: .milliseconds(700))
                    raw = Self.read()
                    let now = Self.controlFrame(.rightOfDivider, raw).flatMap { d in
                        raw.filter { $0.shown && $0.frame.minX >= d.maxX - 2 }.min { $0.frame.minX < $1.frame.minX }
                    }
                    MenuBarLog.write("restore: divider try \(attempt) → in front of \(now?.id ?? "nothing")")
                    if now?.id == first { break }
                }
                CGDisplayShowCursor(CGMainDisplayID())
                MenuBarDrag.warp(to: pointer)
                busy = false
            }
        }
        // Then whatever is still on the wrong side, a few at most.
        await snapshot()
        let drifted = items.filter { item in
            guard let want = wanted[item.id], want != item.section, item.mobility != .fixed, item.shown else { return false }
            return item.mobility != .visibleOnly || want == .visible
        }
        for item in drifted.prefix(6) {
            guard let want = wanted[item.id] else { continue }
            // A crowded bar: one more icon in view would push the strip (and with it other icons)
            // behind «. Leave a nice-to-have where it is; only the ✦ insists.
            if want == .visible, item.mobility != .visibleOnly, let room = visibleRoom(), item.frame.width > room {
                MenuBarLog.write("restore: no room for \(item.id) in view (\(Int(item.frame.width))pt wanted, \(Int(room))pt free); left hidden")
                continue
            }
            let row = saved[want.rawValue] ?? []
            let neighbor = row.firstIndex(of: item.id).flatMap { k in
                row[(k + 1)...].first { id in items.contains { $0.id == id && $0.section == want } }
            }
            MenuBarLog.write("restore: \(item.id) drifted to \(item.section.rawValue), back to \(want.rawValue)")
            await move(item.id, to: want, before: neighbor)
        }
    }

    /// Width still free in the visible section before it would run into the notch (or the screen's
    /// left edge), keeping space for the strip and macOS's « button.
    private func visibleRoom() -> CGFloat? {
        guard let screen = NSScreen.screens.first else { return nil }
        let left = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        let used = items.filter { $0.section == .visible }.reduce(0) { $0 + $1.frame.width }
        let reserve: CGFloat = 24 + 26 + 8 // the shortest strip, «, and a little slack
        return screen.frame.maxX - left - used - reserve
    }

    /// Photographs whatever is on screen right now (called as the hider folds and unfolds).
    func captureVisible() async {
        guard AXIsProcessTrusted(), !busy else { return }
        await capture(Self.read())
    }

    /// Where a move drops an item: next to another icon, or on one side of a divider.
    private enum Anchor: Equatable {
        case leftOf(String)
        case rightOfDivider, leftOfDivider, leftOfAlways
    }

    /// Really moves an item, the way IceMelt does it on macOS 27: unfold the sections, open the «
    /// overflow if the item or its destination is stacked away in there, then ⌘-drag from the item's
    /// slot to just inside the destination's near edge — checked by order afterwards, and tried
    /// again up to three times.
    func move(_ id: String, to section: Section, before neighbor: String? = nil) async {
        guard !busy, let index = items.firstIndex(where: { $0.id == id }), neighbor != id else { return }
        let item = items[index]
        guard neighbor != nil || item.section != section else { return }
        switch item.mobility {
        case .fixed:
            lastError = "macOS keeps “%@” in place.".loc(item.name)
            return
        case .visibleOnly where section != .visible:
            lastError = "Orbit’s button stays visible — it’s how you open the hidden icons.".loc
            return
        default: break
        }
        if MenuBarRemoval.shared.active, Self.isSystem(id), MenuBarRemoval.systemSwitch(for: item) == nil {
            lastError = "macOS keeps “%@” in place.".loc(item.name)
            return
        }
        let before = item.section
        let rows = items.filter { $0.section == section && $0.id != id }
        let order: CGFloat
        if let neighbor, let n = rows.first(where: { $0.id == neighbor }) {
            order = n.order - 0.5
        } else if section == .visible {
            order = (rows.map(\.order).min() ?? 0) - 1
        } else {
            order = (rows.map(\.order).max() ?? 0) + 1
        }
        // Show it in its new place straight away; the real menu bar catches up behind it.
        withAnimation(.spring(duration: 0.4, bounce: 0.25)) {
            items[index].section = section
            items[index].order = order
            items.sort { ($0.section.order, $0.order) < ($1.section.order, $1.order) }
        }
        known[id] = section
        if MenuBarRemoval.shared.active {
            // Hidden means switched off: no dragging, macOS just stops drawing the app's icons.
            lastError = nil
            let bundle = MenuBarRemoval.bundleID(ofItem: id)
            // An app's icons go together; macOS's own each have their own switch.
            for other in items where Self.isSystem(id) ? other.id == id : MenuBarRemoval.bundleID(ofItem: other.id) == bundle {
                known[other.id] = section
                if section != .visible { Self.saveIcon(other.id, images[other.id]) }
            }
            if let moved = items.first(where: { $0.id == id }) { MenuBarRemoval.shared.place(moved, in: section) }
            saveArrangement()
            return
        }
        await MenuBarFreeze.hold()
        busy = true
        lastError = nil
        let hider = MenuBarHider.shared
        let pointer = MenuBarDrag.pointer
        OverflowCover.shared.stepAside()
        hider.reveal(true)
        try? await Task.sleep(for: .milliseconds(450))
        if section == .always { await hider.prepareAlwaysSection() }

        let anchor: Anchor = neighbor.map { .leftOf($0) }
            ?? (section == .visible ? .rightOfDivider : section == .hidden ? .leftOfDivider : .leftOfAlways)
        CGDisplayHideCursor(CGMainDisplayID())
        let outcome = await drag(id, to: anchor, section: section)
        CGDisplayShowCursor(CGMainDisplayID())
        MenuBarDrag.warp(to: pointer)
        switch outcome {
        case .placed: break
        case .wrongSpot:
            // In the right section, just not next to that icon: close enough, keep it.
            MenuBarLog.write("  in \(section.rawValue), but not right before \(neighbor ?? "-")")
        case .unreachable:
            known[id] = before
            lastError = "Couldn’t reach “%@” — macOS has tucked it behind the notch. Make room in the menu bar and try again.".loc(item.name)
        case .refused:
            known[id] = before
            lastError = "macOS didn’t take the move for “%@”. Try once more — or tell Orbit’s developer what happened.".loc(item.name)
        }
        if outcome == .placed || outcome == .wrongSpot { restored = true }
        let isButton = id == Self.toggleID
        if isButton {
            // The visible icons start somewhere else now: measure the fold again, so the strip leaves
            // room for the button instead of pushing it behind «.
            try? await Task.sleep(for: .milliseconds(300))
            hider.refitFold()
        }
        // Only the moved icon is re-read; the rest keep their rows, so nothing else jumps around
        // when macOS reshuffles what fits next to the notch.
        await snapshot(only: [id])
        if outcome == .placed || outcome == .wrongSpot { saveArrangement() }
        hider.reveal(false)
        busy = false
        if isButton, outcome == .placed || outcome == .wrongSpot {
            try? await Task.sleep(for: .milliseconds(1200))
            MenuBarLog.write("button moved; in view \(hider.toggleVisible)")
            if !hider.toggleVisible {
                lastError = "The menu bar is too full for Orbit’s button there — it stays at the end of the hidden strip.".loc
            }
            await snapshot(only: [id])
        }
    }

    static let toggleID = "com.lyu.orbit|toggle"

    private enum Outcome { case placed, wrongSpot, unreachable, refused }

    private func drag(_ id: String, to anchor: Anchor, section: Section) async -> Outcome {
        var raw = Self.read()
        var openedOverflow = false
        func me() -> Raw? { raw.first { $0.id == id } }
        MenuBarLog.write("move \(id): layout « \(Self.lastLayout.chevron.map { "\(Int($0.minX))" } ?? "none") — " + raw.sorted { $0.frame.minX < $1.frame.minX }
            .map { "\($0.name) \(Int($0.frame.minX))\($0.shown ? "" : $0.laidOut ? " overflow" : " stacked")" }.joined(separator: ", "))

        // A drag works on the bar and among the slots of the expanded overflow, and from the
        // overflow onto the bar — but not from the bar into the overflow. So an icon on the bar that's
        // going into a hidden section is first dropped just left of the divider, on the bar.
        if section != .visible, let m = me(), m.shown, let d = Self.controlFrame(.leftOfDivider, raw),
           m.frame.minX >= d.maxX - 2 {
            MenuBarLog.write("move \(id): onto the hidden side of the divider first")
            await MenuBarDrag.drag(from: m.frame.center, to: CGPoint(x: Self.dropX(leftOf: d), y: d.midY), restorePointer: false)
            raw = await settledRead(id, changedFrom: m.frame)
            if anchor == .leftOfDivider, let o = Self.judge(id, anchor, raw, wasOnBar: true) { return o }
        }
        // Open the overflow if the icon or where it's going has no place of its own right now.
        if me()?.laidOut != true || Self.anchorFrame(anchor, raw) == nil, Self.lastLayout.chevron != nil {
            openedOverflow = await openOverflow()
            raw = Self.read()
        }
        var result: Outcome = .refused
        attempts: for attempt in 1...3 {
            guard let m = me(), m.laidOut else {
                let pid = ProcessInfo.processInfo.processIdentifier
                MenuBarLog.write("move \(id): Orbit's slots " + Self.lastLayout.slots.filter { $0.pid == pid }
                    .map { "\(Int($0.frame.minX))w\(Int($0.frame.width))\($0.hasSlot ? "" : " stacked")\($0.onBar ? " bar" : "")" }.joined(separator: ", ")
                    + "; own " + raw.filter { $0.pid == pid }.map { "\($0.id.split(separator: "|").last ?? "") \(Int($0.frame.minX))w\(Int($0.frame.width))" }.joined(separator: ", ")
                    + "; dividers " + MenuBarHider.shared.ownFrames.map { "\(Int($0.minX))w\(Int($0.width))" }.joined(separator: ", "))
                MenuBarLog.write("move \(id) try \(attempt): not reachable (overflow open \(openedOverflow))")
                result = .unreachable
                break
            }
            guard let target = Self.anchorFrame(anchor, raw) else {
                MenuBarLog.write("move \(id) try \(attempt): destination \(anchor) not reachable")
                result = .unreachable
                break
            }
            if let o = Self.judge(id, anchor, raw, wasOnBar: m.shown), o == .placed { result = .placed; break }
            // From the bar into the expanded overflow is the one drag macOS ignores.
            if case .leftOf(let other) = anchor, let n = raw.first(where: { $0.id == other }), m.shown, n.laidOut, !n.shown {
                MenuBarLog.write("move \(id): \(other) is in the overflow, \(id) on the bar — leaving the order")
                result = .refused
                break
            }
            let end = Self.dropPoint(anchor, target)
            MenuBarLog.write("move \(id) → \(section.rawValue) via \(anchor) try \(attempt): from \(m.frame) to \(end), overflow open \(openedOverflow)")
            await MenuBarDrag.drag(from: m.frame.center, to: end, restorePointer: false)
            raw = await settledRead(id, changedFrom: m.frame)
            if let o = Self.judge(id, anchor, raw, wasOnBar: m.shown) {
                MenuBarLog.write("  → \(o)")
                result = o
                if o == .placed { break attempts }
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        // A section move that didn't land next to its neighbor is still a move.
        if result != .placed, case .leftOf = anchor, Self.inSection(id, section, raw) { result = .wrongSpot }
        if result != .placed, result != .wrongSpot, Self.inSection(id, section, raw) { result = .placed }
        if openedOverflow { await closeOverflow() }
        return result
    }

    /// Did it land? `nil` when the layout says nothing either way.
    private static func judge(_ id: String, _ anchor: Anchor, _ raw: [Raw], wasOnBar: Bool) -> Outcome? {
        guard let me = raw.first(where: { $0.id == id }) else { return nil }
        switch anchor {
        case .leftOf(let other):
            guard let n = raw.first(where: { $0.id == other }), me.laidOut, n.laidOut, me.shown == n.shown else { return nil }
            guard me.frame.maxX <= n.frame.minX + 1 else { return .refused }
            // Order, not touching frames: slots beside macOS's own items have gaps.
            let between = raw.contains { o in
                o.id != id && o.id != other && o.laidOut && o.shown == me.shown &&
                o.frame.midX > me.frame.midX && o.frame.midX < n.frame.midX
            }
            return between ? .refused : .placed
        case .rightOfDivider:
            guard let d = controlFrame(.rightOfDivider, raw) else { return nil }
            return me.shown && me.frame.minX >= d.maxX - 2 ? .placed : .refused
        case .leftOfDivider, .leftOfAlways:
            guard let d = controlFrame(anchor, raw) else { return nil }
            if me.laidOut { return me.frame.maxX <= d.minX + 2 ? .placed : .refused }
            // Dropped left of the divider and gone straight into macOS's overflow: hidden, as asked.
            return wasOnBar ? .placed : nil
        }
    }

    private static func inSection(_ id: String, _ section: Section, _ raw: [Raw]) -> Bool {
        guard let me = raw.first(where: { $0.id == id }), me.laidOut, let d = controlFrame(.leftOfDivider, raw) else { return false }
        switch section {
        case .visible: return me.shown && me.frame.minX >= d.maxX - 2
        case .hidden:
            let a = controlFrame(.leftOfAlways, raw)
            return me.frame.maxX <= d.minX + 2 && (a.map { me.frame.minX >= $0.maxX - 2 } ?? true)
        case .always: return controlFrame(.leftOfAlways, raw).map { me.frame.maxX <= $0.minX + 2 } ?? false
        }
    }

    /// Orbit's dividers, where macOS really has them laid out.
    private static func controlFrame(_ anchor: Anchor, _ raw: [Raw]) -> CGRect? {
        let hider = MenuBarHider.shared
        let frame = anchor == .leftOfAlways ? hider.alwaysFrame : hider.dividerFrame
        guard let frame else { return nil }
        // Without MenuBarAgent's layout, trust AppKit's window frame.
        guard !lastLayout.slots.isEmpty else { return frame }
        let me = ProcessInfo.processInfo.processIdentifier
        return lastLayout.slots.filter { $0.pid == me && $0.hasSlot && abs($0.frame.minX - frame.minX) <= 6 }
            .min { abs($0.frame.minX - frame.minX) < abs($1.frame.minX - frame.minX) }?.frame
    }

    private static func anchorFrame(_ anchor: Anchor, _ raw: [Raw]) -> CGRect? {
        if case .leftOf(let other) = anchor {
            return raw.first { $0.id == other && $0.laidOut }?.frame
        }
        return controlFrame(anchor, raw)
    }

    /// Just inside the near edge, where macOS inserts on that side.
    private static func dropPoint(_ anchor: Anchor, _ target: CGRect) -> CGPoint {
        switch anchor {
        case .rightOfDivider: CGPoint(x: target.maxX - 3, y: target.midY)
        case .leftOfDivider, .leftOfAlways: CGPoint(x: dropX(leftOf: target), y: target.midY)
        case .leftOf: CGPoint(x: target.minX + 3, y: target.midY)
        }
    }

    /// A drop within about 20pt of the notch's edge only takes some of the time.
    private static func dropX(leftOf target: CGRect) -> CGFloat {
        let x = target.minX + 3
        guard let screen = NSScreen.screens.first, let right = screen.auxiliaryTopRightArea,
              target.minX > right.minX else { return x }
        return min(max(x, right.minX + 24), target.midX)
    }

    /// Reads until the moved icon holds still somewhere other than where it started (at most 3s).
    private func settledRead(_ id: String, changedFrom start: CGRect) async -> [Raw] {
        let deadline = ContinuousClock.now + .seconds(3)
        var previous: CGRect?
        var latest = Self.read()
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            latest = Self.read()
            let now = latest.first { $0.id == id }?.frame
            if let now, now == previous, now != start { break }
            previous = now
        }
        return latest
    }

    // MARK: macOS's « overflow

    /// Clicks « so the items stacked behind it get real places at the leading end of the bar.
    /// They stay there only while the pointer is over the overflow, so the pointer is left there.
    /// Returns whether Orbit opened it (and so should close it again).
    /// On a full bar macOS can tuck the divider itself behind «, and then nothing can be folded and
    /// every icon counts as visible. Bring it back out to the front of the bar — just right of « —
    /// so whatever macOS tucked away is simply what's hidden, as with Barbee.
    func bringDividerForward() async {
        guard AXIsProcessTrusted(), !busy, !MenuBarHider.inView(MenuBarHider.shared.dividerWindow) else { return }
        await MenuBarFreeze.hold()
        busy = true
        defer { busy = false }
        let pointer = MenuBarDrag.pointer
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            MenuBarDrag.warp(to: pointer)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        let me = ProcessInfo.processInfo.processIdentifier
        for attempt in 1...2 {
            let opened = await openOverflow()
            let layout = await MenuBarHosted.settled(ownFrames: { MenuBarHider.shared.ownFrames })
            Self.lastLayout = layout
            let floor = layout.chevron?.maxX ?? 0
            let front = layout.slots.filter { $0.onBar && $0.pid != me && $0.frame.minX >= floor - 1 }.min { $0.frame.minX < $1.frame.minX }
            guard let divider = Self.controlFrame(.rightOfDivider, Self.read()) ?? MenuBarHider.shared.dividerFrame, let front else {
                MenuBarLog.write("divider: can't find it or the front of the bar")
                if opened { await closeOverflow() }
                return
            }
            MenuBarLog.write("divider: tucked away; dragging \(divider) to the front of the bar at \(front.frame) (try \(attempt))")
            await MenuBarDrag.drag(from: divider.center, to: CGPoint(x: front.frame.minX + 3, y: front.frame.midY), restorePointer: false)
            try? await Task.sleep(for: .milliseconds(600))
            await closeOverflow()
            try? await Task.sleep(for: .milliseconds(300))
            if MenuBarHider.inView(MenuBarHider.shared.dividerWindow) {
                MenuBarLog.write("divider: back on the bar")
                break
            }
        }
    }

    private func openOverflow() async -> Bool {
        let layout = await MenuBarHosted.settled(ownFrames: { MenuBarHider.shared.ownFrames })
        guard let chevron = layout.chevron, !layout.overflowExpanded else { return false }
        OverflowCover.shared.stepAside()
        MenuBarLog.write("overflow: opening (« at \(chevron))")
        if !MenuBarHosted.pressChevron() {
            // Accessibility refused; click it, aiming at where it is right now.
            guard let now = MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames).chevron else { return false }
            await MenuBarDrag.click(at: now.center, leavingPointer: true)
        }
        let deadline = ContinuousClock.now + .seconds(1.5)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames).overflowExpanded { break }
        }
        _ = await MenuBarHosted.settled(ownFrames: { MenuBarHider.shared.ownFrames })
        return true
    }

    private func closeOverflow() async {
        let layout = await MenuBarHosted.settled(ownFrames: { MenuBarHider.shared.ownFrames })
        guard let chevron = layout.chevron, layout.overflowExpanded else { return }
        MenuBarLog.write("overflow: closing")
        OverflowCover.shared.stepAside()
        _ = chevron
        if !MenuBarHosted.pressChevron() {
            guard let now = MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames).chevron else { return }
            await MenuBarDrag.click(at: now.center, leavingPointer: true)
        }
    }

    // MARK: Opening a hidden item

    /// While Orbit holds macOS's overflow open (the patch over « keeps away).
    private(set) var holdingOverflow = false
    /// One hidden item is out for its menu.
    @ObservationIgnored private var itemOut = false

    /// Opens a hidden item's menu the way Barbee does: the bar stays folded, only that item comes
    /// out — ⌘-dragged (through the « overflow if it's stacked away there) to the front of the
    /// visible icons, right of the strip — its menu opens, and once the menu closes it's dragged
    /// back in front of its old right-hand neighbour.
    func open(_ item: Item) async {
        if MenuBarRemoval.shared.isRemoved(item.id) {
            await openRemoved(item)
            return
        }
        let hider = MenuBarHider.shared
        let raw = Self.read()
        let now = raw.first { $0.id == item.id }
        // Already in view (or one of Orbit's own buttons): just press it.
        if let button = item.button, now?.shown ?? item.shown {
            button.performClick(nil)
            return
        }
        if let now, now.shown {
            MenuBarLog.write("open \(item.id): on the bar, pressing")
            await press(now)
            return
        }
        guard !busy, !itemOut else { return }
        if MenuBarRemoval.shared.active {
            // No strip to bring it out of: never unfold or drag anything. Stacked behind macOS's «
            // for lack of room, Accessibility can still open it where it is.
            MenuBarLog.write("open \(item.id): not switched off and not on the bar; pressing in place")
            if let now { await press(now) } else if let element = item.element { AXUIElementPerformAction(element, kAXPressAction as CFString) }
            return
        }
        // Where it goes back to: in front of the icon that was right of it, or the end of its section.
        let section = known[item.id] ?? item.section
        let row = items.filter { $0.section == section }.sorted { $0.order < $1.order }
        let neighbor = row.firstIndex { $0.id == item.id }.flatMap { k in k + 1 < row.count ? row[k + 1].id : nil }
        let home: Anchor = neighbor.map { .leftOf($0) } ?? (section == .always ? .leftOfAlways : .leftOfDivider)

        await MenuBarFreeze.hold()
        busy = true
        itemOut = true
        holdingOverflow = true
        OverflowCover.shared.stepAside()
        let pointer = MenuBarDrag.pointer
        // Room for it next to the visible icons: the strip gives up the item's width for now.
        let width = (now?.frame.width ?? item.frame.width) + 16
        hider.makeRoom(width)
        try? await Task.sleep(for: .milliseconds(350))
        MenuBarLog.write("open \(item.id): bringing it out (room \(Int(width))pt), home \(home)")
        CGDisplayHideCursor(CGMainDisplayID())
        let out = await drag(item.id, to: .rightOfDivider, section: .visible)
        CGDisplayShowCursor(CGMainDisplayID())
        MenuBarDrag.warp(to: pointer)
        let fresh = Self.read().first { $0.id == item.id }
        MenuBarLog.write("open \(item.id): \(out), on the bar \(fresh?.shown ?? false)")
        busy = false
        holdingOverflow = false
        if let fresh, fresh.shown {
            await press(fresh)
        } else if let element = item.element {
            // Couldn't bring it out; Accessibility can sometimes still open it where it is.
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
        waitStopped = false
        await waitForMenuToClose(of: fresh ?? now)

        // Back where it was, and the strip back to its full length.
        await MenuBarFreeze.hold()
        busy = true
        OverflowCover.shared.stepAside()
        let back = MenuBarDrag.pointer
        CGDisplayHideCursor(CGMainDisplayID())
        if Self.read().first(where: { $0.id == item.id })?.shown == true {
            let result = await drag(item.id, to: home, section: section)
            MenuBarLog.write("open \(item.id): put back → \(result)")
        }
        CGDisplayShowCursor(CGMainDisplayID())
        MenuBarDrag.warp(to: back)
        hider.endRoom()
        known[item.id] = section
        busy = false
        itemOut = false
    }

    /// A switched-off icon: only its app goes back on the bar for a moment — it pops in at its place,
    /// nothing else moves or reloads — the icon is pressed, and once its menu is closed exactly that
    /// switch goes off again. Picking another hidden icon meanwhile swaps them.
    private func openRemoved(_ item: Item) async {
        MenuBarLog.write("open \(item.id): asked (t \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime)), one out \(itemOut), busy \(busy))")
        if itemOut {
            // One is out already: put it back first.
            stopWaiting()
            for _ in 0..<30 where itemOut { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // A read of the bar in progress finishes in a moment; don't drop the click for it.
        for _ in 0..<20 where busy { try? await Task.sleep(for: .milliseconds(100)) }
        guard !busy, !itemOut else { return }
        itemOut = true
        defer { itemOut = false }
        waitStopped = false
        let before = Self.idsOnBar()
        if let key = MenuBarRemoval.shared.removed[item.id]?.system, let sw = MenuBarSystemSwitches.Switch(key: key) {
            await openRemovedSystem(item, sw)
        } else {
            let bundle = MenuBarRemoval.bundleID(ofItem: item.id)
            guard await MenuBarRemoval.shared.beginTemporary(bundle) else { return }
            let started = ContinuousClock.now
            let fresh = await appeared { raw in raw.first { $0.id == item.id } ?? raw.first { MenuBarRemoval.bundleID(ofItem: $0.id) == bundle } }
            MenuBarLog.write("open \(item.id): switched on for a moment, \(fresh != nil ? "in \(started.duration(to: .now))" : "didn't appear")")
            if let fresh {
                await press(fresh)
                await waitForMenuToClose(of: fresh)
            }
            MenuBarLog.write("open \(item.id): menu closed (t \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime)))")
            await MenuBarRemoval.shared.endTemporary()
        }
        // Swapped for another one: that one's coming out now, the bar isn't meant to match.
        if !waitStopped { await checkBack(to: before, after: item) }
        MenuBarLog.write("open \(item.id): done (t \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime)))")
    }

    /// One of macOS's own icons: its setting goes back on (it shows at once), it's pressed, and it's
    /// switched off again when its menu closes.
    private func openRemovedSystem(_ item: Item, _ sw: MenuBarSystemSwitches.Switch) async {
        guard MenuBarSystemSwitches.set(sw, hidden: false) else { return }
        let fresh = await appeared { raw in raw.first { $0.id == item.id } ?? raw.first { item.identifier != nil && $0.identifier == item.identifier } }
        MenuBarLog.write("open \(item.id): switched on for a moment, found \(fresh != nil)")
        if let fresh {
            await press(fresh)
            await waitForMenuToClose(of: fresh)
        }
        if MenuBarRemoval.shared.isRemoved(item.id) { MenuBarSystemSwitches.set(sw, hidden: true) }
    }

    /// Waits (up to 3s) for the switched-on icon to be laid out on the bar.
    private func appeared(_ find: ([Raw]) -> Raw?) async -> Raw? {
        var fresh: Raw?
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(50))
            fresh = find(Self.read())
            if let f = fresh {
                // MenuBarAgent shows it already; the app's own idea of its frame can lag a few
                // hundred ms behind, and pressing doesn't need it.
                if f.laidOut || Self.lastLayout.slots.contains(where: { $0.pid == f.pid && $0.hasSlot }) { return f }
            }
        }
        return fresh
    }

    /// After a hidden icon went back: the bar should hold what it held before. An icon still there
    /// that's meant to be hidden is switched off again; anything else different is only noted.
    private func checkBack(to before: Set<String>, after item: Item) async {
        try? await Task.sleep(for: .milliseconds(500))
        let now = Self.idsOnBar()
        let extra = now.subtracting(before)
        guard !extra.isEmpty else { return }
        let removal = MenuBarRemoval.shared
        let stray = extra.filter { removal.isRemoved($0) }
        MenuBarLog.write("open \(item.id): back, but \(extra.sorted()) on the bar that weren't before\(stray.isEmpty ? "" : "; switching \(stray.sorted()) off again")")
        guard !stray.isEmpty else { return }
        await removal.commit()
    }

    /// Ends ``waitForMenuToClose(of:)`` now (another hidden icon was picked).
    @ObservationIgnored private var stopWait: (() -> Void)?
    @ObservationIgnored private var waitStopped = false

    private func stopWaiting() {
        waitStopped = true
        stopWait?()
    }

    private static func iconURL(_ id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "|", with: "_")
        return Storage.dir("MenuBar/icons").appendingPathComponent(safe + ".png")
    }

    /// The icon's picture, kept for while it's off the bar.
    static func saveIcon(_ id: String, _ image: NSImage?) {
        guard let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: iconURL(id))
    }

    static func loadIcon(_ id: String) -> NSImage? { NSImage(contentsOf: iconURL(id)) }

    static func appIcon(_ bundle: String) -> NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
    }

    /// Opens an item's menu where it's drawn: Accessibility first, a real click if that's refused.
    ///
    /// Pressing through Accessibility can hold on until the item's menu closes again, so it runs off
    /// the main thread: Orbit stays free meanwhile (✦, another hidden icon). Still pressing after a
    /// moment means the menu is open; a quick failure falls back to a click.
    private func press(_ raw: Raw) async {
        if let button = raw.button { button.performClick(nil); return }
        if let element = raw.element {
            let result = PressResult()
            nonisolated(unsafe) let e = element
            DispatchQueue.global(qos: .userInteractive).async { result.set(AXUIElementPerformAction(e, kAXPressAction as CFString)) }
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(40))
                guard let r = result.value else { continue }
                if r == .success { return }
                break
            }
            if result.value == nil { return }
        }
        await MenuBarDrag.click(at: raw.frame.center, leavingPointer: true)
    }

    private final class PressResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AXError?
        var value: AXError? { lock.withLock { stored } }
        func set(_ r: AXError) { lock.withLock { stored = r } }
    }

    /// Waits for the next click or key anywhere, then for the item's menu or popover to be gone
    /// (at most two minutes).
    private func waitForMenuToClose(of raw: Raw?) async {
        let deadline = ContinuousClock.now + .seconds(120)
        defer { stopWait = nil }
        for _ in 0..<4 where !waitStopped { try? await Task.sleep(for: .milliseconds(100)) }
        while ContinuousClock.now < deadline, !waitStopped {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                var monitor: Any?
                var finished = false
                let finish = {
                    guard !finished else { return }
                    finished = true
                    if let m = monitor { NSEvent.removeMonitor(m) }
                    done.resume()
                }
                monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { finish() }
                }
                stopWait = finish
                // Also look every so often: an app may close its own menu (or Accessibility did).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
            }
            if waitStopped || !Self.menuOpen(for: raw?.pid) { return }
        }
    }

    /// A menu or popover of that app is on screen near the menu bar.
    private static func menuOpen(for pid: pid_t?) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            // The app's own popover or menu — or any menu (macOS's own items' menus belong to Control Center).
            // Not WindowServer's own: the mic/camera dot sits up there at menu level the whole time it's on.
            guard (w[kCGWindowOwnerName as String] as? String) != "Window Server",
                  let layer = w[kCGWindowLayer as String] as? Int,
                  layer >= 101 || ((w[kCGWindowOwnerPID as String] as? pid_t) == pid && layer >= 20),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let y = b["Y"] else { return false }
            return y < 80
        }
    }

    // MARK: Reading

    private struct Raw {
        let id: String
        let name: String
        let appIcon: NSImage
        let element: AXUIElement?
        var button: NSStatusBarButton? = nil
        var frame: CGRect
        var mobility: Mobility = .free
        var pid: pid_t = 0
        /// macOS's own items: `com.apple.menuextra.wifi` and so on.
        var identifier: String? = nil
        /// On the bar proper. Items macOS tucks behind its « button are listed stacked on top of each
        /// other at that spot, so overlap means "not really there".
        var shown = false
        /// Laid out somewhere a click or drag can reach: on the bar, or in the expanded overflow.
        var laidOut = false
    }

    /// Every item MenuBarAgent is showing right now — on the bar or stacked behind « — by id. Only
    /// what MenuBarAgent hosts counts: an app whose switch just went off goes on listing its item
    /// in its own Accessibility tree for a while.
    static func idsOnBar() -> Set<String> {
        let hosted = Set(MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames).slots.map(\.pid))
        return Set(read().filter { hosted.contains($0.pid) }.map(\.id))
    }

    /// Apps with an icon MenuBarAgent is showing, by bundle id (see ``idsOnBar()``).
    static func bundlesOnBar() -> Set<String> {
        Set(MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames).slots.compactMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier })
    }

    /// MenuBarAgent's slots as last read.
    private(set) static var lastLayout = MenuBarHosted.Layout.empty

    /// - Parameter only: re-place just these items against the dividers; others keep their known row.
    /// When the menu bar was last read and photographed.
    private(set) var snapshotAt: Date = .distantPast

    private func snapshot(only: Set<String>? = nil) async {
        defer { snapshotAt = Date() }
        let raw = Self.read()
        await capture(raw)
        let hider = MenuBarHider.shared
        let divider = hider.dividerFrame
        let always = hider.hasAlwaysSection ? hider.alwaysFrame : nil
        let removal = MenuBarRemoval.shared
        let byRemoving = removal.active
        var placed = raw.map { r in
            // Only an item on screen can be placed against the dividers; anything pushed away (or
            // squeezed behind the notch) keeps the section it was last seen in.
            var section = known[r.id] ?? .hidden
            let place = only.map { $0.contains(r.id) || known[r.id] == nil } ?? true
            if byRemoving {
                // No dividers: on the bar means visible, unless it's only out for a moment.
                section = removal.removed[r.id].flatMap { Section(rawValue: $0.section) } ?? .visible
            } else if place, r.laidOut, let divider = Self.controlFrame(.leftOfDivider, raw) ?? (Self.lastLayout.slots.isEmpty ? divider : nil) {
                let alwaysSlot = always == nil ? nil : Self.controlFrame(.leftOfAlways, raw)
                if let alwaysSlot, r.frame.maxX <= alwaysSlot.minX + 2 { section = .always }
                else if r.frame.maxX <= divider.minX + 2 {
                    // The always-hidden divider itself stacked away: hidden or always can't be told
                    // apart, so an icon Orbit knows to be always hidden stays there.
                    section = always != nil && alwaysSlot == nil && known[r.id] == .always ? .always : .hidden
                }
                else { section = .visible }
            }
            var order = r.frame.minX
            if r.mobility == .visibleOnly {
                // Orbit's button is always in the visible row. Tucked behind «, it's drawn at the
                // folded strip's right end instead — just before the first visible icon.
                section = .visible
                if !r.laidOut, let d = Self.controlFrame(.rightOfDivider, raw) ?? divider { order = d.maxX - 1 }
            }
            known[r.id] = section
            return Item(id: r.id, name: r.name, appIcon: r.appIcon, element: r.element, button: r.button, frame: r.frame,
                        section: section, shown: r.shown, order: order, image: images[r.id], mobility: r.mobility,
                        identifier: r.identifier)
        }
        if byRemoving {
            // Switched-off icons aren't on the bar at all; list them from what Orbit kept.
            let present = Set(placed.map(\.id))
            for (id, r) in removal.removed where !present.contains(id) {
                let section = Section(rawValue: r.section) ?? .hidden
                known[id] = section
                placed.append(Item(id: id, name: r.name, appIcon: Self.appIcon(r.bundleID), element: nil, button: nil, frame: .zero,
                                   section: section, shown: false, order: CGFloat(r.order),
                                   image: images[id] ?? Self.loadIcon(id), mobility: .free))
            }
        }
        // Ties broken by id, so reading the same bar twice gives the same list.
        placed.sort { ($0.section.order, $0.order, $0.id) < ($1.section.order, $1.order, $1.id) }
        // A refresh that finds the bar as it was changes nothing on screen (no reshuffle, no bounce).
        let key = { (list: [Item]) in list.map { "\($0.id)|\($0.section.rawValue)" } }
        if key(placed) == key(items) { items = placed } else {
            if !items.isEmpty { MenuBarLog.write("snapshot: \(Set(key(placed)).symmetricDifference(Set(key(items))).sorted())") }
            withAnimation(.spring(duration: 0.4, bounce: 0.2)) { items = placed }
        }
        systemOverflow = Self.overflowing
    }

    /// Apps whose items belong to the system; named by the item instead of the app.
    static func isSystem(_ id: String) -> Bool { systemOwners.contains(MenuBarRemoval.bundleID(ofItem: id)) }

    private static let systemOwners: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.TextInputMenuAgent", "com.apple.MenuBarAgent"]

    /// Set by read(); copied into `systemOverflow` by the snapshot.
    nonisolated(unsafe) private static var overflowing = false

    private static func read() -> [Raw] {
        let me = ProcessInfo.processInfo.processIdentifier
        var found: [Raw] = []
        var overflow = false
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != me {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            guard let bar = attribute(root, "AXExtrasMenuBar") as AXUIElement?,
                  let children = attribute(bar, kAXChildrenAttribute) as [AXUIElement]? else { continue }
            var seen: [String: Int] = [:]
            for child in children {
                guard let frame = frame(child), frame.width > 0 else { continue }
                // macOS 26 hosts its own items (Focus, Wi-Fi, sound…) without a description; the item
                // inside says what it is. Without this they'd only be told apart by position.
                let inner = (attribute(child, kAXChildrenAttribute) as [AXUIElement]?)?.first
                let identifier = (attribute(child, kAXIdentifierAttribute) as String?) ?? inner.flatMap { attribute($0, kAXIdentifierAttribute) as String? }
                let label = (attribute(child, kAXDescriptionAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (attribute(child, kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 }
                    ?? identifier.flatMap(systemName)
                // macOS 26's « button: MenuBarAgent's only item that isn't a hosted status item. It can't be
                // moved, and it only appears when the bar is too full.
                if app.bundleIdentifier == "com.apple.MenuBarAgent", (attribute(child, kAXSubroleAttribute) as String?) != "AXHostingView", inner == nil {
                    if isOnScreen(frame) { overflow = true }
                    continue
                }
                let system = systemOwners.contains(app.bundleIdentifier ?? "")
                let name = system ? (label ?? app.localizedName ?? "") : (app.localizedName ?? label ?? "")
                let key = "\(app.bundleIdentifier ?? app.localizedName ?? "?")|\(label ?? "")"
                let n = seen[key, default: 0]
                seen[key] = n + 1
                let id = n == 0 ? key : "\(key)|\(n)"
                let fixed = identifier == "com.apple.menuextra.clock" || identifier == "com.apple.menuextra.controlcenter"
                    || identifier == privacyIndicator
                found.append(Raw(id: id, name: name, appIcon: app.icon ?? NSImage(), element: child, frame: frame,
                                 mobility: fixed ? .fixed : .free, pid: app.processIdentifier, identifier: identifier))
            }
        }
        found += ownItems()
        let layout = MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames)
        lastLayout = layout
        if layout.slots.isEmpty {
            // No MenuBarAgent tree to go by: overlap among the apps' own frames says "stacked away".
            for i in found.indices {
                let f = found[i].frame
                let stacked = found.indices.contains { j in j != i && found[j].frame.intersection(f).width > 3 }
                found[i].shown = isOnScreen(f) && !stacked
                found[i].laidOut = found[i].shown
            }
        } else {
            place(&found, in: layout)
            if layout.chevron != nil { overflow = true }
        }
        overflowing = overflow
        return found
    }

    /// Gives every item its slot. macOS's own items by identifier, which never changes; everyone
    /// else within their process, closest first (an app's own idea of where its item is can lag
    /// behind while the bar is laid out, but never so far it would swap two of its items).
    private static func place(_ found: inout [Raw], in layout: MenuBarHosted.Layout) {
        let me = ProcessInfo.processInfo.processIdentifier
        let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first?.processIdentifier
        var free = Array(layout.slots.indices)
        var assigned: [Int: MenuBarHosted.Slot] = [:]
        for i in found.indices where found[i].pid == agent {
            if let k = free.firstIndex(where: { layout.slots[$0].pid == agent && layout.slots[$0].identifier == found[i].identifier }) {
                assigned[i] = layout.slots[free.remove(at: k)]
            }
        }
        for pid in Set(found.map(\.pid)) where pid != agent {
            var mine = found.indices.filter { found[$0].pid == pid }
            // Orbit's own windows sit exactly on their slots; other apps get slack.
            let tolerance: CGFloat = pid == me ? 6 : 600
            while !mine.isEmpty {
                var best: (item: Int, slot: Int, distance: CGFloat)?
                for i in mine {
                    for k in free where layout.slots[k].pid == pid {
                        let d = abs(layout.slots[k].frame.midX - found[i].frame.midX)
                        if d <= tolerance, d < (best?.distance ?? .greatestFiniteMagnitude) { best = (i, k, d) }
                    }
                }
                guard let best else { break }
                assigned[best.item] = layout.slots[best.slot]
                free.removeAll { $0 == best.slot }
                mine.removeAll { $0 == best.item }
            }
            // An icon of Orbit's stacked behind « reports a made-up window frame (off screen, at
            // 0,-33) that never moves, even once the overflow lays it out: match what's left by
            // width instead, away from Orbit's dividers.
            if pid == me, !mine.isEmpty {
                let dividers = MenuBarHider.shared.ownFrames
                for i in mine {
                    let w = found[i].frame.width
                    guard let k = free.first(where: { k in
                        let slot = layout.slots[k]
                        return slot.pid == me && abs(slot.frame.width - w) <= 1
                            && !dividers.contains { abs($0.minX - slot.frame.minX) <= 6 && abs($0.width - slot.frame.width) <= 2 }
                    }) else { continue }
                    assigned[i] = layout.slots[k]
                    free.removeAll { $0 == k }
                }
            }
        }
        for i in found.indices {
            guard let slot = assigned[i] else {
                // MenuBarAgent doesn't list every stacked-away item.
                found[i].shown = false
                found[i].laidOut = false
                continue
            }
            found[i].laidOut = slot.hasSlot
            found[i].shown = slot.onBar && isOnScreen(slot.frame)
            if slot.hasSlot { found[i].frame = slot.frame }
        }
    }

    /// macOS's own items, named the way System Settings names them.
    private static func systemName(_ identifier: String) -> String? {
        let names = ["focusmode": "Focus", "sound": "Sound", "wifi": "Wi-Fi", "battery": "Battery", "bluetooth": "Bluetooth",
                     "controlcenter": "Control Center", "clock": "Clock", "display": "Display", "screenmirroring": "Screen Mirroring",
                     "nowplaying": "Now Playing", "airdrop": "AirDrop", "keyboardbrightness": "Keyboard Brightness",
                     "accessibility": "Accessibility Shortcuts", "stagemanager": "Stage Manager", "siri": "Siri", "spotlight": "Spotlight",
                     "timemachine": "Time Machine", "vpn": "VPN", "textinput": "Input Menu", "hearing": "Hearing", "user": "Fast User Switching"]
        let key = identifier.replacingOccurrences(of: "com.apple.menuextra.", with: "")
        return names[key]?.loc ?? key
    }

    static let planetID = "com.lyu.orbit|orbit"
    /// The orange/green mic-and-camera-in-use indicator. macOS always keeps it in view (it's a privacy
    /// signal), so Orbit never moves, covers or tries to fold over it.
    static let privacyIndicator = "com.apple.menuextra.audiovideo"
    private static weak var planet: NSStatusBarButton?

    /// Orbit's planet (OrbitPlanet), when the user has it on — found by its autosave name ("Item-0").
    static var planetButton: NSStatusBarButton? {
        if let planet, planet.window != nil { return planet }
        let selector = NSSelectorFromString("statusItem")
        for window in NSApp.windows where window.responds(to: selector) {
            guard let item = window.value(forKey: "statusItem") as? NSStatusItem, item.autosaveName == "Item-0" else { continue }
            planet = item.button
            return item.button
        }
        return nil
    }

    /// Orbit's own icons. Its own process can't be read through Accessibility from the main
    /// thread, so they come from the status items themselves.
    private static func ownItems() -> [Raw] {
        let icon = NSApp.applicationIconImage ?? NSImage()
        let mine: [(String, String, NSStatusBarButton?, Mobility)] = [
            // The planet, only when the user turned it on (General); it can go anywhere.
            ("orbit", "Orbit".loc, planetButton, .free),
            ("runner", "Runner".loc, MenuBarRunner.shared.button, .free),
            ("calendar", "Calendar".loc, MenuBarCalendar.shared.button, .free),
            ("toggle", "Orbit button".loc, MenuBarHider.shared.toggleButton, .visibleOnly),
        ]
        guard let primary = NSScreen.screens.first else { return [] }
        return mine.compactMap { key, name, button, mobility in
            guard let button, let f = button.window?.frame, f.width > 0 else { return nil }
            let frame = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
            return Raw(id: "com.lyu.orbit|\(key)", name: name, appIcon: icon, element: nil, button: button, frame: frame,
                       mobility: mobility, pid: ProcessInfo.processInfo.processIdentifier)
        }
    }

    /// Where macOS's « button is, if it's showing (Accessibility coordinates, origin top-left).
    static func overflowButtonFrame() -> CGRect? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        guard let bar = attribute(root, "AXExtrasMenuBar") as AXUIElement?,
              let children = attribute(bar, kAXChildrenAttribute) as [AXUIElement]? else { return nil }
        // « is MenuBarAgent's one real button (the icons are hosting-view groups). Anything else —
        // the camera/mic indicator comes and goes in the same bar — never counts as «, so the cover
        // stays on « while the indicator shows.
        for child in children where (attribute(child, kAXRoleAttribute) as String?) == kAXButtonRole
            && ((attribute(child, kAXChildrenAttribute) as [AXUIElement]?) ?? []).isEmpty {
            if let f = frame(child), f.width > 0, isOnScreen(f) { return f }
        }
        // Older bars: the one slot with nothing inside that isn't a hosting view.
        for child in children where (attribute(child, kAXSubroleAttribute) as String?) != "AXHostingView"
            && (attribute(child, kAXRoleAttribute) as String?) != kAXButtonRole
            && ((attribute(child, kAXChildrenAttribute) as [AXUIElement]?) ?? []).isEmpty {
            if let f = frame(child), f.width > 0, isOnScreen(f) { return f }
        }
        return nil
    }

    /// After unfolding in place: are the hidden icons really in view, or did the notch and
    /// macOS's « button swallow them?
    func hiddenFitOnScreen() -> Bool {
        let raw = Self.read()
        let hiddenIDs = Set(items.filter { $0.section == .hidden }.map(\.id))
        let hidden = raw.filter { hiddenIDs.contains($0.id) }
        return !Self.overflowing && hidden.allSatisfy(\.shown)
    }

    /// In the menu bar of the main screen and not under the notch.
    private static func isOnScreen(_ f: CGRect) -> Bool {
        guard let screen = NSScreen.screens.first, f.minY < 40, f.minY >= -2,
              f.minX >= screen.frame.minX, f.maxX <= screen.frame.maxX else { return false }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           f.maxX > left.maxX, f.minX < right.minX { return false }
        return true
    }

    // MARK: Pictures

    private func capture(_ raw: [Raw]) async {
        // Wherever it's laid out — on the bar, or left of the notch in the expanded overflow.
        let visible = raw.filter { $0.laidOut && $0.frame.minY < 40 && $0.frame.minY >= -2 }
        guard !visible.isEmpty, let screen = NSScreen.screens.first else { return }
        let barHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let strip = CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: barHeight)
        guard let shot = await Self.captureMenuBar(strip, scale: screen.backingScaleFactor) else { return }
        let scale = CGFloat(shot.width) / strip.width
        for r in visible {
            let crop = CGRect(x: (r.frame.minX - strip.minX) * scale, y: r.frame.minY * scale,
                              width: r.frame.width * scale, height: min(r.frame.height, barHeight) * scale).integral
            guard let piece = shot.cropping(to: crop) else { continue }
            images[r.id] = NSImage(cgImage: piece, size: NSSize(width: r.frame.width, height: min(r.frame.height, barHeight)))
        }
    }

    /// Other menu bar managers (Barbee, Bartender, Ice…) draw their own overlay across the menu bar;
    /// leave their windows out so the picture shows the real icons underneath.
    private static let overlayApps: Set<String> = ["Barbee", "Bartender 4", "Bartender 5", "Bartender 6", "Bartender", "Ice", "Hidden Bar", "Dozer", "Vanilla"]

    private static func captureMenuBar(_ strip: CGRect, scale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return nil }
        let skip = content.applications.filter { overlayApps.contains($0.applicationName) }
        let filter = SCContentFilter(display: display, excludingApplications: skip, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = strip
        config.width = Int(strip.width * scale)
        config.height = Int(strip.height * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: AX helpers

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pos = attribute(element, kAXPositionAttribute) as AXValue?, let size = attribute(element, kAXSizeAttribute) as AXValue?,
              AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

private extension MenuBarItems.Section {
    var order: Int { self == .visible ? 2 : self == .hidden ? 1 : 0 }
}

/// A small log of menu bar moves (~/Library/Logs/Orbit/menubar.log), so a move that macOS ignores
/// can be looked at afterwards.
enum MenuBarLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("menubar.log")
    }()

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
