import AppKit
import ScreenCaptureKit

extension Pref {
    /// Paint over macOS's own « overflow button (clicking the spot opens Orbit's bar instead).
    static let hideSystemOverflow = "menubar.hideSystemOverflow"
}

/// macOS 26 shows a « button whenever menu bar icons don't fit, and there's no setting to turn it
/// off. Orbit covers it with a patch of whatever is behind the menu bar there — the wallpaper, or the
/// bar's own color — and turns a click on that spot into Orbit's bar of hidden icons.
@MainActor
final class OverflowCover {
    static let shared = OverflowCover()

    /// One patch per Space. macOS draws a separate menu bar for every Space (a "Menubar" window that
    /// belongs to that Space alone), and a Space switch slides the bars along with everything else.
    /// A single patch on all Spaces stayed put while the bars slid under it — that's what gave it
    /// away. Each Space's patch belongs to that Space, slides in and out with its bar, and keeps that
    /// Space's own wallpaper.
    private final class Cover {
        let panel: NSPanel
        let image: NSImageView
        var strip: Strip?
        var seeThrough = true
        init(panel: NSPanel, image: NSImageView) { self.panel = panel; self.image = image }
    }
    private var covers: [Cover] = []
    /// The newest picture from any Space, for a Space's first patch until its own is taken.
    private var lastStrip: Strip?
    private var current: Cover? { covers.first { $0.panel.isOnActiveSpace } }
    private var panel: NSPanel? { current?.panel }
    private var timer: Timer?
    private var covered: CGRect?
    private var spaceObserver: Any?
    private var axObserver: AXObserver?

    /// The whole bar photographed twice — the desktop-level windows on their own, and everything as
    /// shown — so any patch is just a crop of it: the cover lands the moment « shows up, instead of
    /// after a round of screenshots.
    private struct Strip {
        let desktop: CGImage
        let real: CGImage?
        let scale: CGFloat
        let height: CGFloat
        /// The picture starts here (« never sits left of the notch, so the left half isn't taken).
        var originX: CGFloat = 0
        let at: Date
    }
    private var strip: Strip? { current?.strip ?? lastStrip }
    private var capturing = false
    private var failedAt = Date.distantPast
    /// The bar shows the desktop through it (vs. a solid color): its picture goes stale quickly.
    private var seeThrough: Bool { current?.seeThrough ?? true }
    /// Polls fast for a moment after anything moves.
    private var burstUntil = Date.distantPast
    private var lastTick = Date.distantPast

    var enabled: Bool {
        // Switched-off icons never reach «, but a bar too full of visible ones still brings it out.
        Pref.defaults.bool(forKey: Pref.hiderEnabled)
            && (Pref.defaults.object(forKey: Pref.hideSystemOverflow) as? Bool ?? true)
    }

