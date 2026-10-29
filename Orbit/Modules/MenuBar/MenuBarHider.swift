import AppKit

/// Tucks menu bar icons away, Barbee-style. From left to right Orbit owns:
///   [always hidden] ⋮ always-divider  [hidden] | divider  [visible] … ‹ arrow
/// A divider "hides" whatever sits left of it by growing wide enough to push it off-screen.
/// The main divider grows while collapsed; the always-divider stays grown unless Orbit reveals
/// everything for a moment (to open one item, take pictures of the icons, or move one).
@MainActor @Observable
final class MenuBarHider: NSObject {
    static let shared = MenuBarHider()

    private(set) var collapsed = false
    /// Everything unfolded for a moment, without the auto-hide timer.
    private(set) var revealing = false

    @ObservationIgnored private var toggle: NSStatusItem?
    @ObservationIgnored private var divider: NSStatusItem?
    @ObservationIgnored private var always: NSStatusItem?
    @ObservationIgnored private var collapseTimer: Timer?

    private static let hiddenLength: CGFloat = 10_000

    func apply() {
        #if DEBUG
        DebugOnce.install
        #endif
        // ✦ and ✦✦ are one pair now.
        if Pref.defaults.string(forKey: Pref.hiderIcon) == "sparkles" { Pref.defaults.set("sparkle", forKey: Pref.hiderIcon) }
        if Pref.defaults.bool(forKey: Pref.hiderEnabled) {
            MenuBarNewItems.shared.start()
            guard toggle == nil else { return }
            let t = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            t.autosaveName = "OrbitHiderToggle"
            toggle = t
            if MenuBarRemoval.shared.active {
                // Hidden icons are switched off, not pushed away: just the button, no divider.
                configureRoles()
                updateToggleImage()
                OverflowCover.shared.apply()
                Task { @MainActor in
                    await MenuBarRemoval.shared.reconcile()
                    await MenuBarItems.shared.refresh(reveal: false)
                }
                return
            }
            let d = NSStatusBar.system.statusItem(withLength: 12)
            d.autosaveName = "OrbitHiderDivider"
            divider = d
            configureRoles()
            if Pref.defaults.bool(forKey: Pref.hiderAlways) { addAlwaysDivider() }
            setCollapsed(false)
            // macOS decides where new items land; settle which one is which once they're laid out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MenuBarHider.shared.settleOrder()
                // macOS 27 forgets where the dividers were; put the user's arrangement back first.
                Task { @MainActor in
                    await MenuBarItems.shared.restoreArrangement()
                    MenuBarHider.shared.foldForBar()
                }
            }
            OverflowCover.shared.apply()
        } else {
            MenuBarNewItems.shared.stop()
            Task { await MenuBarRemoval.shared.restoreAll() }
            OverflowCover.shared.apply()
            HiddenBar.shared.hide()
            revealing = false
            setCollapsed(false)
            [toggle, divider, always].compactMap { $0 }.forEach { NSStatusBar.system.removeStatusItem($0) }
            toggle = nil
            divider = nil
            always = nil
        }
    }

    /// Starts over with the other way of hiding (Full Disk Access just came or went).
    func rebuild() {
        guard toggle != nil else { return }
        HiddenBar.shared.hide()
        revealing = false
        collapsed = false
        [toggle, divider, always].compactMap { $0 }.forEach { NSStatusBar.system.removeStatusItem($0) }
        toggle = nil
        divider = nil
        always = nil
        apply()
    }

    /// The "always hidden" section only exists once something is put there.
    private func addAlwaysDivider() {
        guard always == nil, toggle != nil else { return }
        let a = NSStatusBar.system.statusItem(withLength: 12)
        a.autosaveName = "OrbitHiderAlways"
        always = a
        configureRoles()
        applyLengths()
    }

    var hasAlwaysSection: Bool { always != nil }

    /// "Below" style keeps hidden icons folded away for good — they live in the bar under the menu
    /// bar — so the menu bar never overflows into macOS's own « button.
    var barStyle: Bool { (Pref.defaults.string(forKey: Pref.hiderStyle) ?? "bar") == "bar" }

    func foldForBar() {
        guard toggle != nil, barStyle, !collapsed else { return }
        setCollapsed(true, quietly: true)
    }

    private func configureRoles() {
        if let b = toggle?.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.appearsDisabled = false
        }
        for (item, image) in [(divider, Self.dividerImage), (always, Self.alwaysImage)] {
            guard let b = item?.button else { continue }
            b.target = nil
            b.action = nil
            b.image = image
            b.appearsDisabled = true
        }
        // Folded, the divider is the strip between the notch and the visible icons. It carries the
        // button's icon at its right end and works like it, so there's always something to click —
        // on a full menu bar macOS may tuck the real button behind its « along with the hidden icons.
        if let b = divider?.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imageScaling = .scaleNone
            // No grey capsule across the whole strip when it's clicked.
            (b.cell as? NSButtonCell)?.highlightsBy = []
        }
    }

    /// Is this status item window really in view (not tucked behind macOS's « button)?
    static func inView(_ window: NSWindow?) -> Bool {
        guard let f = window?.frame, NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }) else { return false }
        // Tucked items report positions stacked around the « button; real ones sit right of it.
        if let overflow = MenuBarItems.overflowButtonFrame(), f.minX < overflow.maxX - 1 { return false }
        return true
    }

    var toggleInView: Bool { Self.inView(toggle?.button?.window) }
    /// The real button is drawn in the menu bar (not tucked behind «, with the strip standing in).
    var toggleVisible: Bool { toggleInView }

    /// The folded length before ``makeRoom(_:)`` took some off.
    @ObservationIgnored private var roomSaved: CGFloat?

    /// Shortens the folded strip by `width` for a moment, so one hidden item can be brought out next
    /// to the visible icons without anything else unfolding.
    func makeRoom(_ width: CGFloat) {
        guard collapsed, !revealing, let length = foldedLength, roomSaved == nil else { return }
        roomSaved = length
        let shorter = max(24, length - width)
        foldedLength = shorter
        setDividerLength(shorter)
        divider?.button?.image = foldedImage(length: shorter)
        MenuBarLog.write("fold: making room \(Int(width))pt (\(Int(length)) → \(Int(shorter)))")
    }

    /// Puts the strip back after ``makeRoom(_:)`` and checks it still fits.
    func endRoom() {
        guard let saved = roomSaved else { return }
        roomSaved = nil
        guard collapsed, !revealing else { return }
        foldedLength = saved
        setDividerLength(saved)
        divider?.button?.image = foldedImage(length: saved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MenuBarHider.shared.checkFold() }
    }

    /// The button moved: the visible icons now start somewhere else, so the fold is measured afresh
    /// on the next fold. Call while revealing (the divider is short then, so its edge can be read).
    func refitFold() {
        foldedLength = nil
        dividerRightEdge = nil
        learnRightEdge()
    }

    /// The folded divider's picture: empty, with the button icon at the right end when the real
    /// button isn't in view.
    private func foldedImage(length: CGFloat) -> NSImage? {
        guard !toggleInView else { return nil }
        let icon = Pref.defaults.string(forKey: Pref.hiderIcon) ?? "sparkle"
        guard let symbol = Self.image(for: icon, collapsed: !showingHidden, label: "Show hidden menu bar items".loc) else { return nil }
        let size = NSSize(width: max(length, symbol.size.width + 8), height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: size.width - symbol.size.width - 6, y: (size.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Show hidden menu bar items".loc
        return image
    }

    /// The left one of the arrow and divider has to be the divider, or collapsing would hide the arrow.
    /// macOS (26) remembers positions itself and may put them either way round, so swap roles if needed.
    private func settleOrder() {
        // Tucked-away items report made-up positions; only compare two that are really in view.
        guard !collapsed, Self.inView(divider?.button?.window), Self.inView(toggle?.button?.window),
              let dx = divider?.button?.window?.frame.minX, let tx = toggle?.button?.window?.frame.minX, dx > tx,
              let t = toggle, let d = divider else { return }
        toggle = d
        divider = t
        t.length = 12
        d.length = NSStatusItem.squareLength
        configureRoles()
        setCollapsed(false)
    }

    /// Right-click on ✦: Orbit's own menu, since the planet is off unless the user wants it.
    static func showOrbitMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title.loc, action: #selector(MenuAction.run(_:)), keyEquivalent: key)
            let target = MenuAction(run)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        add("Open Orbit") { MainWindow.show() }
        add("Menu Bar Settings…") { MainWindow.show(.menubar) }
        menu.addItem(.separator())
        add("Open Orbit Ring") { OrbitRing.shared.open(hold: false) }
        add("Open Launcher") { LauncherPanel.shared.show() }
        menu.addItem(.separator())
        add("Quit Orbit", "q") { AppQuit.now() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private final class MenuAction: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run(_ sender: Any?) { action() }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        // macOS 26 paints a grey capsule behind a clicked item; across the wide folded strip it looks
        // like a broken button. Orbit shows its own state with the ✦/✦✦ pair instead.
        for delay in [0.0, 0.05, 0.2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sender.highlight(false) } }
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            Self.showOrbitMenu(from: sender)
            return
        }
        if HiddenBar.shared.isVisible { HiddenBar.shared.hide(); return }
        if collapsed || MenuBarRemoval.shared.active { showHidden() } else { setCollapsed(true) }
    }

    // MARK: The folded strip's lid

    /// The folded divider is a status item, and macOS lights the whole of a clicked item with a grey
    /// capsule. A nearly invisible lid over the strip takes the clicks instead: the empty stretch does
    /// nothing, the ✦ at its right end works like the button.
    private var lid: NSPanel?

    func placeLid() {
        let wanted = collapsed && !revealing && foldedLength != nil && !MenuBarItems.shared.busy
            && Self.inView(divider?.button?.window)
        guard wanted, let d = divider?.button?.window?.frame else { lid?.orderOut(nil); return }
        let p = lid ?? makeLid()
        if p.frame != d { p.setFrame(d, display: false) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func makeLid() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary] // out of Mission Control
        p.isOpaque = false
        // Fully clear windows let clicks fall through; this is as good as invisible.
        p.backgroundColor = NSColor.black.withAlphaComponent(0.002)
        p.hasShadow = false
        p.animationBehavior = .none
        p.contentView = LidView()
        lid = p
        return p
    }

    private final class LidView: NSView {
        override func mouseDown(with event: NSEvent) {
            // Only the ✦ at the right end responds (and only when the strip is the one drawing it).
            guard convert(event.locationInWindow, from: nil).x >= bounds.width - 32 else { return }
            MainActor.assumeIsolated {
                guard !MenuBarHider.shared.toggleInView else { return }
                let hider = MenuBarHider.shared
                if event.modifierFlags.contains(.option) { MainWindow.show(.menubar); return }
                if HiddenBar.shared.isVisible { HiddenBar.shared.hide() } else { hider.showHidden() }
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard convert(event.locationInWindow, from: nil).x >= bounds.width - 32,
                  MainActor.assumeIsolated({ !MenuBarHider.shared.toggleInView }) else { return }
            MainActor.assumeIsolated { if let b = MenuBarHider.shared.toggleButton { MenuBarHider.showOrbitMenu(from: b) } }
        }
    }

    /// The one way to show hidden icons (the button, "Show now", the Ring): in the bar under the menu
    /// bar, or unfolded in place — falling back to the bar when the notch leaves no room for them.
    func showHidden() {
        guard toggle != nil else { return }
        if barStyle || MenuBarRemoval.shared.active, AXIsProcessTrusted() {
            HiddenBar.shared.show(below: buttonFrame)
            return
        }
        setCollapsed(false)
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let hider = MenuBarHider.shared
            guard !hider.collapsed, MenuBarItems.shared.hasSnapshot, !MenuBarItems.shared.hiddenFitOnScreen() else { return }
            hider.setCollapsed(true, quietly: true)
            HiddenBar.shared.show(below: hider.buttonFrame)
            Toast.show("No room next to the notch", symbol: "menubar.rectangle", detail: "Showing hidden icons below the menu bar instead")
        }
    }

    // MARK: Geometry (CoreGraphics coordinates: origin top-left, like Accessibility)

    var dividerFrame: CGRect? { divider.flatMap(Self.cgFrame) }
    var dividerWindow: NSWindow? { divider?.button?.window }
    var alwaysFrame: CGRect? { always.flatMap(Self.cgFrame) }
    /// Orbit's own items, which are never listed or moved.
    var ownFrames: [CGRect] { [toggle, divider, always].compactMap { $0.flatMap(Self.cgFrame) } }
    var toggleButton: NSStatusBarButton? { toggle?.button }

    /// Where the button is on screen (AppKit coordinates): the real one, or the icon at the folded
    /// divider's right end.
    var buttonFrame: CGRect {
        if !toggleInView, foldedLength != nil, let d = divider?.button?.window?.frame {
            return CGRect(x: d.maxX - 30, y: d.minY, width: 30, height: d.height)
        }
        return toggle?.button?.window?.frame ?? .zero
    }

    private static func cgFrame(_ item: NSStatusItem) -> CGRect? {
        guard let f = item.button?.window?.frame, let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    /// Creates the always-hidden divider if needed and makes sure it sits left of the main divider.
    /// Call while revealing, so the new divider can't push anything away before it's in place.
    func prepareAlwaysSection() async {
        if always == nil {
            Pref.defaults.set(true, forKey: Pref.hiderAlways)
            addAlwaysDivider()
            try? await Task.sleep(for: .milliseconds(600))
        }
        guard let a = alwaysFrame, let d = dividerFrame, a.minX > d.minX else { return }
        // New items usually land at the far left; if not, carry it over the main divider.
        await MenuBarDrag.drag(from: CGPoint(x: a.midX, y: a.midY), to: CGPoint(x: d.minX + 1, y: d.midY))
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: Showing and hiding

    /// Unfolds every section (or puts them back) without touching the collapsed state.
    func reveal(_ on: Bool) {
        revealing = on
        applyLengths()
        updateToggleImage()
        if !on, collapsed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MenuBarHider.shared.checkFold() } }
    }

    /// The menu bar keeps changing (icons come and go, the clock widens): every few seconds, make
    /// sure the folded divider is still in view.
    @ObservationIgnored private lazy var foldWatch: Timer = {
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let hider = MenuBarHider.shared
                // Keep ✦ / ✦✦ honest even if a close slipped past (the bar closing mid-fade, a menu).
                if hider.drawnOpen != hider.showingHidden { hider.updateToggleImage() }
                hider.placeLid()
                guard hider.collapsed, !hider.revealing, hider.foldedLength != nil, !MenuBarItems.shared.busy,
                      !MenuBarItems.shared.holdingOverflow, !HiddenBar.shared.isVisible else { return }
                hider.watchTicks += 1
                if !Self.inView(hider.divider?.button?.window) { hider.checkFold() }
                else if hider.watchTicks % 5 == 0 {
                    // A full read of the bar only after it reported a change (or now and then, in
                    // case it's not being watched).
                    let changes = OverflowCover.shared.barChanges
                    guard changes != hider.peekCheckedAt || hider.watchTicks % 30 == 0 else { return }
                    hider.peekCheckedAt = changes
                    _ = hider.growOverPeekingIcons()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }()

    /// Opens one hidden item's menu — unfolding, or opening macOS's « overflow, just long enough —
    /// then folds back after the next click (see ``MenuBarItems/open(_:)``).
    func openHidden(_ item: MenuBarItems.Item) {
        Task { await MenuBarItems.shared.open(item) }
    }

    /// From the Ring/launcher: turns the feature on the first time, then toggles.
    func toggleFromAction() {
        if !Pref.defaults.bool(forKey: Pref.hiderEnabled) {
            Pref.defaults.set(true, forKey: Pref.hiderEnabled)
            apply()
            MainWindow.show(.menubar)
            return
        }
        if HiddenBar.shared.isVisible { HiddenBar.shared.hide() } else if collapsed || MenuBarRemoval.shared.active { showHidden() } else { setCollapsed(true) }
    }

    func setCollapsed(_ hide: Bool, quietly: Bool = false) {
        collapseTimer?.invalidate()
        if hide { settleOrder() }
        // If the divider was dragged to the right of the toggle, collapsing would hide the toggle too.
        if hide, Self.inView(divider?.button?.window), Self.inView(toggle?.button?.window),
           let dx = divider?.button?.window?.frame.minX, let tx = toggle?.button?.window?.frame.minX, dx > tx {
            Toast.show("Move the divider left of the arrow", symbol: "arrow.left.and.right", detail: "Hold ⌘ and drag it in the menu bar")
            return
        }
        // Last look at the icons while they're still on screen, for the bar under the menu bar.
        if hide, !collapsed, toggle != nil { Task { await MenuBarItems.shared.captureVisible() } }
        collapsed = hide
        peekSettled = false
        grewFrom = nil
        gaveUp = false
        applyLengths()
        updateToggleImage()
        if hide {
            _ = foldWatch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MenuBarHider.shared.checkFold() }
        }
        let seconds = Pref.defaults.integer(forKey: Pref.hiderAutoCollapse)
        if !hide, !quietly, seconds > 0, toggle != nil {
            collapseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { _ in
                MainActor.assumeIsolated { MenuBarHider.shared.setCollapsed(true) }
            }
        }
    }

    /// How long the divider gets when folded. The classic trick — 10,000 points, pushing everything to
    /// its left off screen — doesn't survive macOS 26 on a full menu bar: macOS just tucks the giant
    /// divider behind its « button and leaves the "hidden" icons in view. A divider exactly as long as
    /// the room between the notch and the visible icons stays on screen, and it's the icons left of it
    /// that no longer fit and go.
    @ObservationIgnored private var foldedLength: CGFloat?
    /// Where the divider's right edge sits (status items grow leftwards, so it stays put however long
    /// the divider gets). Learned while the divider is short and on screen.
    @ObservationIgnored private var dividerRightEdge: CGFloat?

    private func learnRightEdge() {
        guard let d = divider?.button?.window?.frame, d.width < 100, Self.inView(divider?.button?.window) else { return }
        dividerRightEdge = d.maxX
    }

    /// Room between the « button (or the notch) and the divider's right edge.
    private func measureFoldedLength() {
        guard let right = dividerRightEdge, let screen = NSScreen.screens.first else { return }
        let left = (MenuBarItems.overflowButtonFrame()?.maxX ?? screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX) + 6
        // Tight: any slack left of the strip is room for a hidden icon to peek through. If the clock
        // widens and tips the strip behind «, checkFold takes a few points off.
        let room = (right - left - 10).rounded(.down)
        foldedLength = room > 24 ? room : nil
    }

    /// Every length change of the strip goes through here, so the « cover can move to where the
    /// « is about to be before the bar redraws (the strip grows leftwards; « sits just left of it).
    private func setDividerLength(_ length: CGFloat) {
        let old = divider?.length ?? length
        divider?.length = length
        OverflowCover.shared.stripChanged(by: length - old, folded: collapsed && !revealing && length > 12)
    }

    private func applyLengths() {
        defer {
            OverflowCover.shared.refreshSoon()
            lid?.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MenuBarHider.shared.placeLid() }
        }
        let hideMain = collapsed && !revealing
        // A peek (revealing) keeps the measured length so folding back lands exactly where it was.
        if !collapsed { foldedLength = nil }
        if hideMain, foldedLength == nil {
            learnRightEdge()
            if dividerRightEdge == nil {
                // Folded since launch: never seen the divider short. Open it for a moment to measure.
                setDividerLength(12)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    let hider = MenuBarHider.shared
                    hider.learnRightEdge()
                    if hider.dividerRightEdge == nil { hider.dividerRightEdge = hider.divider?.button?.window?.frame.maxX }
                    hider.applyLengths()
                }
                return
            }
            measureFoldedLength()
        } else if !hideMain {
            learnRightEdge()
        }
        setDividerLength(hideMain ? (foldedLength ?? Self.hiddenLength) : 12)
        divider?.button?.image = hideMain ? foldedLength.flatMap { foldedImage(length: $0) } : Self.dividerImage
        divider?.button?.appearsDisabled = !hideMain
        always?.length = revealing ? 12 : Self.hiddenLength
        always?.button?.image = revealing ? Self.alwaysImage : nil
    }

    /// After folding: if macOS tucked the divider itself away anyway, shorten it and fold again;
    /// then make sure the button is still reachable.
    private func checkFold(attempt: Int = 0) {
        guard collapsed, !revealing, !gaveUp, !recovering else { return }
        // Tucked behind « (it then reports a made-up frame left of the « button).
        if let d = divider?.button?.window?.frame, !Self.inView(divider?.button?.window), attempt >= 6 || (foldedLength ?? 300) <= 24 {
            // Even the shortest strip doesn't fit: the divider itself is behind «. Stop shrinking and
            // pull it back out to the front of the bar instead.
            guard !recovering else { return }
            recovering = true
            MenuBarLog.write("fold: divider stays tucked even at \(foldedLength.map { "\($0)" } ?? "max") (frame \(d)); bringing it forward")
            foldedLength = nil
            dividerRightEdge = nil
            Task {
                setDividerLength(12)
                try? await Task.sleep(for: .milliseconds(300))
                await MenuBarItems.shared.bringDividerForward()
                recovering = false
                if Self.inView(divider?.button?.window) {
                    learnRightEdge()
                    applyLengths()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MenuBarHider.shared.checkFold() }
                } else {
                    gaveUp = true
                    MenuBarLog.write("fold: couldn't bring the divider back; staying as is")
                }
            }
            return
        }
        if let d = divider?.button?.window?.frame, attempt < 6, !Self.inView(divider?.button?.window) {
            // Grown too far trying to swallow a peeking icon: go back and live with it.
            if let previous = grewFrom {
                grewFrom = nil
                peekSettled = true
                foldedLength = previous
                MenuBarLog.write("fold: growing tipped the strip behind «; back to \(previous)")
                setDividerLength(previous)
                divider?.button?.image = foldedImage(length: previous)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MenuBarHider.shared.checkFold(attempt: attempt + 1) }
                return
            }
            if foldedLength == nil { measureFoldedLength() }
            foldedLength = max(24, (foldedLength ?? 300) - (attempt == 0 ? 8 : 16))
            MenuBarLog.write("fold: divider tucked away (frame \(d)); shortening to \(foldedLength!)")
            setDividerLength(foldedLength!)
            divider?.button?.image = foldedImage(length: foldedLength!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MenuBarHider.shared.checkFold(attempt: attempt + 1) }
            return
        }
        if let d = divider?.button?.window?.frame { MenuBarLog.write("fold: divider \(d), length \(foldedLength.map { "\($0)" } ?? "max"), button in view \(toggleInView)") }
        if let length = foldedLength { divider?.button?.image = foldedImage(length: length) }
        placeLid()
        grewFrom = nil
        if growOverPeekingIcons() { return }
        unfoldIfToggleLost()
    }

    @ObservationIgnored private var grewFrom: CGFloat?
    @ObservationIgnored private var recovering = false
    /// Recovery failed once; don't keep trying (and spinning) until the user folds again.
    @ObservationIgnored private var gaveUp = false
    @ObservationIgnored private var watchTicks = 0
    @ObservationIgnored private var peekCheckedAt = -1
    @ObservationIgnored private var peekSettled = false

    /// A hidden icon squeezed into the gap between « and the folded strip (the room changed: the clock
    /// narrowed, an icon quit) would sit there in view, with the ✦ far off to its right. Widen the strip
    /// so it goes behind « too — the ✦ then sits right beside the visible icons again.
    private func growOverPeekingIcons() -> Bool {
        guard !peekSettled, let length = foldedLength, let d = dividerFrame else { return false }
        let own = ownFrames
        let layout = MenuBarHosted.read(ownFrames: own)
        let me = ProcessInfo.processInfo.processIdentifier
        let floor = layout.chevron?.maxX ?? 0
        let peeking = layout.slots.filter { slot in
            slot.onBar && slot.frame.minX >= floor - 1 && slot.frame.maxX <= d.minX + 2
                && !(slot.pid == me && own.contains { abs($0.minX - slot.frame.minX) <= 2 })
                // macOS's mic/camera indicator stays in view whatever happens; growing over it only loops.
                && slot.identifier != MenuBarItems.privacyIndicator
        }
        guard let left = peeking.map(\.frame.minX).min() else { return false }
        grewFrom = length
        let grown = (length + (d.minX - left) + 4).rounded()
        MenuBarLog.write("fold: \(peeking.count) icon(s) peeking left of the strip; growing \(length) → \(grown)")
        foldedLength = grown
        setDividerLength(grown)
        divider?.button?.image = foldedImage(length: grown)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MenuBarHider.shared.checkFold() }
        return true
    }

    /// Collapsing must never take the arrow with it (it would be the only way back). If the arrow
    /// ended up off-screen — left of the divider, or squeezed behind the notch — unfold again.
    private func unfoldIfToggleLost() {
        guard collapsed, let window = toggle?.button?.window else { return }
        // The folded divider stands in for a tucked-away button.
        if foldedLength != nil, Self.inView(divider?.button?.window) { return }
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        guard !NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { return }
        setCollapsed(false, quietly: true)
        Toast.show("Not enough room in the menu bar", symbol: "menubar.rectangle",
                   detail: "Hold ⌘ and drag the arrow further right")
    }

    /// Choices for the hider button, Barbee-style. Pairs change with the state — one ✦ while the
    /// icons are hidden, several once they're showing (unfolded or in the bar below); the rest stay
    /// the same.
    static let icons = ["sparkle", "chevron", "star", "moon.stars", "eye", "ellipsis", "circle.grid.2x2", "square.stack.3d.up", "line.3.horizontal.decrease", "orbit"]

    /// Hidden icons are showing somewhere: unfolded in place, peeked at, or in the bar below.
    var showingHidden: Bool {
        MenuBarRemoval.shared.active ? HiddenBar.shared.isVisible : !collapsed || revealing || HiddenBar.shared.isVisible
    }

    @ObservationIgnored private var drawnOpen: Bool?

    func updateToggleImage() {
        drawnOpen = showingHidden
        let icon = Pref.defaults.string(forKey: Pref.hiderIcon) ?? "sparkle"
        let closed = !showingHidden
        let label = closed ? "Show hidden menu bar items".loc : "Hide menu bar items".loc
        toggle?.button?.image = Self.image(for: icon, collapsed: closed, label: label)
        if collapsed, let length = foldedLength { divider?.button?.image = foldedImage(length: length) }
    }

    static func image(for icon: String, collapsed: Bool, label: String = "") -> NSImage? {
        switch icon {
        case "chevron":
            return NSImage(systemSymbolName: collapsed ? "chevron.compact.left" : "chevron.compact.right", accessibilityDescription: label)
        case "sparkle", "sparkles": return symbol(collapsed ? "sparkle" : "sparkles", label)
        case "star": return symbol(collapsed ? "star" : "star.fill", label)
        case "moon.stars": return symbol(collapsed ? "moon" : "moon.stars", label)
        case "eye": return symbol(collapsed ? "eye.slash" : "eye", label)
        case "orbit":
            let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
                NSColor.black.set()
                let c = NSPoint(x: rect.midX, y: rect.midY)
                NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 8, y: c.y - 3, width: 16, height: 6))
                let t = NSAffineTransform()
                t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: -18); t.translateX(by: -c.x, yBy: -c.y)
                ring.transform(using: t as AffineTransform)
                ring.lineWidth = 1.3
                ring.stroke()
                NSBezierPath(ovalIn: NSRect(x: c.x - 8.6, y: c.y - 3.2, width: 3, height: 3)).fill()
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = label
            return image
        default:
            return symbol(icon, label)
        }
    }

    private static func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
    }

    private static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: 2.25, y: 2, width: 1.5, height: rect.height - 4), xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Dotted, so the two dividers can be told apart while everything is unfolded.
    private static let alwaysImage: NSImage = {
        let image = NSImage(size: NSSize(width: 6, height: 16), flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.55).setFill()
            for i in 0..<4 { NSBezierPath(ovalIn: NSRect(x: 2, y: 2.5 + CGFloat(i) * 3.2, width: 2, height: 2)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

#if DEBUG
@MainActor private enum DebugOnce {
    static let install: Void = MenuBarLayoutEditorDebug.install()
}
#endif
