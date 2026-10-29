import AppKit
import SwiftUI

/// macOS's Hot Corners, with Orbit's tools on the menu: push the pointer into a corner of the screen
/// and the corner's action runs — the Ring, a capture, the clipboard, a window layout, or one of
/// macOS's own corner actions (Mission Control, Desktop, screen saver…).
@MainActor @Observable
final class HotCorners {
    static let shared = HotCorners()

    enum Corner: String, CaseIterable, Identifiable {
        case topLeft = "tl", topRight = "tr", bottomLeft = "bl", bottomRight = "br"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            }
        }

        var isTop: Bool { self == .topLeft || self == .topRight }
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        /// macOS's own key for this corner in com.apple.dock.
        var dockKey: String { "wvous-\(rawValue)-corner" }
    }

    /// What a corner does. Stored as a string: "", "ring", "cmd.<OrbitAction>" or "sys.<System>".
    enum Target: Hashable {
        case none, ring
        case command(OrbitAction)
        case system(System)

        init(_ raw: String) {
            if raw == "ring" { self = .ring; return }
            if raw.hasPrefix("cmd."), let a = OrbitAction(rawValue: String(raw.dropFirst(4))) { self = .command(a); return }
            if raw.hasPrefix("sys."), let s = System(rawValue: String(raw.dropFirst(4))) { self = .system(s); return }
            self = .none
        }

        var raw: String {
            switch self {
            case .none: ""
            case .ring: "ring"
            case .command(let a): "cmd.\(a.rawValue)"
            case .system(let s): "sys.\(s.rawValue)"
            }
        }

        @MainActor var title: String {
            switch self {
            case .none: "Nothing".loc
            case .ring: "Orbit Ring".loc
            case .command(let a): a.title
            case .system(let s): s.title.loc
            }
        }

        var symbol: String {
            switch self {
            case .none: "minus"
            case .ring: "circle.dashed"
            case .command(let a): a.symbol
            case .system(let s): s.symbol
            }
        }
    }

    /// The corner actions macOS has, so Orbit can stand in for them.
    enum System: String, CaseIterable {
        case missionControl, appWindows, desktop, launchpad, notificationCenter, quickNote, screenSaver
        var title: String {
            switch self {
            case .missionControl: "Mission Control"
            case .appWindows: "Application Windows"
            case .desktop: "Desktop"
            case .launchpad: "Apps"
            case .notificationCenter: "Notification Center"
            case .quickNote: "Quick Note"
            case .screenSaver: "Start Screen Saver"
            }
        }
        var symbol: String {
            switch self {
            case .missionControl: "rectangle.3.group"
            case .appWindows: "macwindow.on.rectangle"
            case .desktop: "menubar.dock.rectangle"
            case .launchpad: "square.grid.3x3"
            case .notificationCenter: "bell.badge"
            case .quickNote: "note.text"
            case .screenSaver: "sparkles.tv"
            }
        }
    }

    /// Hold a key while reaching the corner, so it never fires by accident.
    enum Modifier: Int, CaseIterable {
        case none = 0, command, option, control, shift
        var flags: NSEvent.ModifierFlags {
            switch self {
            case .none: []
            case .command: .command
            case .option: .option
            case .control: .control
            case .shift: .shift
            }
        }
        var label: String {
            switch self {
            case .none: "No key"
            case .command: "⌘"
            case .option: "⌥"
            case .control: "⌃"
            case .shift: "⇧"
            }
        }
    }

    static let enabledKey = "corners.enabled"
    static let delayKey = "corners.delay"
    static let dragKey = "corners.whileDragging"
    static let glowKey = "corners.glow"

    var enabled: Bool { didSet { Pref.defaults.set(enabled, forKey: Self.enabledKey); restart() } }
    /// Seconds the pointer has to rest in the corner.
    var delay: Double { didSet { Pref.defaults.set(delay, forKey: Self.delayKey) } }
    /// Fire while dragging something (a file to the Shelf, a window to Mission Control).
    var whileDragging: Bool { didSet { Pref.defaults.set(whileDragging, forKey: Self.dragKey) } }
    /// The light that gathers in the corner while it's about to fire.
    var glowing: Bool { didSet { Pref.defaults.set(glowing, forKey: Self.glowKey) } }
    private(set) var targets: [Corner: Target] = [:]
    private(set) var modifiers: [Corner: Modifier] = [:]
    /// The corner the pointer is resting in right now, for the page's preview.
    private(set) var active: Corner?

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var dwell: DispatchWorkItem?
    @ObservationIgnored private var armed: Set<Corner> = Set(Corner.allCases)
    @ObservationIgnored private let glow = CornerGlow()

    private init() {
        let d = Pref.defaults
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? false
        delay = d.object(forKey: Self.delayKey) as? Double ?? 0.2
        whileDragging = d.object(forKey: Self.dragKey) as? Bool ?? true
        glowing = d.object(forKey: Self.glowKey) as? Bool ?? true
        for c in Corner.allCases {
            targets[c] = Target(d.string(forKey: "corners.\(c.rawValue)") ?? "")
            modifiers[c] = Modifier(rawValue: d.integer(forKey: "corners.\(c.rawValue).mod")) ?? .none
        }
        if d.object(forKey: "corners.seeded2") == nil {
            seedFromMacOS()
        }
    }

    func target(_ c: Corner) -> Target { targets[c] ?? .none }
    func modifier(_ c: Corner) -> Modifier { modifiers[c] ?? .none }

    func set(_ t: Target, for c: Corner) {
        targets[c] = t
        Pref.defaults.set(t.raw, forKey: "corners.\(c.rawValue)")
        if t != .none, !enabled { enabled = true }
    }

    func set(_ m: Modifier, for c: Corner) {
        modifiers[c] = m
        Pref.defaults.set(m.rawValue, forKey: "corners.\(c.rawValue).mod")
    }

    // MARK: Watching the pointer

    func start() { restart() }

    private func restart() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard enabled else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Global monitors only see other apps' events; Orbit's own windows need a local one too.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { e in
            MainActor.assumeIsolated { HotCorners.shared.moved(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
            MainActor.assumeIsolated { HotCorners.shared.moved(e) }
            return e
        }) { monitors.append(m) }
    }

    private func moved(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dragging = event.type != .mouseMoved
        // Re-arm a corner once the pointer has clearly left it.
        for c in armed.symmetricDifference(Set(Corner.allCases)) where !near(c, p, within: 40) { armed.insert(c) }

        guard let corner = Corner.allCases.first(where: { near($0, p, within: 3) }) else {
            leave()
            return
        }
        guard corner != active else { return }
        leave()
        guard armed.contains(corner), target(corner) != .none, !dragging || whileDragging,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == modifier(corner).flags
        else { return }
        active = corner
        let screen = screen(for: p)
        if glowing { glow.show(corner, on: screen, duration: delay) }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let hc = HotCorners.shared
                guard hc.active == corner, hc.near(corner, NSEvent.mouseLocation, within: 6) else { return }
                hc.armed.remove(corner)
                hc.active = nil
                if hc.glowing { hc.glow.fire() }
                hc.run(hc.target(corner))
            }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func leave() {
        dwell?.cancel()
        dwell = nil
        if active != nil { glow.hide() }
        active = nil
    }

    /// Is `p` within `d` points of a real outer corner of some screen — one the pointer stops at,
    /// not a corner that runs on into a neighbouring display?
    private func near(_ c: Corner, _ p: CGPoint, within d: CGFloat) -> Bool {
        for s in NSScreen.screens {
            let f = s.frame
            let x = c.isLeft ? f.minX : f.maxX - 1
            let y = c.isTop ? f.maxY - 1 : f.minY
            guard abs(p.x - x) <= d, abs(p.y - y) <= d else { continue }
            let beyondX = CGPoint(x: c.isLeft ? f.minX - 2 : f.maxX + 1, y: y)
            let beyondY = CGPoint(x: x, y: c.isTop ? f.maxY + 1 : f.minY - 2)
            if NSScreen.screens.contains(where: { $0.frame.contains(beyondX) || $0.frame.contains(beyondY) }) { continue }
            return true
        }
        return false
    }

    private func screen(for p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    // MARK: Running

    func run(_ t: Target) {
        switch t {
        case .none: break
        case .ring: OrbitRing.shared.open(hold: false)
        case .command(let a): a.perform()
        case .system(let s): Self.run(s)
        }
    }

    private static func run(_ s: System) {
        let missionControl = "/System/Applications/Mission Control.app"
        switch s {
        case .missionControl:
            NSWorkspace.shared.open(URL(fileURLWithPath: missionControl))
        case .appWindows, .desktop:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: missionControl + "/Contents/MacOS/Mission Control")
            p.arguments = [s == .desktop ? "1" : "2"]
            try? p.run()
        case .launchpad:
            for id in ["com.apple.apps.launcher", "com.apple.launchpad.launcher"] {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    NSWorkspace.shared.open(url)
                    return
                }
            }
        case .screenSaver:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        case .notificationCenter:
            openNotificationCenter()
        case .quickNote:
            // macOS's own shortcut for Quick Note is Globe (fn) + Q.
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down) // Q
                e?.flags = .maskSecondaryFn
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Notification Center opens from the clock in the menu bar: press it through Accessibility,
    /// or click it if that's refused.
    private static func openNotificationCenter() {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
            return v as? T
        }
        let bars: [AXUIElement] = (attribute(root, "AXExtrasMenuBar") as AXUIElement?).map { [$0] }
            ?? attribute(root, kAXWindowsAttribute) ?? []
        for bar in bars {
            for slot in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                let content = (attribute(slot, kAXChildrenAttribute) as [AXUIElement]?)?.first
                let extra = content.flatMap { (attribute($0, kAXChildrenAttribute) as [AXUIElement]?)?.first } ?? content
                guard let extra, (attribute(extra, kAXIdentifierAttribute) as String?) == "com.apple.menuextra.clock" else { continue }
                for target in [extra, content, slot].compactMap({ $0 }) {
                    if AXUIElementPerformAction(target, kAXPressAction as CFString) == .success { return }
                }
                // Accessibility refused: click the clock where it's drawn.
                var p = CGPoint.zero, s = CGSize.zero
                guard let pos: AXValue = attribute(slot, kAXPositionAttribute), let size: AXValue = attribute(slot, kAXSizeAttribute),
                      AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return }
                let center = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
                let original = CGEvent(source: nil)?.location ?? center
                for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
                CGWarpMouseCursorPosition(original)
                CGAssociateMouseAndMouseCursorPosition(1)
                return
            }
        }
    }

    // MARK: macOS's own hot corners

    /// macOS's corner actions by their com.apple.dock codes, in Orbit's terms.
    private static func target(macOS code: Int) -> Target? {
        switch code {
        case 2: .system(.missionControl)
        case 3: .system(.appWindows)
        case 4: .system(.desktop)
        case 5: .system(.screenSaver)
        case 10: .command(.sleepDisplay)
        case 11: .system(.launchpad)
        case 12: .system(.notificationCenter)
        case 13: .command(.lockScreen)
        case 14: .system(.quickNote)
        default: nil
        }
    }

    /// Corners macOS itself has an action on. Both firing at once would be a mess.
    var macOSCorners: [Corner: Int] {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        var out: [Corner: Int] = [:]
        for c in Corner.allCases {
            if let code = dock?.object(forKey: c.dockKey) as? Int, code > 1 { out[c] = code }
        }
        return out
    }

    /// First run: start from whatever macOS's corners do now, so nothing changes until you change it.
    /// Run again once when Notification Center and Quick Note became choices, for corners still empty.
    private func seedFromMacOS() {
        Pref.defaults.set(true, forKey: "corners.seeded")
        Pref.defaults.set(true, forKey: "corners.seeded2")
        let dock = UserDefaults(suiteName: "com.apple.dock")
        for c in Corner.allCases where target(c) == .none {
            guard let code = dock?.object(forKey: c.dockKey) as? Int, let t = Self.target(macOS: code) else { continue }
            targets[c] = t
            Pref.defaults.set(t.raw, forKey: "corners.\(c.rawValue)")
            let mod = dock?.object(forKey: "wvous-\(c.rawValue)-modifier") as? Int ?? 0
            let m: Modifier = mod & (1 << 20) != 0 ? .command : mod & (1 << 19) != 0 ? .option
                : mod & (1 << 18) != 0 ? .control : mod & (1 << 17) != 0 ? .shift : .none
            modifiers[c] = m
            Pref.defaults.set(m.rawValue, forKey: "corners.\(c.rawValue).mod")
        }
    }

    /// macOS's name for a corner action Orbit can't stand in for (Notification Center, Quick Note).
    static func macOSName(_ code: Int) -> String? {
        switch code {
        case 6: "Disable Screen Saver"
        default: nil
        }
    }

    /// Corners where macOS and Orbit would both fire, once Orbit is on.
    var conflicts: [Corner] {
        macOSCorners.compactMap { c, code in target(c) != .none || Self.target(macOS: code) != nil ? c : nil }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Orbit takes over: macOS's corners are moved into Orbit and switched off in macOS. A corner
    /// whose macOS action Orbit can't do (Notification Center, Quick Note) stays with macOS unless
    /// Orbit already has something there.
    func takeOverFromMacOS() {
        for (c, code) in macOSCorners {
            if target(c) == .none, let t = Self.target(macOS: code) { set(t, for: c) }
        }
        let taken = conflicts.filter { target($0) != .none }
        guard !taken.isEmpty else { return }
        let script = taken.map { "defaults write com.apple.dock \($0.dockKey) -int 1" }.joined(separator: "; ") + "; killall Dock"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotCorners.shared.macOSChanged += 1 } }
        }
        try? p.run()
        enabled = true
    }

    /// Bumped when macOS's corner settings change, so the page re-reads them.
    var macOSChanged = 0
}

