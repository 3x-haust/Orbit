import AppKit
import ApplicationServices

/// Where macOS really draws every menu bar item (macOS 27).
///
/// Status items are no longer windows: each display's bar is one window of `MenuBarAgent`, and its
/// Accessibility tree holds one slot per item, whose child belongs to the process that made it.
/// Those slots are the ground truth for geometry — the same approach as the open-source IceMelt
/// (an Ice fork): items macOS has put away in its « overflow are listed stacked on top of each other,
/// items on the bar never overlap, and while the overflow is expanded its items get real slots at the
/// leading end of the bar, left of the « button.
enum MenuBarHosted {
    struct Slot {
        let frame: CGRect
        let pid: pid_t
        /// `com.apple.menuextra.clock` and friends, for macOS's own items.
        let identifier: String?
        /// Laid out somewhere — on the bar, or in the expanded overflow — rather than stacked away.
        let hasSlot: Bool
        /// On the bar proper (right of the « button).
        let onBar: Bool
    }

    struct Layout {
        let slots: [Slot]
        let chevron: CGRect?

        /// The overflow is expanded when someone else's item is laid out left of the « button.
        var overflowExpanded: Bool {
            let me = ProcessInfo.processInfo.processIdentifier
            return slots.contains { $0.pid != me && $0.hasSlot && !$0.onBar }
        }

        static let empty = Layout(slots: [], chevron: nil)
    }

