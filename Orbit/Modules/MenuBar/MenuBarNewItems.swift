import AppKit
import ApplicationServices

/// Icons from apps Orbit has never seen go straight to Hidden, the way Barbee does it: the moment an
/// app's first icon shows up, its switch goes off (see ``MenuBarRemoval``) and it's listed under Hidden.
///
/// Orbit remembers apps, not single icons — macOS switches whole apps, and an icon's label can change
/// (a CPU meter's title). An app it knows keeps whatever the user chose for it, however often it quits
/// and comes back; only one that has never had an icon while Orbit was watching counts as new. The
/// first time this runs, everything there is (on the bar, switched off, or known to macOS's own list)
/// counts as known, so nothing the user has now suddenly goes.
///
/// Noticing is cheap: MenuBarAgent tells Accessibility when its slots change, apps announce their
/// launch, and one read of MenuBarAgent's bar (well under a millisecond) says which processes have
/// icons. A slow backstop covers anything missed.
@MainActor
final class MenuBarNewItems {
    static let shared = MenuBarNewItems()

    /// Bundle ids of every app Orbit has seen an icon of.
    private static let knownKey = "menubar.knownApps"
    /// Was watching when Orbit last ran; if not, what's there now is taken as known first.
    private static let watchingKey = "menubar.newItemsWatching"

    private var known: Set<String> = Set(Pref.defaults.stringArray(forKey: knownKey) ?? []) {
        didSet { if known != oldValue { Pref.defaults.set(known.sorted(), forKey: Self.knownKey) } }
    }

    private var running = false
    private var needsSeed = false
    private var launchObserver: Any?
    private var backstop: Timer?
    private var axObserver: AXObserver?
    private var agentPID: pid_t = 0
    /// Processes with an icon at the last look; a look that finds the same ones stops there.
    private var lastPIDs: Set<pid_t> = []
    private var handling: Set<String> = []
    private var scheduled = false
    private var lastCheck = Date.distantPast

    var enabled: Bool { Pref.defaults.bool(forKey: Pref.hideNewItems) }

    /// The hider came on (or Orbit started with it on).
    func start() {
        guard !running else { return }
        running = true
        needsSeed = !Pref.defaults.bool(forKey: Self.watchingKey) || known.isEmpty
        lastPIDs = []
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated { MenuBarNewItems.shared.launched(pid) }
        }
        let t = Timer(timeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarNewItems.shared.check() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        backstop = t
        // Orbit's own items and the bar settle first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MenuBarNewItems.shared.check() }
    }

    /// The hider went off: stop, and take what's there as known when it comes back on.
    func stop() {
        Pref.defaults.set(false, forKey: Self.watchingKey)
        guard running else { return }
        running = false
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        backstop?.invalidate()
        backstop = nil
        unobserveBar()
    }

