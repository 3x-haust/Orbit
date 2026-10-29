import AppKit
import SwiftUI

/// Orbit's notch: one black shape per screen that's the notch at rest and grows into whatever needs
/// it — live activities beside the camera, the volume and brightness HUD, a short notice, the
/// song-change banner, or the full panel with its tabs. Everything that uses the notch goes through
/// here, so two things never fight over it. In order: Face Unlock (its own HUD, everything else
/// steps aside) › the HUD › the open panel › a notice › the banner › live activities › the plain notch.
@MainActor @Observable
final class NotchCenter {
    static let shared = NotchCenter()
    static var enabled: Bool { NotchPrefs.bool(NotchPrefs.enabled) }

    enum Tab: String, CaseIterable, Identifiable {
        case home, shelf, mirror, timer, clipboard
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home"
            case .shelf: "Shelf"
            case .mirror: "Mirror"
            case .timer: "Timer"
            case .clipboard: "Clipboard"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .shelf: "tray.full.fill"
            case .mirror: "person.crop.square.fill"
            case .timer: "timer"
            case .clipboard: "doc.on.clipboard.fill"
            }
        }

        var pref: String {
            switch self {
            case .home: NotchPrefs.tabHome
            case .shelf: NotchPrefs.tabShelf
            case .mirror: NotchPrefs.tabMirror
            case .timer: NotchPrefs.tabTimer
            case .clipboard: NotchPrefs.tabClipboard
            }
        }
    }

    /// What sits beside the closed notch.
    enum Ear: Equatable {
        case music, timer, recording, download, awake
        /// Just plugged in (true) or unplugged (false), for a few seconds.
        case charging(Bool)
    }

    enum Phase: Equatable {
        case hidden, idle, ears(Ear), hud, peek, banner, expanded

        var collapsed: Bool {
            switch self {
            case .idle, .ears: true
            default: false
            }
        }
    }

    struct HUD: Equatable {
        var kind: DisplayOSD.Kind
        var value: Double
        var caption: String?
        var display: CGDirectDisplayID
    }

    /// A short notice: charging, Focus, a device, a finished download or timer.
    struct Peek: Equatable {
        var symbol: String
        var tint: Color
        var title: String
        var detail: String?
        var trailing: String?
        /// Battery levels shown on the right instead of `trailing` (AirPods: left, right, case).
        var levels: [Level] = []

        struct Level: Equatable {
            var symbol: String
            var percent: Int
        }
    }

    struct Config: Equatable {
        var scale: CGFloat = 1
        var radius: CGFloat = 22
        var shadow = true
        var haptics = true
        var hoverOpen = true
        var openDelay = 0.12
        var closeDelay = 0.35
        var swipe = true
        var allScreens = false
        var hideFullScreen = true
        /// Open on the tab last looked at, instead of Home.
        var openLast = false
        var tabs: [Tab] = Tab.allCases
        var live: Set<String> = []

        static func load() -> Config {
            let d = Pref.defaults
            var c = Config()
            c.scale = CGFloat(min(max(d.double(forKey: NotchPrefs.scale), 0.85), 1.25))
            c.radius = CGFloat(min(max(d.double(forKey: NotchPrefs.radius), 10), 34))
            c.shadow = d.bool(forKey: NotchPrefs.shadow)
            c.haptics = d.bool(forKey: NotchPrefs.haptics)
            c.hoverOpen = d.bool(forKey: NotchPrefs.hoverOpen)
            c.openDelay = min(max(d.double(forKey: NotchPrefs.openDelay), 0), 1)
            c.closeDelay = min(max(d.double(forKey: NotchPrefs.closeDelay), 0.1), 2)
            c.swipe = d.bool(forKey: NotchPrefs.swipe)
            c.allScreens = d.string(forKey: NotchPrefs.screens) == "all"
            c.hideFullScreen = d.bool(forKey: NotchPrefs.hideFullScreen)
            c.openLast = d.string(forKey: NotchPrefs.openTab) == "last"
            c.tabs = Tab.allCases.filter { d.bool(forKey: $0.pref) }
            c.live = Set([NotchPrefs.liveMusic, NotchPrefs.liveCharging, NotchPrefs.liveTimer, NotchPrefs.liveRecording,
                          NotchPrefs.liveAwake, NotchPrefs.liveFocus, NotchPrefs.liveDownloads, NotchPrefs.liveBluetooth]
                .filter { d.bool(forKey: $0) })
            return c
        }
    }

    private(set) var config = Config()
    private(set) var hud: HUD?
    private(set) var peek: Peek?
    private(set) var banner: WidgetContent?
    /// The screen whose notch is open, if any.
    private(set) var expandedOn: CGDirectDisplayID?
    var tab: Tab = .home
    private(set) var dropTargeted = false
    /// Screens showing a full-screen app right now (the notch steps aside there).
    private(set) var hiddenFor: Set<CGDirectDisplayID> = []
    /// Where notices and the banner go: the screen with the camera housing, else the main one.
    private(set) var primary: CGDirectDisplayID = CGMainDisplayID()

    /// A short-lived ear (charging), ahead of the ongoing ones.
    private(set) var flashEar: Ear?
    /// How wide an ear can be on each screen before it would cover menus or menu bar items.
    private(set) var rooms: [CGDirectDisplayID: CGFloat] = [:]

    @ObservationIgnored private var windows: [CGDirectDisplayID: NotchWindow] = [:]
    @ObservationIgnored private var flashEarWork: DispatchWorkItem?
    @ObservationIgnored private var roomsMeasuredAt: TimeInterval = 0
    @ObservationIgnored private var roomTask: Task<Void, Never>?
    @ObservationIgnored private var lastMorph: TimeInterval = 0
    @ObservationIgnored private var swipeSpent = false
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var openWork: DispatchWorkItem?
    @ObservationIgnored private var closeWork: DispatchWorkItem?
    @ObservationIgnored private var hudWork: DispatchWorkItem?
    @ObservationIgnored private var peekWork: DispatchWorkItem?
    @ObservationIgnored private var bannerWork: DispatchWorkItem?
    @ObservationIgnored private var hovering: Set<CGDirectDisplayID> = []
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var dragEndMonitor: Any?
    @ObservationIgnored private var pointerMonitors: [Any] = []
    @ObservationIgnored private var tabWhenClosed: Tab = .home
    @ObservationIgnored private var closedAt: TimeInterval = -100
    @ObservationIgnored private var swipe: (amount: CGFloat, at: TimeInterval) = (0, 0)

    private init() {}

    // MARK: Lifecycle

    /// Matches what's turned on; called at launch and whenever a notch setting changes.
    func apply() {
        config = Config.load()
        NowPlaying.shared.update() // the music activity and Home tab need the current song
        guard Self.enabled else { teardown(); return }
        // The top shelf's own window gives way to the notch's Shelf tab.
        if Shelf.edge == .top, Shelf.shared.isVisible { Shelf.shared.hide() }
        if observers.isEmpty { observe() }
        rebuildWindows()
        NotchLive.shared.apply(config)
        checkFullScreen()
    }

    private func teardown() {
        NotchLive.shared.apply(nil)
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        hovering.removeAll()
        expandedOn = nil
        stopClickMonitor()
    }

    private func observe() {
        // The windows ignore the mouse unless it's over the shape, so the pointer is watched here:
        // each move is one rect test per screen. Moves over Orbit's own windows come to the local one.
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { _ in
            MainActor.assumeIsolated { NotchCenter.shared.pointerMoved(NSEvent.mouseLocation) }
        }) { pointerMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { event in
            MainActor.assumeIsolated { NotchCenter.shared.pointerMoved(NSEvent.mouseLocation) }
            return event
        }) { pointerMonitors.append(m) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchCenter.shared.rebuildWindows() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let c = NotchCenter.shared
                    c.checkFullScreen()
                    c.measureRooms()
                    // A Space switch animates; look again once it has landed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        c.checkFullScreen()
                        c.measureRooms(force: true)
                    }
                }
            })
        }
    }

    private func rebuildWindows() {
        guard Self.enabled else { return }
        var targets = NSScreen.screens.filter { $0.hasCameraHousing || config.allScreens }
        // No notch on this Mac: draw one on the main screen.
        if targets.isEmpty, let main = NSScreen.screens.first { targets = [main] }
        let ids = Set(targets.map(\.displayID))
        for (id, w) in windows where !ids.contains(id) {
            w.orderOut(nil)
            windows[id] = nil
        }
        for screen in targets {
            if let w = windows[screen.displayID] { w.place(on: screen) } else { windows[screen.displayID] = NotchWindow(screen: screen) }
        }
        primary = targets.first(where: \.hasCameraHousing)?.displayID ?? NSScreen.main?.displayID ?? CGMainDisplayID()
        measureRooms(force: true)
    }

    // MARK: What each screen shows

    func phase(on display: CGDirectDisplayID) -> Phase {
        if NotchHUD.shared.model.expanded || hiddenFor.contains(display) { return .hidden }
        if let hud, hud.display == display { return .hud }
        if expandedOn == display { return .expanded }
        if display == primary {
            if peek != nil { return .peek }
            if banner != nil { return .banner }
        }
        if let ear = currentEar, room(on: display) >= NotchGeometry.minEar { return .ears(ear) }
        return .idle
    }

    var currentEar: Ear? {
        #if DEBUG
        if debugEarOn { return debugEar }
        #endif
        if let flashEar { return flashEar }
        let live = config.live
        if live.contains(NotchPrefs.liveRecording), Recorder.shared.isRecording { return .recording }
        if live.contains(NotchPrefs.liveTimer), NotchTimer.shared.isRunning { return .timer }
        if live.contains(NotchPrefs.liveDownloads), !NotchDownloads.shared.items.isEmpty { return .download }
        if live.contains(NotchPrefs.liveMusic), NowPlaying.shared.track != nil, NowPlaying.shared.playing { return .music }
        if live.contains(NotchPrefs.liveAwake), KeepAwake.shared.isOn { return .awake }
        return nil
    }

    // MARK: Opening and closing

    /// The pointer moved (or a shape changed under it): each window takes the mouse only while it's
    /// over that window's shape, and that's also what hovering means — a drag included, so files
    /// can be dropped on the notch.
    func pointerMoved(_ p: NSPoint) {
        for (id, w) in windows {
            let inside = w.hitRect()?.contains(p) ?? false
            if w.ignoresMouseEvents == inside { w.ignoresMouseEvents = !inside }
            if inside != hovering.contains(id) { hover(inside, on: id) }
        }
    }

    func hover(_ inside: Bool, on display: CGDirectDisplayID) {
        #if DEBUG
        if debugEarOn { return } // promo frames: the real pointer doesn't open or close it
        #endif
        if inside { hovering.insert(display) } else { hovering.remove(display) }
        if inside {
            closeWork?.cancel()
            guard config.hoverOpen, expandedOn == nil, canOpen(display) else { return }
            openWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovering.contains(display) else { return }
                self.open(on: display, byHover: true)
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + config.openDelay, execute: work)
        } else {
            openWork?.cancel()
            guard expandedOn == display, !dropTargeted else { return }
            scheduleClose(after: config.closeDelay)
        }
    }

    /// Opens the notch. `tab` is for opens with a reason to show one (a file dragged in, the Shelf
    /// shortcut); everything else lands on Home — unless the setting says the last tab, or the
    /// pointer slipped off and came straight back (a hover open within 1.5s of closing).
    func open(on display: CGDirectDisplayID? = nil, tab: Tab? = nil, byHover: Bool = false) {
        guard Self.enabled, !config.tabs.isEmpty else { return }
        let display = display ?? (windows[NSScreen.active.displayID] != nil ? NSScreen.active.displayID : primary)
        guard windows[display] != nil, canOpen(display) else { return }
        if let tab, config.tabs.contains(tab) || (tab == .shelf && shelfAvailable) {
            self.tab = tab
        } else if expandedOn == nil {
            let quickReturn = byHover && ProcessInfo.processInfo.systemUptime - closedAt < 1.5
            let wanted = config.openLast || quickReturn ? tabWhenClosed : homeTab
            self.tab = config.tabs.contains(wanted) || (wanted == .shelf && shelfAvailable) ? wanted : homeTab
        }
        guard expandedOn != display else { return }
        closeWork?.cancel()
        morph { expandedOn = display }
        if config.haptics { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
        startClickMonitor()
    }

    func close() {
        openWork?.cancel()
        closeWork?.cancel()
        guard expandedOn != nil else { return }
        morph { expandedOn = nil }
        stopClickMonitor()
        tabWhenClosed = tab
        closedAt = ProcessInfo.processInfo.systemUptime
        // Back to Home once it has finished closing, so the closing frames keep what they showed.
        guard !config.openLast else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.expandedOn == nil else { return }
            self.tab = self.homeTab
        }
    }

    /// The tab a plain open shows: Home, or the first one turned on.
    private var homeTab: Tab { config.tabs.contains(.home) ? .home : config.tabs.first ?? .home }

    /// The shelf lives here: as a tab, or because the top shelf is the notch's.
    var shelfAvailable: Bool { config.tabs.contains(.shelf) || Shelf.inNotch }

    /// The Shelf shortcut with the shelf at the top.
    func toggleShelf() {
        if expandedOn != nil, tab == .shelf { close() } else { open(tab: .shelf) }
    }

    /// A drag reached the top edge (the top shelf's trigger): open straight into the Shelf tab and
    /// stay open while the drag goes on — the pointer can't hover during a drag. Once the button
    /// comes up, it closes unless the pointer is on the notch.
    func openForDrag(on display: CGDirectDisplayID) {
        let target = windows[display] != nil ? display : primary
        guard expandedOn != target || tab != .shelf else { return }
        open(on: target, tab: .shelf)
        pointerMoved(NSEvent.mouseLocation)
        guard dragEndMonitor == nil else { return }
        dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            MainActor.assumeIsolated {
                let c = NotchCenter.shared
                if let m = c.dragEndMonitor { NSEvent.removeMonitor(m) }
                c.dragEndMonitor = nil
                if c.hovering.isEmpty { c.scheduleClose(after: 1.5) }
            }
        }
    }

    func toggle(on display: CGDirectDisplayID? = nil) {
        if expandedOn != nil { close() } else { open(on: display) }
    }

    /// From the ring, the launcher or a shortcut.
    func toggleFromAction() {
        guard Self.enabled else {
            MainWindow.show(.notch)
            return
        }
        toggle()
    }

    /// The shortcut's timer, at the length set on the Notch page. Pressed again while running, it stops.
    func startTimerFromAction() {
        let timer = NotchTimer.shared
        if timer.isRunning {
            timer.stop()
            return
        }
        let minutes = max(1, Pref.defaults.double(forKey: NotchPrefs.timerMinutes))
        timer.start(minutes: minutes)
        flash(.init(symbol: "timer", tint: Palette.brand, title: "Timer Started", detail: nil, trailing: NotchTimer.clock(minutes * 60)), for: 1.8)
    }

    private func scheduleClose(after delay: Double) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering.isEmpty, !self.dropTargeted else { return }
            self.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func canOpen(_ display: CGDirectDisplayID) -> Bool {
        guard !NotchHUD.shared.model.expanded, !hiddenFor.contains(display) else { return false }
        // The top shelf grows out of the notch too: it gives way (with the notch on it lives in the
        // Shelf tab anyway, so this only catches one left over from before the setting changed).
        if Shelf.shared.isVisible, Shelf.edge == .top { Shelf.shared.hide() }
        return true
    }

    /// A click anywhere else closes the open notch. Only installed while it's open.
    private func startClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { NotchCenter.shared.close() }
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// Two fingers down on the notch open it; up closes it. One gesture does one thing: after it
    /// opens or closes, the rest of that swipe (and its momentum) is ignored, so a quick back-and-forth
    /// can't queue up morphs.
    func scroll(_ event: NSEvent, on display: CGDirectDisplayID) {
        guard config.swipe, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) || now - swipe.at > 0.4 {
            swipe.amount = 0
            swipeSpent = false
        }
        swipe.at = now
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipe.amount = 0
            swipeSpent = false
            return
        }
        guard !swipeSpent, now - lastMorph > 0.12 else { return }
        // Positive: fingers moving down, whatever the scroll direction setting.
        let finger = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        swipe.amount += finger
        if swipe.amount > 18, expandedOn == nil {
            swipeSpent = true
            open(on: display)
        } else if swipe.amount < -18, expandedOn == display {
            swipeSpent = true
            close()
        }
    }

    // MARK: Drops

    func setDropTargeted(_ on: Bool, on display: CGDirectDisplayID) {
        dropTargeted = on
        if on {
            guard shelfAvailable else { return }
            open(on: display, tab: .shelf)
        } else if hovering.isEmpty {
            scheduleClose(after: 1.5)
        }
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard shelfAvailable else { return false }
        tab = .shelf
        return Shelf.shared.accept(providers)
    }

    // MARK: HUD, notices, banner

    /// The volume / brightness HUD in the notch. False when it belongs at the bottom instead (the
    /// setting, or that screen has no notch from Orbit).
    func showHUD(_ kind: DisplayOSD.Kind, value: Double, caption: String?, on display: CGDirectDisplayID) -> Bool {
        guard Self.enabled, Pref.defaults.string(forKey: NotchPrefs.hudPlace) == "notch" else { return false }
        let target = windows[display] != nil ? display : (NSScreen.screens.count == 1 ? primary : display)
        guard windows[target] != nil, !hiddenFor.contains(target), !NotchHUD.shared.model.expanded else { return false }
        let next = HUD(kind: kind, value: value, caption: caption, display: target)
        if hud == nil { morph { hud = next } } else { withAnimation(.spring(duration: 0.18, bounce: 0)) { hud = next } }
        hudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.morph { self?.hud = nil } }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
        return true
    }

    func flash(_ notice: Peek, for seconds: Double = 2.8) {
        guard Self.enabled, windows[primary] != nil else { return }
        morph { peek = notice }
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.morph { self?.peek = nil } }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The song-change banner grown out of the notch. False when there's no notch to grow it from.
    func showBanner(_ content: WidgetContent) -> Bool {
        guard Self.enabled, windows[primary] != nil, !hiddenFor.contains(primary) else { return false }
        morph { banner = content }
        scheduleBannerEnd(after: 3.6)
        return true
    }

    func refreshBanner(_ content: WidgetContent) {
        guard let banner, banner.generation == content.generation else { return }
        withAnimation(.easeOut(duration: 0.2)) { self.banner = content }
    }

    private func scheduleBannerEnd(after delay: Double) {
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Still under the pointer: wait for it to leave.
            if self.hovering.contains(self.primary) { self.scheduleBannerEnd(after: 1.2); return }
            self.morph { self.banner = nil }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A charging ear for a few seconds.
    func flash(ear: Ear, for seconds: Double = 3) {
        guard Self.enabled, windows[primary] != nil else { return }
        morph { flashEar = ear }
        flashEarWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.morph { self?.flashEar = nil } }
        flashEarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Morphing

    /// Every change of shape goes through here, so it's animated by the one spring and the windows
    /// hear about it (they don't resize; see NotchWindow).
    func morph(_ change: () -> Void) {
        withAnimation(Self.morph, change)
        lastMorph = ProcessInfo.processInfo.systemUptime
        windows.values.forEach { $0.sync() }
    }

    func room(on display: CGDirectDisplayID) -> CGFloat { rooms[display] ?? 64 }

    /// Measures the free menu bar beside each notch: the front app's menus on the left (through
    /// Accessibility) and the status items on the right (MenuBarAgent's slots). Off the main thread;
    /// at most once a second unless forced.
    func measureRooms(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - roomsMeasuredAt > 1 else { return }
        roomsMeasuredAt = now
        let screens: [(CGDirectDisplayID, NotchRoom.Geometry)] = windows.compactMap { id, w in
            w.targetScreen.map { (id, NotchRoom.Geometry(screen: $0)) }
        }
        let own = MenuBarHider.shared.ownFrames
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        roomTask?.cancel()
        roomTask = Task.detached(priority: .utility) {
            var out: [CGDirectDisplayID: CGFloat] = [:]
            for (id, g) in screens { out[id] = NotchRoom.measure(g, frontPID: front, ownFrames: own) }
            await MainActor.run {
                let c = NotchCenter.shared
                guard out != c.rooms else { return }
                c.morph { c.rooms = out }
            }
        }
    }

    // MARK: Full screen

    private func checkFullScreen() {
        guard config.hideFullScreen, !windows.isEmpty else {
            if !hiddenFor.isEmpty { hiddenFor = [] }
            return
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        var full = Set<CGDirectDisplayID>()
        for (id, w) in windows {
            guard let s = w.targetScreen else { continue }
            let cg = CGRect(x: s.frame.minX, y: top - s.frame.maxY, width: s.frame.width, height: s.frame.height)
            let covered = list.contains { info in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                      ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                      let b = info[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: b) else { return false }
                return abs(r.minX - cg.minX) < 1 && abs(r.minY - cg.minY) < 1 && abs(r.width - cg.width) < 1 && abs(r.height - cg.height) < 1
            }
            if covered { full.insert(id) }
        }
        if full != hiddenFor {
            hiddenFor = full
            if let e = expandedOn, full.contains(e) { close() }
        }
    }

    static var morph: Animation {
        #if DEBUG
        if debugSpeed != 1 { return baseMorph.speed(debugSpeed) }
        #endif
        return baseMorph
    }

    private static let baseMorph = Animation.spring(duration: 0.42, bounce: 0.2)

    #if DEBUG
    /// Debug: slows every morph so a burst of window captures can sample it (promo frames).
    nonisolated(unsafe) static var debugSpeed: Double = 1
    var debugEarOn = false
    var debugEar: Ear?
    /// The battery level the charging ear shows in promo frames.
    var debugPercent: Int?
    #endif
}

#if DEBUG
extension NotchCenter {
    /// Debug: puts the primary notch into one state for promo frames — "closed", "ears-music",
    /// "expanded-home", "expanded-shelf", "charging" (the ear) or "reset" — morphing at `speed`. Returns its window number.
    func debugState(_ state: String, speed: Double, percent: Int) -> Int? {
        Self.debugSpeed = speed
        peekWork?.cancel()
        switch state {
        case "closed":
            close()
            morph { debugEarOn = true; debugEar = nil; peek = nil; flashEar = nil }
        case "ears-music":
            close()
            morph { debugEarOn = true; debugEar = .music; peek = nil; flashEar = nil }
        case "open", "open-hover":
            debugEarOn = true
            open(on: primary, byHover: state == "open-hover")
            stopClickMonitor()
        case "expanded-home", "expanded-shelf":
            debugEarOn = true
            open(on: primary, tab: state == "expanded-shelf" ? .shelf : .home)
            stopClickMonitor() // a real click elsewhere mustn't close it mid-capture
        case "charging":
            close()
            morph {
                debugEarOn = true
                debugEar = .charging(true)
                debugPercent = percent
                peek = nil
            }
        default:
            Self.debugSpeed = 1
            close()
            debugEarOn = false
            debugEar = nil
            peek = nil
        }
        return windows[primary]?.windowNumber
    }

    /// Debug: each notch window's state, for checking clicks go through where there's no shape.
    func debugInfo() -> [[String: Any]] {
        windows.map { id, w in
            let r = w.hitRect()
            return ["display": id, "phase": String(describing: phase(on: id)), "ignoresMouseEvents": w.ignoresMouseEvents,
                    "window": NSStringFromRect(w.frame), "hitRect": r.map(NSStringFromRect) ?? "none",
                    "pointer": NSStringFromPoint(NSEvent.mouseLocation), "hovering": hovering.contains(id), "tab": tab.rawValue]
        }
    }
}
#endif

extension NSScreen {
    /// A MacBook screen with the camera notch.
    var hasCameraHousing: Bool { safeAreaInsets.top > 0 && auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil }

    /// The notch's size, or a drawn one for screens without a camera housing.
    var notchSize: CGSize {
        if hasCameraHousing, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea {
            // Down to the menu bar's bottom, which can sit a point below the camera housing.
            let bar = frame.maxY - visibleFrame.maxY
            return CGSize(width: frame.width - l.width - r.width, height: max(safeAreaInsets.top, bar < 40 ? bar : 0))
        }
        let bar = frame.maxY - visibleFrame.maxY
        return CGSize(width: 180, height: bar > 10 ? min(bar, 32) : 24)
    }

    /// The notch's horizontal center (the camera housing isn't always dead center).
    var notchMidX: CGFloat {
        if hasCameraHousing, let l = auxiliaryTopLeftArea { return frame.minX + l.width + notchSize.width / 2 }
        return frame.midX
    }
}