    func apply() {
        guard enabled else {
            timer?.invalidate()
            timer = nil
            hide()
            return
        }
        if timer == nil {
            // A cheap check (one Accessibility read of the bar, ~0.4ms, plus the window list, ~0.7ms):
            // every two seconds as a backstop; the bar's own Accessibility notifications do the noticing,
            // and every frame while things are moving comes from `burst`.
            let t = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let me = OverflowCover.shared
                    // Hiding by switching icons off, « only comes with a bar full of visible icons —
                    // an app arriving, which the bar announces. While nothing's covered, the backstop
                    // can be slow.
                    let backstop: TimeInterval = MenuBarRemoval.shared.active && !me.visible ? 10 : 1.8
                    if Date().timeIntervalSince(me.lastTick) >= backstop { me.tick(.poll) }
                }
            }
            t.tolerance = 0.4
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { OverflowCover.shared.spaceChanged() }
            }
        }
        observeBar()
        tick(.poll)
    }

    /// Icons may have moved (folding, unfolding): follow the « quickly. While Orbit is ⌘-dragging
    /// icons the patch steps away completely so it can't catch the drag.
    func refreshSoon() {
        guard enabled else { return }
        if MenuBarItems.shared.busy { hide() }
        burst()
        tick(.orbit)
    }

    /// Orbit just changed the strip's length by `delta`. Its right end stays put, so it grows
    /// leftwards and « moves with its left edge: the cover goes there now, in the same turn of the
    /// run loop — spanning the old spot as well until the bar has really moved — rather than after
    /// the bar has redrawn and the « has been seen peeking.
    func stripChanged(by delta: CGFloat, folded: Bool) {
        guard enabled else { return }
        burst()
        // Predicted from where « really is (`seen`), never from an earlier prediction — those used
        // to pile up into a patch hundreds of points wide that hid real icons. Big jumps aren't
        // predicted at all: the bar is being rearranged, not nudged.
        guard folded, delta != 0, abs(delta) <= 120, let c = seen, visible,
              !MenuBarItems.shared.busy, !MenuBarItems.shared.holdingOverflow else { tick(.orbit); return }
        let predicted = c.offsetBy(dx: -delta, dy: 0)
        expected = predicted
        place(c.union(predicted), source: .predicted)
    }

    /// Called by the move code before it starts dragging.
    func stepAside() { hide() }

    enum Source: String { case poll, ax, orbit, predicted, space, picture }

    /// Where Orbit expects « after its own change; cleared once the bar has caught up.
    private var expected: CGRect?
    /// Where « (plus the gap up to the strip) really was at the last look — no predictions mixed in.
    private var seen: CGRect?

    private var fastTimer: Timer?

    /// Every frame for a moment, then back to the backstop.
    private func burst(_ seconds: TimeInterval = 1.5) {
        burstUntil = max(burstUntil, Date().addingTimeInterval(seconds))
        guard fastTimer == nil, timer != nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            MainActor.assumeIsolated {
                let me = OverflowCover.shared
                guard Date() < me.burstUntil, me.timer != nil else { t.invalidate(); me.fastTimer = nil; return }
                me.tick(.poll)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    /// Each Space has its own patch, already in place and slid in with its bar; a Space seen for
    /// the first time gets one at once (with the last picture until its own is taken).
    private func spaceChanged() {
        Self.shareable = nil
        burst()
        MenuBarLog.write("cover: space changed")
        tick(.space)
    }

    /// The picture is from before a Space change or Mission Control: retake it, keep using it.
    private var stale = false

    private func tick(_ source: Source) {
        let sinceLast = Date().timeIntervalSince(lastTick)
        lastTick = Date()
        let state = Self.screenState()
        // Never in the way while Orbit itself is unfolding or ⌘-dragging icons: the patch would sit
        // right where the drag lands and swallow it. Mission Control and full-screen apps take the
        // bar away; so must the patch.
        guard enabled, !MenuBarItems.shared.busy, !MenuBarItems.shared.holdingOverflow,
              state.menuBar, !state.missionControl else {
            if state.missionControl, visible { MenuBarLog.write("cover: mission control, hidden") }
            if state.missionControl { stale = true }
            hide()
            return
        }
        guard let chevron = MenuBarItems.overflowButtonFrame() else {
            // A single missed look (Accessibility timing out while the bar redraws) used to take
            // the patch away for a frame — the flicker. « has to be gone for a moment first.
            if visible, Date().timeIntervalSince(lastSeenChevron) < 0.3 { return }
            hide()
            return
        }
        lastSeenChevron = Date()
        // « itself moved: follow it every frame for a moment. Notifications that changed nothing
        // (an icon redrawing its image, like the runner's) don't start that.
        if let last = lastChevron, last != chevron { burst(0.5) }
        lastChevron = chevron
        let real = Self.coverRect(chevron)
        seen = real
        var f = real
        // Orbit's own change hasn't reached the bar yet: keep covering both spots, briefly.
        if let e = expected {
            if abs(e.minX - real.minX) < 1 || Date() >= burstUntil || abs(e.minX - real.minX) > 120 { expected = nil } else { f = real.union(e) }
        }
        // AppKit sometimes shoves the patch aside when status items change length; put it back.
        let shoved = visible && (panel.map { p in covered.map { abs(p.frame.minX - $0.minX) > 3.5 || p.frame.maxX < $0.maxX } == true } ?? false)
        let moved = covered.map { abs($0.minX - f.minX) > 0.5 || abs($0.width - f.width) > 0.5 } ?? true
        // A Space visited for the first time has no patch of its own yet.
        let missing = current.map { $0.panel.alphaValue < 1 } ?? true
        if moved || shoved || !visible || missing {
            if moved, let c = covered {
                MenuBarLog.write("cover: « \(Int(c.minX))…\(Int(c.maxX)) → \(Int(f.minX))…\(Int(f.maxX)) seen via \(source.rawValue), \(Int(sinceLast * 1000))ms after the previous look")
            }
            if moved { burst() }
            place(f, source: source)
        }
        let age = strip.map { Date().timeIntervalSince($0.at) } ?? .infinity
        if stale || current?.strip == nil || age > (seeThrough && visible ? 4 : 30) || (strip.map { f.maxY + 1 > $0.height } ?? true) {
            Task { await refreshStrip() }
        }
    }

    /// Puts the patch over `f` from the cached picture of the bar, at once. The panel stays ordered
    /// in all along; only its frame, picture and alpha change, with no animation.
    private func place(_ f: CGRect, source: Source = .poll) {
        let started = Date()
        // While things move, a couple of points to spare on each side so no edge of « shows.
        let margin: CGFloat = Date() < burstUntil ? 3 : 1
        let area = CGRect(x: f.minX - margin, y: f.minY - 1, width: f.width + 2 * margin, height: f.height + 2)
        guard let strip, let screen = NSScreen.screens.first, let patch = patch(for: area, from: strip) else {
            // Nothing good to show yet: better « for a moment than a black box.
            if covered != f { hide() }
            Task { await refreshStrip() }
            return
        }
        let rect = NSRect(x: area.minX, y: screen.frame.maxY - area.maxY, width: area.width, height: area.height)
        let here = current ?? makeCover()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        show(here, patch, at: rect)
        // The other Spaces' patches follow too (their bars have the same icons), each with its own
        // Space's wallpaper, so a switch slides in a patch that's already in place.
        for other in covers where other !== here {
            if let own = other.strip, let p = self.patch(for: area, from: own) { show(other, p, at: rect) } else { other.panel.alphaValue = 0 }
        }
        CATransaction.commit()
        here.panel.displayIfNeeded()
        covered = f
        visible = true
        let ms = Date().timeIntervalSince(started) * 1000
        if ms > 4 || source == .predicted { MenuBarLog.write("cover: placed via \(source.rawValue) in \(String(format: "%.1f", ms))ms") }
    }

    private var visible = false
    private var lastSeenChevron = Date.distantPast
    private var lastChevron: CGRect?

    private func show(_ cover: Cover, _ patch: NSImage, at rect: NSRect) {
        let p = cover.panel
        cover.image.image = patch
        if p.frame != rect { p.setFrame(rect, display: true) }
        p.alphaValue = 1
        p.ignoresMouseEvents = false
        if !p.isVisible { p.orderFrontRegardless() }
    }

    /// « and whatever sits between it and the folded strip: an icon that widened (a badge, a
    /// longer title) can end up there, peeking out where the strip can't grow to cover it.
    private static func coverRect(_ chevron: CGRect) -> CGRect {
        let hider = MenuBarHider.shared
        guard hider.collapsed, !hider.revealing, let window = hider.dividerWindow, MenuBarHider.inView(window) else { return chevron }
        // The strip's own window frame is in the same left-to-right coordinates as «'s.
        var left = window.frame.minX
        guard left > chevron.maxX + 1, left - chevron.maxX < 160 else { return chevron }
        // Never over macOS's mic/camera indicator: it must stay in sight.
        if let privacy = privacyFrame(), privacy.minX >= chevron.maxX - 1, privacy.minX < left { left = privacy.minX }
        return CGRect(x: chevron.minX, y: chevron.minY, width: max(chevron.width, left - chevron.minX), height: chevron.height)
    }

    private static var privacyCache: (at: Date, frame: CGRect?) = (.distantPast, nil)

    /// Where macOS's mic/camera-in-use indicator is, looked up at most twice a second.
    private static func privacyFrame() -> CGRect? {
        if Date().timeIntervalSince(privacyCache.at) < 0.5 { return privacyCache.frame }
        privacyCache = (Date(), MenuBarHosted.read().slots.first { $0.identifier == MenuBarItems.privacyIndicator }?.frame)
        return privacyCache.frame
    }

    /// Out of sight but still ordered in, so coming back is a matter of alpha, not window ordering.
    private func hide() {
        if visible {
            for c in covers {
                c.panel.alphaValue = 0
                c.panel.ignoresMouseEvents = true
            }
        }
        visible = false
        covered = nil
        expected = nil
        seen = nil
    }

    // MARK: The picture of the bar

    private func refreshStrip() async {
        // A failed look (mid-transition) isn't retried for a moment.
        guard !capturing, Date().timeIntervalSince(failedAt) > 0.5, let screen = NSScreen.screens.first else { return }
        capturing = true
        defer { capturing = false }
        let started = Date()
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
           agent.processIdentifier != agentPID, let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
            axObserver = nil
            observeBar()
        }
        guard let fresh = await Self.captureStrip(screen) else { failedAt = Date(); return }
        // Mission Control or a Space swipe began while we looked: that picture can't be trusted.
        let state = Self.screenState()
        guard state.menuBar, !state.missionControl else { failedAt = Date(); return }
        // The picture is of the Space showing now; it belongs to that Space's patch.
        lastStrip = fresh
        stale = false
        let here = current ?? makeCover()
        here.strip = fresh
        if let c = covered ?? MenuBarItems.overflowButtonFrame().map(Self.coverRect) {
            here.seeThrough = Self.gapMatches(c, in: fresh) ?? true
            if enabled, !MenuBarItems.shared.busy, !MenuBarItems.shared.holdingOverflow, state.menuBar, visible || covered == nil {
                place(c, source: .picture)
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ms > 250 { MenuBarLog.write("cover: bar picture took \(ms)ms") }
    }

    private static func captureStrip(_ screen: NSScreen) async -> Strip? {
        // Listing every window on screen is most of a picture's cost; the display and the desktop's
        // windows stay the same until the Space changes.
        let display: SCDisplay, desktopWindows: [SCWindow], orbit: [SCRunningApplication]
        if let cached = shareable, Date().timeIntervalSince(cached.at) < 30 {
            (display, desktopWindows, orbit) = (cached.display, cached.desktop, cached.orbit)
        } else {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return nil }
            display = d
            desktopWindows = content.windows.filter { $0.windowLayer < 0 && $0.isOnScreen }
            orbit = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            shareable = (d, desktopWindows, orbit, Date())
        }
        guard !desktopWindows.isEmpty else { MenuBarLog.write("cover: no desktop windows, skipped"); shareable = nil; return nil }
        let scale = screen.backingScaleFactor
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness) + 4
        let originX = max(0, (screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX) - screen.frame.minX - 40).rounded(.down)
        let rect = CGRect(x: originX, y: 0, width: screen.frame.width - originX, height: height)
        async let desktop = shot(SCContentFilter(display: display, including: desktopWindows), rect: rect, scale: scale)
        // The bar as shown, without Orbit's own windows: the notch's music ear sits right where the
        // bar's color is read beside «, and its album tint came back as a dark red patch.
        async let real = shot(SCContentFilter(display: display, excludingApplications: orbit, exceptingWindows: []), rect: rect, scale: scale)
        guard let d = await desktop else { return nil }
        // Caught mid-transition, the desktop can come back empty — a see-through, black picture.
        guard let avg = average(d), avg.3 > 0.9 else {
            MenuBarLog.write("cover: empty bar picture discarded")
            shareable = nil
            return nil
        }
        return Strip(desktop: d, real: await real, scale: scale, height: height, originX: originX, at: Date())
    }

    /// The desktop behind `rect`, or — over a solid bar — the bar's own color.
    private func patch(for rect: CGRect, from strip: Strip) -> NSImage? {
        let f = rect
        let size = NSSize(width: rect.width, height: rect.height)
        if Self.gapMatches(f, in: strip) == false, let real = strip.real, let gap = Self.gapRect(f),
           let cut = Self.crop(real, gap, scale: strip.scale, originX: strip.originX), let c = Self.average(cut), c.3 > 0.9 {
            return Self.solid((c.0, c.1, c.2), size: size)
        }
        guard let cut = Self.crop(strip.desktop, rect, scale: strip.scale, originX: strip.originX), let a = Self.average(cut), a.3 > 0.9 else { return nil }
        // The desktop picture can come back dark (a wallpaper still loading, a Space mid-switch)
        // while the bar beside « is plainly light: that was the black box. The bar's own color is
        // always a safe patch.
        if let real = strip.real, let gap = Self.gapRect(f), let g = Self.crop(real, gap, scale: strip.scale, originX: strip.originX),
           let c = Self.average(g), c.3 > 0.9, Self.distance((a.0, a.1, a.2), (c.0, c.1, c.2)) > 0.3 {
            return Self.solid((c.0, c.1, c.2), size: size)
        }
        return NSImage(cgImage: cut, size: size)
    }

    /// An icon-free stretch just left of «, between it and the notch.
    private static func gapRect(_ f: CGRect) -> CGRect? {
        guard let screen = NSScreen.screens.first else { return nil }
        let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        let gap = CGRect(x: max(notchRight + 2, f.minX - 14), y: f.minY + 2, width: 10, height: max(4, f.height - 4))
        return gap.minX < f.minX - 4 ? gap : nil
    }

    /// Does the bar next to « look like the bare desktop (see-through), or not (solid)? nil if it
    /// can't tell.
    private static func gapMatches(_ f: CGRect, in strip: Strip) -> Bool? {
        guard let gap = gapRect(f), let real = strip.real,
              let r = crop(real, gap, scale: strip.scale, originX: strip.originX), let d = crop(strip.desktop, gap, scale: strip.scale, originX: strip.originX),
              let a = average(r), let b = average(d) else { return nil }
        return distance((a.0, a.1, a.2), (b.0, b.1, b.2)) < 0.05
    }

    nonisolated(unsafe) private static var shareable: (display: SCDisplay, desktop: [SCWindow], orbit: [SCRunningApplication], at: Date)?

    private static func crop(_ image: CGImage, _ rect: CGRect, scale: CGFloat, originX: CGFloat = 0) -> CGImage? {
        let px = CGRect(x: (rect.minX - originX) * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard px.minX >= 0, px.minY >= 0, px.maxX <= CGFloat(image.width), px.maxY <= CGFloat(image.height) else { return nil }
        return image.cropping(to: px)
    }

    // MARK: Watching the bar

    /// MenuBarAgent's bar tells Accessibility when its slots move; if it does, the cover reacts at
    /// once instead of on the next poll.
    private func observeBar() {
        guard axObserver == nil, AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
        var observer: AXObserver?
        // Measured: MenuBarAgent posts AXLayoutChanged / AXMoved / AXUIElementDestroyed within a few
        // ms of its slots moving (AXValueChanged fires every second for the clock, so it's left out).
        // They come in floods of ten; one look per run-loop turn is enough.
        let callback: AXObserverCallback = { _, element, name, _ in
            let notification = name as String
            // The observer also hears other apps' windows changing; only the bar's own count.
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            MainActor.assumeIsolated {
                guard pid == OverflowCover.shared.agentPID else { return }
                OverflowCover.shared.barNotified(notification)
            }
        }
        guard AXObserverCreate(agent.processIdentifier, callback, &observer) == .success, let observer else { return }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        var added = 0
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXMovedNotification,
                     kAXResizedNotification, kAXLayoutChangedNotification] {
            if AXObserverAddNotification(observer, root, name as CFString, nil) == .success { added += 1 }
        }
        // MenuBarAgent restarts now and then; watch for a new one.
        agentPID = agent.processIdentifier
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        MenuBarLog.write("cover: watching the bar (\(added) notifications)")
    }

    private var agentPID: pid_t = 0
    private var notified = false

    /// Counts the bar's layout notifications, so others can skip a look when nothing moved.
    private(set) var barChanges = 0

    private func barNotified(_ name: String) {
        barChanges &+= 1
        // With icons switched off rather than pushed away, « can only appear when an icon arrives or
        // grows; icons moving or redrawing (the runner, every frame) don't need a look while nothing's covered.
        if MenuBarRemoval.shared.active, !visible,
           name == kAXMovedNotification || name == kAXLayoutChangedNotification { return }
        // One look per flood, at most about three a second (the trailing one always comes); only a real change
        // of « starts a burst (see tick).
        guard !notified else { return }
        notified = true
        let wait = Date() < burstUntil ? 0 : max(0, 0.3 - Date().timeIntervalSince(lastTick))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MainActor.assumeIsolated {
                OverflowCover.shared.notified = false
                OverflowCover.shared.tick(.ax)
            }
        }
    }

    /// One look at the window list: is the menu bar there, and is Mission Control up?
    private static func screenState() -> (menuBar: Bool, missionControl: Bool) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
              let screen = NSScreen.screens.first else { return (true, false) }
        var menuBar = false, mission = false
        for w in list {
            let name = w[kCGWindowName as String] as? String
            let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            if name == "Menubar", bounds["Y"] == 0 { menuBar = true }
            // Mission Control is drawn by the Dock in screen-sized windows above the desktop; the
            // Dock's own window (named "Dock") is always there and doesn't count.
            if (w[kCGWindowOwnerName as String] as? String) == "Dock", name != "Dock",
               let layer = w[kCGWindowLayer as String] as? Int, layer >= 0,
               (bounds["Width"] ?? 0) >= screen.frame.width * 0.9, (bounds["Height"] ?? 0) >= screen.frame.height * 0.5 {
                mission = true
            }
        }
        return (menuBar, mission)
    }

    private static func shot(_ filter: SCContentFilter, rect: CGRect, scale: CGFloat) async -> CGImage? {
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Mean color and coverage.
    private static func average(_ image: CGImage) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let a = CGFloat(px[3]) / 255
        guard a > 0 else { return (0, 0, 0, 0) }
        return (CGFloat(px[0]) / 255 / a, CGFloat(px[1]) / 255 / a, CGFloat(px[2]) / 255 / a, a)
    }

    private static func distance(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
        max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
    }

    private static func solid(_ c: (CGFloat, CGFloat, CGFloat), size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { r in
            NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1).setFill()
            r.fill()
            return true
        }
    }

    /// A patch for the Space showing now: ordered in right away (invisible) so it joins this Space.
    private func makeCover() -> Cover {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        // Bound to one Space (no canJoinAllSpaces), like the bar it covers. Transient, not
        // stationary: stationary windows stay put in Mission Control, where the bar is gone.
        p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.animationBehavior = .none
        let view = ClickView()
        let image = NSImageView()
        image.imageScaling = .scaleAxesIndependently
        image.autoresizingMask = [.width, .height]
        view.addSubview(image)
        p.contentView = view
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        let cover = Cover(panel: p, image: image)
        // Spaces come and go; keep the patches of the most recent dozen.
        if covers.count >= 12, let old = covers.firstIndex(where: { !$0.panel.isOnActiveSpace }) {
            covers[old].panel.orderOut(nil)
            covers.remove(at: old)
        }
        covers.append(cover)
        MenuBarLog.write("cover: new patch for this Space (\(covers.count) in all)")
        return cover
    }

    /// A click where « was opens Orbit's bar of hidden (and tucked-away) icons.
    private final class ClickView: NSView {
        override func layout() {
            super.layout()
            subviews.forEach { $0.frame = bounds }
        }

        override func mouseDown(with event: NSEvent) {
            MainActor.assumeIsolated {
                let anchor = window?.frame ?? .zero
                HiddenBar.shared.isVisible ? HiddenBar.shared.hide() : HiddenBar.shared.show(below: anchor)
            }
        }
    }
}