    /// An app has just started: its icon follows within a moment, or a few seconds for slow starters.
    private func launched(_ pid: pid_t?) {
        guard running else { return }
        if let pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.MenuBarAgent" {
            unobserveBar()
        }
        for delay in [0.3, 1.0, 2.5, 5.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MenuBarNewItems.shared.check() }
        }
    }

    // MARK: Looking

    /// One look at the bar: any process with an icon that wasn't there last time is looked up.
    func check() {
        guard running, AXIsProcessTrusted() else { return }
        lastCheck = Date()
        observeBar()
        if needsSeed {
            seed()
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let layout = MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames)
        var bundles: [String: NSRunningApplication] = [:]
        if layout.slots.isEmpty {
            // No MenuBarAgent bar to go by: the long way, every app's own tree.
            for b in MenuBarItems.bundlesWithItems() where !known.contains(b) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first { bundles[b] = app }
            }
        } else {
            let pids = Set(layout.slots.map(\.pid)).subtracting([me])
            guard pids != lastPIDs else { return }
            lastPIDs = pids
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid), let b = app.bundleIdentifier, !known.contains(b) else { continue }
                bundles[b] = app
            }
        }
        for (bundle, app) in bundles where !handling.contains(bundle) {
            arrived(bundle, app)
        }
    }

    /// Everything there is now counts as known: icons on the bar, apps whose icons are switched off,
    /// and every app macOS's own list has ever tracked.
    private func seed() {
        var all = known
        all.formUnion(MenuBarItems.bundlesWithItems())
        all.formUnion(MenuBarItems.bundlesOnBar())
        all.formUnion(MenuBarItems.shared.items.map { MenuBarRemoval.bundleID(ofItem: $0.id) })
        all.formUnion(MenuBarRemoval.shared.removed.values.map(\.bundleID))
        for e in MenuBarAgentPrefs.entries() ?? [] { all.formUnion(e.bundleIDs) }
        if let layout = Pref.defaults.dictionary(forKey: "menubar.arrangement") as? [String: [String]] {
            all.formUnion(layout.values.joined().map(MenuBarRemoval.bundleID(ofItem:)))
        }
        all.remove("")
        known = all
        needsSeed = false
        Pref.defaults.set(true, forKey: Self.watchingKey)
        lastPIDs = Set(MenuBarHosted.read(ownFrames: MenuBarHider.shared.ownFrames).slots.map(\.pid))
        MenuBarLog.write("new icons: watching; \(all.count) apps known already")
    }

    private func arrived(_ bundle: String, _ app: NSRunningApplication) {
        // Known from now on, whatever happens next: the user's own choice for it sticks.
        known.insert(bundle)
        let name = app.localizedName ?? bundle
        // Orbit's own, and macOS's (the clock, Control Center, Wi-Fi…: those the user turns on in System Settings).
        guard MenuBarRemoval.switchable(bundle) else { return }
        guard enabled, MenuBarRemoval.shared.active else {
            MenuBarLog.write("new icons: \(bundle) is new; left where it is (\(enabled ? "hider isn't switching icons off" : "setting off"))")
            return
        }
        MenuBarLog.write("new icons: \(bundle) is new; hiding it")
        handling.insert(bundle)
        Task {
            await hide(bundle, name: name, app: app)
            handling.remove(bundle)
        }
    }

    // MARK: Hiding

    private func hide(_ bundle: String, name: String, app: NSRunningApplication) async {
        let started = ContinuousClock.now
        let items = MenuBarItems.shared
        // Its icon, read (and photographed) through Accessibility — an app can take a moment.
        var found: [MenuBarItems.Item] = []
        for _ in 0..<10 {
            found = await items.newItems(of: bundle)
            if !found.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if found.isEmpty {
            // Not readable yet: switch the app off all the same; it's listed by name meanwhile.
            found = [MenuBarItems.Item(id: "\(bundle)|", name: name, appIcon: app.icon ?? NSImage(), element: nil, button: nil, frame: .zero,
                                       section: .hidden, shown: false, order: 10_000, image: nil, mobility: .free)]
        }
        let removal = MenuBarRemoval.shared
        for item in found {
            MenuBarItems.saveIcon(item.id, item.image)
            removal.place(item, in: .hidden)
        }
        // MenuBarAgent may not have written the app's entry yet: until there is one to switch off, try again.
        var gone = false
        for _ in 0..<10 {
            while removal.working { try? await Task.sleep(for: .milliseconds(50)) }
            await removal.commit()
            try? await Task.sleep(for: .milliseconds(250))
            if !MenuBarItems.bundlesOnBar().contains(bundle) { gone = true; break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        MenuBarLog.write("new icons: \(bundle) \(gone ? "switched off" : "still on the bar") after \(started.duration(to: .now)) (\(found.map(\.id)))")
        await items.refresh(reveal: false)
        guard gone else { return }
        Toast.show("Hid a new menu bar icon", symbol: "eye.slash", detail: name, actionTitle: "Show") {
            Task { @MainActor in
                let shared = MenuBarItems.shared
                if let item = shared.items.first(where: { MenuBarRemoval.bundleID(ofItem: $0.id) == bundle && $0.section != .visible }) {
                    await shared.open(item)
                } else {
                    MenuBarHider.shared.showHidden()
                }
            }
        }
    }

    // MARK: Watching the bar

    /// MenuBarAgent posts these within a few ms of a slot coming or its slots moving; they come in
    /// floods, so they only ask for a look, at most every half second.
    private func observeBar() {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first else { return }
        if axObserver != nil, agent.processIdentifier == agentPID { return }
        unobserveBar()
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { MenuBarNewItems.shared.barChanged() }
        }
        guard AXObserverCreate(agent.processIdentifier, callback, &observer) == .success, let observer else { return }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(observer, root, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        agentPID = agent.processIdentifier
    }

    private func unobserveBar() {
        if let axObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes) }
        axObserver = nil
        agentPID = 0
    }

    private func barChanged() {
        guard running, !scheduled else { return }
        scheduled = true
        let wait = max(0.15, 0.5 - Date().timeIntervalSince(lastCheck))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            MenuBarNewItems.shared.scheduled = false
            MenuBarNewItems.shared.check()
        }
    }

    // MARK: Debug

    var knownApps: Set<String> { known }

    /// Forgets an app entirely, as if it had never had an icon (for a throwaway test app).
    func forget(_ bundle: String) {
        known.remove(bundle)
        lastPIDs = []
    }
}