    /// Reads the main display's bar. Only MenuBarAgent is messaged, so a hung app can't stall it.
    static func read(ownFrames: [CGRect] = []) -> Layout {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let main = NSScreen.screens.first else { return .empty }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let me = ProcessInfo.processInfo.processIdentifier
        // MenuBarAgent keeps a bar window per Space, each listing every item. Its "extras menu bar"
        // is the one on screen, but lists only MenuBarAgent's own items (sound, Wi-Fi, clock, «…),
        // so it can't stand in for the bar. It does tell which window is showing: that window's slots
        // sit exactly where the extras bar's do. (Picking by guesswork once chose another Space's
        // stale bar, whose « sat where the runner is here — and Orbit clicked the runner.)
        let shown: AXUIElement? = attribute(root, "AXExtrasMenuBar")
        let shownFrames = ((shown.flatMap { attribute($0, kAXChildrenAttribute) as [AXUIElement]? }) ?? []).compactMap { frame($0) }
        let windows: [AXUIElement] = attribute(root, kAXWindowsAttribute) ?? []
        // Every status window of Orbit's sits exactly on its slot in the bar that's showing — the
        // expanded overflow included, which the other Spaces' bars don't reflect.
        let own = ownFrames + Self.ownStatusFrames(main)

        // One window per display, normally; the agent also keeps one per Space, and has been seen with
        // two for one display. The drawn one is where Orbit's own items sit where AppKit says they are.
        var best: (score: Int, slots: [(CGRect, pid_t, String?)], chevron: CGRect?)?
        for window in windows {
            // Accessibility puts the main display at the origin, top-left. The "extras" bar spans only
            // the status-item end of the bar (e.g. x 903…1512), so it's taken as long as it lies
            // within the main display's top edge; the per-Space windows span the whole width.
            guard let host = frame(window), Self.onMainBar(host, main) else { continue }
            var slots: [(CGRect, pid_t, String?)] = []
            var chevron: CGRect?
            for slot in (attribute(window, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let f = frame(slot), f.width > 0 else { continue }
                // The « button is the one slot with nothing behind it.
                guard let content = (attribute(slot, kAXChildrenAttribute) as [AXUIElement]?)?.first else {
                    chevron = f
                    continue
                }
                var pid: pid_t = 0
                AXUIElementGetPid(content, &pid)
                if pid == 0 { pid = me }
                var identifier: String?
                if pid == agent.processIdentifier {
                    let extra = (attribute(content, kAXChildrenAttribute) as [AXUIElement]?)?.first ?? content
                    identifier = attribute(extra, kAXIdentifierAttribute)
                }
                slots.append((f, pid, identifier))
            }
            let matchesShown = (slots.map(\.0) + [chevron].compactMap { $0 }).filter { f in shownFrames.contains { $0 == f } }.count
            let score = matchesShown * 10_000
                + slots.filter { $0.1 == me }.filter { s in own.contains { abs($0.minX - s.0.minX) <= 2 && abs($0.width - s.0.width) <= 2 } }.count * 100 + slots.count
            if best == nil || score > best!.score { best = (score, slots, chevron) }
        }
        guard let best else { return .empty }

        // Stacked items don't all share one x exactly, so overlap is what tells them apart; Orbit's own
        // items are exempt from the overlap test (a folded divider reaches under the « button).
        var counts: [Int: Int] = [:]
        for s in best.slots { counts[Int(s.0.minX), default: 0] += 1 }
        let slots = best.slots.map { s -> Slot in
            let unique = counts[Int(s.0.minX)] == 1
            let overlapping = s.1 != me && best.slots.contains { o in
                o.1 != me && !(o.0 == s.0 && o.1 == s.1) && o.0.intersection(s.0).width > 4
            }
            let laidOut = unique && !overlapping
            let onBar = laidOut && (s.1 == me || best.chevron.map { s.0.minX >= $0.minX } ?? true)
            return Slot(frame: s.0, pid: s.1, identifier: s.2, hasSlot: laidOut, onBar: onBar)
        }
        return Layout(slots: slots.sorted { $0.frame.minX < $1.frame.minX }, chevron: best.chevron)
    }

    /// Presses macOS's « button through Accessibility — found fresh, right now — instead of clicking
    /// where it was a moment ago: the bar shifts while it opens and closes, and a click aimed at a
    /// stale spot lands on whatever icon slid in there (the runner, usually).
    static func pressChevron() -> Bool {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
              let main = NSScreen.screens.first else { return false }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let shown: AXUIElement? = attribute(root, "AXExtrasMenuBar")
        for window in shown.map({ [$0] }) ?? (attribute(root, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
            guard let host = frame(window), Self.onMainBar(host, main) else { continue }
            for slot in (attribute(window, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard let f = frame(slot), f.width > 0,
                      ((attribute(slot, kAXChildrenAttribute) as [AXUIElement]?) ?? []).isEmpty else { continue }
                for target in [slot] + ((attribute(slot, kAXChildrenAttribute) as [AXUIElement]?) ?? []) {
                    if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success { return true }
                }
            }
        }
        return false
    }

    /// Reads until the bar holds still (two equal reads 150ms apart, at most `timeout`).
    static func settled(ownFrames: @MainActor () -> [CGRect], timeout: Duration = .seconds(1.5)) async -> Layout {
        let deadline = ContinuousClock.now + timeout
        var previous: [CGRect]?
        var latest = Layout.empty
        while true {
            latest = await MainActor.run { read(ownFrames: ownFrames()) }
            let frames = latest.slots.map(\.frame) + [latest.chevron ?? .zero]
            if frames == previous || ContinuousClock.now >= deadline { return latest }
            previous = frames
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    // MARK: AX helpers

    /// Orbit's status-item windows on the main display's bar, in Accessibility coordinates.
    private static func ownStatusFrames(_ main: NSScreen) -> [CGRect] {
        NSApp.windows.compactMap { w in
            guard String(describing: type(of: w)).contains("StatusBarWindow"), w.isVisible else { return nil }
            let f = w.frame
            guard f.width > 0, f.minY >= main.frame.maxY - 40, f.minX >= main.frame.minX, f.maxX <= main.frame.maxX else { return nil }
            return CGRect(x: f.minX, y: main.frame.maxY - f.maxY, width: f.width, height: f.height)
        }
    }

    private static func onMainBar(_ host: CGRect, _ main: NSScreen) -> Bool {
        host.minY == 0 && host.minX >= main.frame.minX - 1 && host.maxX <= main.frame.maxX + 1 && host.height < 60
    }

    private static func isHosting(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as String?) == "AXHostingView"
    }

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

/// Real input for the menu bar, the only kind MenuBarAgent listens to: hosted items have no window
/// to aim an event at, so clicks and ⌘-drags go to the HID system at the item's slot, as if the person
/// did them. Only used when the user rearranges icons or opens a hidden one.
enum MenuBarDrag {
    /// ⌘-drags from `start` to `end`. The pointer is put back afterwards.
    static func drag(from start: CGPoint, to end: CGPoint, restorePointer: Bool = true) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? start
        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            e?.flags = .maskCommand
            if type == .leftMouseDown || type == .leftMouseUp { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
            return e
        }
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if restorePointer { CGWarpMouseCursorPosition(original) }
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        event(.leftMouseDown, start)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(30))
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            event(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(30))
        }
        event(.leftMouseUp, end)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// A plain left click. The expanded overflow stays open only while the pointer is over it, so a
    /// click that opens it (or an item in it) can leave the pointer there.
    static func click(at point: CGPoint, leavingPointer: Bool = false) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? point
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if !leavingPointer { CGWarpMouseCursorPosition(original) }
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            e?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
