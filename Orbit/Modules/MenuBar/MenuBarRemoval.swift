import AppKit

/// Hiding by switching icons off, not pushing them away: an icon put in a hidden section has its app's
/// "Allow in the Menu Bar" switch turned off (see ``MenuBarAgentPrefs``), so it's really gone — no
/// divider, no « to cover, nothing to flicker in full screen or across Spaces. Moving it back to
/// Visible turns the switch on again. Clicking a hidden icon in Orbit's bar brings it back just long
/// enough to use it.
///
/// macOS switches whole apps, so every icon of an app goes together.
@MainActor @Observable
final class MenuBarRemoval {
    static let shared = MenuBarRemoval()

    /// Orbit has Full Disk Access, so it can flip the switches.
    private(set) var permitted = MenuBarAgentPrefs.readable
    /// Changes are being written and MenuBarAgent restarted.
    private(set) var working = false

    /// Hiding works this way (instead of the divider) whenever the hider is on and Orbit is allowed.
    var active: Bool { permitted && Pref.defaults.bool(forKey: Pref.hiderEnabled) }

    struct Removed: Codable, Equatable {
        var bundleID: String
        var name: String
        var section: String
        var order: Double
        /// macOS's own icons: which setting switches it (see ``MenuBarSystemSwitches``).
        var system: String? = nil
    }

    private static let key = "menubar.removed"
    /// Item id → what Orbit needs to list it while it's off the bar.
    private(set) var removed: [String: Removed] = {
        guard let data = Pref.defaults.data(forKey: key) else { return [:] }
        let all = (try? JSONDecoder().decode([String: Removed].self, from: data)) ?? [:]
        return all.filter { $0.value.system != nil || switchable($0.value.bundleID) }
    }() {
        didSet { Pref.defaults.set(try? JSONEncoder().encode(removed), forKey: Self.key) }
    }

    func isRemoved(_ id: String) -> Bool { removed[id] != nil }
    /// Apps to switch off. Never Orbit itself (✦ is how hidden icons come back) or macOS's own owners,
    /// which aren't in the list of switches.
    var removedBundles: Set<String> { Set(removed.values.filter { $0.system == nil }.map(\.bundleID)).filter(Self.switchable) }
    var removedSystem: Set<MenuBarSystemSwitches.Switch> { Set(removed.values.compactMap { $0.system.flatMap(MenuBarSystemSwitches.Switch.init(key:)) }) }

    static func systemSwitch(for item: MenuBarItems.Item) -> MenuBarSystemSwitches.Switch? {
        guard MenuBarItems.isSystem(item.id), item.mobility != .fixed else { return nil }
        return MenuBarSystemSwitches.switch(identifier: item.identifier, owner: bundleID(ofItem: item.id), name: item.name)
    }

    static func switchable(_ bundle: String) -> Bool {
        bundle != Bundle.main.bundleIdentifier && !MenuBarItems.isSystem(bundle + "|")
    }