// MARK: - Feedback

/// A soft light that gathers in the corner while the pointer rests there, and blooms when it fires.
@MainActor
private final class CornerGlow {
    @Observable final class Model {
        var corner: HotCorners.Corner = .topLeft
        var progress: CGFloat = 0
        var fired = false
        var visible = false
    }

    private let model = Model()
    private var panel: NSPanel?
    private static let side: CGFloat = 140

    func show(_ corner: HotCorners.Corner, on screen: NSScreen?, duration: Double) {
        guard let screen else { return }
        let f = screen.frame
        let s = Self.side
        let rect = NSRect(x: corner.isLeft ? f.minX : f.maxX - s, y: corner.isTop ? f.maxY - s : f.minY, width: s, height: s)
        let p = panel ?? make()
        p.setFrame(rect, display: false)
        model.corner = corner
        model.fired = false
        model.progress = 0
        model.visible = true
        p.orderFrontRegardless()
        withAnimation(.easeOut(duration: max(0.12, duration))) { model.progress = 1 }
    }

    func fire() {
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { model.fired = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.hide() }
    }

    func hide() {
        withAnimation(.easeIn(duration: 0.18)) { model.visible = false; model.progress = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: GlowView(model: model))
        host.sizingOptions = []
        p.contentView = FloatingPanel.container(for: host)
        panel = p
        return p
    }