    static func bundleID(ofItem id: String) -> String { String(id.split(separator: "|", maxSplits: 1).first ?? "") }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarRemoval.shared.checkPermission() }
        }
    }

    /// Looks again (Orbit may just have been given Full Disk Access).
    func checkPermission() {
        let now = MenuBarAgentPrefs.readable
        guard now != permitted else { return }
        // What the divider was hiding stays hidden — switched off now.
        let wasHidden = now ? MenuBarItems.shared.items.filter { $0.section != .visible && $0.mobility == .free
            && (!MenuBarItems.isSystem($0.id) || Self.systemSwitch(for: $0) != nil) } : []
        permitted = now
        MenuBarLog.write("removal: full disk access \(now)")
        if Pref.defaults.bool(forKey: Pref.hiderEnabled) { for item in wasHidden { place(item, in: item.section) } }
        MenuBarHider.shared.rebuild()
        if now { Task { await reconcile() } }
    }

    // MARK: Changing sections

    /// The user put `item` in `section`. Every icon of its app follows; the switch flips after a short
    /// pause so dropping several icons costs one restart.
    func place(_ item: MenuBarItems.Item, in section: MenuBarItems.Section) {
        let bundle = Self.bundleID(ofItem: item.id)
        if MenuBarItems.isSystem(item.id) {
            guard let sw = Self.systemSwitch(for: item) else { return }
            removed[item.id] = section == .visible ? nil
                : Removed(bundleID: bundle, name: item.name, section: section.rawValue, order: Double(item.order), system: sw.key)
            scheduleCommit()
            return
        }
        guard Self.switchable(bundle) else { return }
        if section == .visible {
            for (id, r) in removed where r.bundleID == bundle { removed[id] = nil }
        } else {
            removed[item.id] = Removed(bundleID: bundle, name: item.name, section: section.rawValue, order: Double(item.order))
            for other in MenuBarItems.shared.items where other.id != item.id && Self.bundleID(ofItem: other.id) == bundle {
                removed[other.id] = Removed(bundleID: bundle, name: other.name, section: section.rawValue, order: Double(other.order))
            }
        }
        scheduleCommit()
    }

    /// Drops everything Orbit kept about an app (for cleaning up after a test app).
    func forget(bundle: String) {
        for (id, r) in removed where r.bundleID == bundle { removed[id] = nil }
        MenuBarAgentPrefs.forget(bundle)
    }

    private var commitTask: Task<Void, Never>?

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await commit()
        }
    }

    /// Makes the switches match `removed`. An entry goes off when its app is hidden, or when it has
    /// no icons of its own and every app its icons come from is hidden (Docker's helper; something
    /// started from Terminal). Any entry Orbit switched off that no longer needs to be goes back.
    func commit() async {
        guard permitted, !working else { return }
        // macOS's own icons switch live, no restart.
        MenuBarSystemSwitches.apply(hidden: removedSystem)
        await write(decide: decision())
    }

    /// What Orbit last wrote for entries it switched off only for what was started from them; macOS
    /// turns some of those (a terminal's) straight back on, and Orbit then stops trying rather than
    /// restarting the menu bar at every launch.
    private static let launcherKey = "menubar.launcherWrites"
    private static let stubbornKey = "menubar.launcherStubborn"

    /// - Parameter keepingTemporary: leave alone what's switched on for the icon in use right now.
    private func decision(keepingTemporary: Bool = true) -> (MenuBarAgentPrefs.Entry) -> Bool? {
        let off = removedBundles
        let temporary = temporary
        let withIcons = Set(MenuBarItems.shared.items.map { Self.bundleID(ofItem: $0.id) })
        let originals = MenuBarAgentPrefs.changedApps
        let written = Pref.defaults.dictionary(forKey: Self.launcherKey) as? [String: Bool] ?? [:]
        // Earlier builds switched launcher entries back on themselves while an icon was out for a
        // moment, then took that for macOS doing it: start that list over once.
        if !Pref.defaults.bool(forKey: "menubar.stubbornReset1") {
            Pref.defaults.removeObject(forKey: Self.stubbornKey)
            Pref.defaults.set(true, forKey: "menubar.stubbornReset1")
        }
        var stubborn = Set(Pref.defaults.stringArray(forKey: Self.stubbornKey) ?? [])
        // (An entry on only for the icon in use isn't macOS turning it back on.)
        for e in MenuBarAgentPrefs.entries() ?? [] where written[e.key] == false && e.isAllowed && !temporary.contains(e.key) { stubborn.insert(e.key) }
        Pref.defaults.set(Array(stubborn), forKey: Self.stubbornKey)
        var launchers: [String: Bool] = [:]
        defer { Pref.defaults.set(launchers, forKey: Self.launcherKey) }
        return { e in
            if keepingTemporary, temporary.contains(e.key) { return nil }
            let ownOff = e.bundleID.map(off.contains) ?? false
            let ownIcons = e.bundleID.map { withIcons.contains($0) && !off.contains($0) } ?? false
            let othersOff = !e.locationIDs.subtracting(e.bundleID.map { [$0] } ?? []).isEmpty
                && e.locationIDs.subtracting(e.bundleID.map { [$0] } ?? []).isSubset(of: off)
            if ownOff { return false }
            if othersOff, !ownIcons, !stubborn.contains(e.key) {
                launchers[e.key] = false
                Pref.defaults.set(launchers, forKey: Self.launcherKey)
                return false
            }
            // Orbit's own change, no longer wanted: back as it was.
            if let was = originals[e.key], e.isAllowed != was { return was }
            return nil
        }
    }

    private func write(decide: (MenuBarAgentPrefs.Entry) -> Bool?) async {
        working = true
        defer { working = false }
        let changed: Int
        do {
            changed = try MenuBarAgentPrefs.sync(decide)
        } catch {
            MenuBarLog.write("removal: write failed \(error)")
            Toast.show("Couldn’t change the menu bar", symbol: "exclamationmark.triangle", detail: "macOS didn’t take the change")
            return
        }
        guard changed > 0 else { return }
        await settle(MenuBarAgentPrefs.lastChanges)
        await MenuBarItems.shared.refresh(reveal: false)
    }

    /// MenuBarAgent picks a switch change up by itself (~0.3s) — only the changed icons come and go,
    /// nothing else on the bar reloads. Should an icon that went off still be there after a moment,
    /// MenuBarAgent missed it: restart it once, as a last resort.
    private func settle(_ changes: [MenuBarAgentPrefs.Change]) async {
        let off = changes.filter { !$0.allowed }.reduce(into: Set<String>()) { $0.formUnion($1.bundleIDs) }
        let on = changes.filter(\.allowed).reduce(into: Set<String>()) { $0.formUnion($1.bundleIDs) }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        var lingering: Set<String> = []
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
            let bundles = MenuBarItems.bundlesOnBar()
            lingering = off.subtracting(on).intersection(bundles)
            if lingering.isEmpty { return }
        } while ContinuousClock.now < deadline
        // An icon whose menu is still open stays until the menu closes; that's not a missed change.
        if lingering.allSatisfy(Self.menuOpen) {
            MenuBarLog.write("removal: \(lingering.sorted()) still on the bar, its menu open; leaving it to MenuBarAgent")
            return
        }
        MenuBarLog.write("removal: \(lingering.sorted()) still on the bar after 1.5s; restarting MenuBarAgent")
        await MenuBarAgentPrefs.restartAgent()
    }

    /// The app has a menu or popover open up by the menu bar.
    private static func menuOpen(_ bundle: String) -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= 20,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], let y = b["Y"] else { return false }
            return y < 80
        }
    }

    /// At launch, or once Full Disk Access arrives: anything the user hid that macOS turned back on
    /// (an update, System Settings) goes off again — and an icon that was out for a moment when
    /// Orbit last went away goes back first.
    func reconcile() async {
        guard active else { return }
        MenuBarAgentPrefs.adoptBackupOriginals()
        await putBackTemporary()
        await commit()
    }

    /// The hider was turned off: every switch Orbit flipped goes back to how it was.
    func restoreAll() async {
        commitTask?.cancel()
        removed = [:]
        MenuBarSystemSwitches.apply(hidden: [])
        guard permitted, !MenuBarAgentPrefs.changedApps.isEmpty else { return }
        working = true
        defer { working = false }
        temporary = []
        if MenuBarAgentPrefs.restoreOriginals() { await settle(MenuBarAgentPrefs.lastChanges) }
    }

    // MARK: Using a hidden icon

    /// Entries switched on just for the icon in use, by key; kept on disk so a crash mid-use doesn't
    /// leave the icon on the bar.
    private static let temporaryKey = "menubar.temporaryOn"
    private var temporary: Set<String> {
        get { Set(Pref.defaults.stringArray(forKey: Self.temporaryKey) ?? []) }
        set { newValue.isEmpty ? Pref.defaults.removeObject(forKey: Self.temporaryKey) : Pref.defaults.set(newValue.sorted(), forKey: Self.temporaryKey) }
    }

    /// Switches on only what carries this app's icons — its own entry; or, for an icon started from
    /// another app (a script in Terminal), that entry — and nothing else. MenuBarAgent shows it at
    /// its place within a moment, without the rest of the bar reloading.
    /// ``MenuBarItems/openRemoved(_:)`` presses it and calls ``endTemporary()`` once its menu is closed.
    func beginTemporary(_ bundle: String) async -> Bool {
        guard permitted else { return false }
        let entries = MenuBarAgentPrefs.entries() ?? []
        var keys = Set(entries.filter { !$0.isAllowed && $0.bundleID == bundle }.map(\.key))
        if keys.isEmpty { keys = Set(entries.filter { !$0.isAllowed && $0.locationIDs.contains(bundle) }.map(\.key)) }
        guard !keys.isEmpty else { return true } // already on
        working = true
        defer { working = false }
        do { try MenuBarAgentPrefs.sync { keys.contains($0.key) ? true : nil } } catch {
            MenuBarLog.write("removal: couldn't switch \(bundle) on for a moment: \(error)")
            return false
        }
        temporary = temporary.union(keys)
        MenuBarLog.write("removal: \(bundle) on for a moment (\(keys.sorted()))")
        return true
    }

    /// The icon's menu closed: exactly the entries switched on for it go off again.
    func endTemporary() async { await putBackTemporary() }

    private func putBackTemporary() async {
        let keys = temporary
        guard !keys.isEmpty, permitted else { return }
        working = true
        defer { working = false }
        do {
            // Only if it's still meant to be off: the user may have moved it to Visible meanwhile.
            let wanted = decision(keepingTemporary: false)
            try MenuBarAgentPrefs.sync { e in
                // Asked of every entry: it also keeps Orbit's notes on launcher entries complete.
                let want = wanted(e)
                return keys.contains(e.key) && want == false ? false : nil
            }
        } catch {
            MenuBarLog.write("removal: couldn't switch back off: \(error)")
            return
        }
        temporary = []
        await settle(MenuBarAgentPrefs.lastChanges)
    }
}