    private struct GlowView: View {
        let model: Model

        var body: some View {
            let c = model.corner
            let anchor = UnitPoint(x: c.isLeft ? 0 : 1, y: c.isTop ? 0 : 1)
            ZStack {
                // The light pooling in the corner.
                RadialGradient(colors: [.white.opacity(0.42), .white.opacity(0.12), .clear],
                               center: anchor, startRadius: 0, endRadius: CornerGlow.side * (model.fired ? 1.1 : 0.85))
                    .scaleEffect(0.35 + 0.65 * model.progress, anchor: anchor)
                // A thin ring arc that closes as the dwell completes, with Orbit's satellite riding it.
                Circle()
                    .trim(from: 0, to: 0.25 * model.progress)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 88, height: 88)
                    .rotationEffect(.degrees(rotation(c)))
                    .position(x: c.isLeft ? 0 : CornerGlow.side, y: c.isTop ? 0 : CornerGlow.side)
                    .opacity(model.fired ? 0 : 1)
            }
            .frame(width: CornerGlow.side, height: CornerGlow.side)
            .opacity(model.visible ? 1 : 0)
            .scaleEffect(model.fired ? 1.15 : 1, anchor: anchor)
            .allowsHitTesting(false)
        }

        /// Starts the quarter arc on the screen edge and sweeps it into the screen.
        private func rotation(_ c: HotCorners.Corner) -> Double {
            switch c {
            case .topLeft: 0
            case .topRight: 90
            case .bottomRight: 180
            case .bottomLeft: 270
            }
        }
    }
}
