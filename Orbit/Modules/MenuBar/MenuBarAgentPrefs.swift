import AppKit

/// macOS 27's own "Allow in the Menu Bar" switches (System Settings › Menu Bar), driven the way Barbee does it.
///
/// Control Center's group container keeps one entry per app: `trackedApplications`, plist data
/// holding each app's location (bundle id or path), where its items sat, and `isAllowed`. An app that
/// isn't allowed simply has no icon — nothing spills into the « overflow, nothing needs covering.
/// Orbit flips those switches through cfprefsd, keeps the original values to put back. MenuBarAgent
/// watches the domain and applies a change on its own within ~0.3s, so nothing needs restarting;
/// ``restartAgent()`` is only a fallback for when it didn't.
///
/// The file sits in a container macOS protects: Orbit needs Full Disk Access to touch it.
enum MenuBarAgentPrefs {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    /// `defaults` takes a path domain without the extension.
    private static var domain: String { url.deletingPathExtension().path }
    static let key = "trackedApplications"

    /// Orbit can read the file — i.e. it has Full Disk Access.
    static var readable: Bool { (try? Data(contentsOf: url, options: .alwaysMapped)) != nil }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: Reading

    struct Entry {
        /// The app the entry is for.
        let bundleID: String?
        /// The apps its icons come from: a helper inside it (Docker's), or whatever was started from
        /// it (a script run in Terminal is Terminal's).
        let locationIDs: Set<String>
        let isAllowed: Bool
        /// Stable name for the entry, for the originals.
        let key: String

        var bundleIDs: Set<String> { locationIDs.union(bundleID.map { [$0] } ?? []) }
    }

    private static func makeEntry(_ dict: [String: Any]) -> Entry {
        let primary = bundleID(of: dict)
        var locations = Set<String>()
        if let list = dict["menuItemLocations"] as? [Any] {
            for case let location as [String: Any] in list { if let id = bundleID(of: location) { locations.insert(id) } }
        }
        let key = primary ?? String(describing: dict["location"] ?? "?").prefix(200).description
        return Entry(bundleID: primary, locationIDs: locations, isAllowed: dict["isAllowed"] as? Bool ?? true, key: key)
    }

    private enum Format { case binary, xml, json }

    // MARK: cfprefsd, the way Barbee goes through it

    /// The group container MenuBarAgent keeps its preferences in, and the domain inside it.
    private static var container: CFString { url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path as CFString }
    private static let appID = "group.com.apple.controlcenter" as CFString

    private typealias CopyMultiple = @convention(c) (CFArray?, CFString, CFString, CFString, CFString?) -> Unmanaged<CFDictionary>?
    private typealias SetValue = @convention(c) (CFString, CFPropertyList?, CFString, CFString, CFString, CFString?) -> Void
    private typealias Synchronize = @convention(c) (CFString, CFString, CFString, CFString?) -> DarwinBoolean

    private static let cf = dlopen(nil, RTLD_NOW)
    private static let copyMultiple = dlsym(cf, "_CFPreferencesCopyMultipleWithContainer").map { unsafeBitCast($0, to: CopyMultiple.self) }
    private static let setValue = dlsym(cf, "_CFPreferencesSetValueWithContainer").map { unsafeBitCast($0, to: SetValue.self) }
    private static let synchronize = dlsym(cf, "_CFPreferencesSynchronizeWithContainer").map { unsafeBitCast($0, to: Synchronize.self) }

    /// How the last read got its answer, for the log.
    nonisolated(unsafe) private(set) static var lastSource = "none"

    /// The domain as cfprefsd has it (newer than the file on disk while it hasn't flushed), else the
    /// file itself. `defaults export` of the path domain comes back empty on macOS 27, so it isn't used.
    private static func export() -> [String: Any]? {
        if let copyMultiple,
           let d = copyMultiple(nil, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)?.takeRetainedValue() as? [String: Any],
           d[key] != nil {
            lastSource = "cfprefsd"
            return d
        }
        if let data = try? Data(contentsOf: url),
           let d = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            lastSource = "file"
            return d
        }
        lastSource = "none"
        return nil
    }

    /// Writes one key through cfprefsd and checks it landed; falls back to `defaults`.
    private static func store(_ value: Any, whole: [String: Any]) -> Bool {
        if let setValue, let synchronize {
            setValue(key as CFString, value as CFPropertyList, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
            _ = synchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
            if let back = export()?[key], sameValue(back, value) {
                MenuBarLog.write("agent prefs: written through cfprefsd")
                return true
            }
            MenuBarLog.write("agent prefs: cfprefsd didn't keep the change; trying defaults")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-menubar-\(UUID().uuidString).plist")
        var all = whole
        all[key] = value
        guard let data = try? PropertyListSerialization.data(fromPropertyList: all, format: .binary, options: 0),
              (try? data.write(to: tmp)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return run("/usr/bin/defaults", ["import", domain, tmp.path]) != nil
    }

    /// One of Control Center's own top-level settings (`showSiri`, `showVPN`…).
    static func value(_ name: String) -> Any? { export()?[name] }

    /// Sets (or, with nil, clears) one top-level setting through cfprefsd.
    static func setValue(_ name: String, _ value: Any?) -> Bool {
        guard let setValue, let synchronize else { return false }
        setValue(name as CFString, value as CFPropertyList?, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        _ = synchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost, container)
        let back = export()?[name]
        if let value { return back.map { sameValue($0, value) } ?? false }
        return back == nil
    }

    private static func sameValue(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? Data, let y = b as? Data { return x == y }
        return (a as AnyObject).isEqual(b)
    }

    private static func decode(_ data: Data) -> (Any, Format)? {
        if data.starts(with: Array("bplist".utf8)) || data.starts(with: Array("<?xml".utf8)) {
            let format: Format = data.starts(with: Array("bplist".utf8)) ? .binary : .xml
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)).map { ($0, format) }
        }
        return (try? JSONSerialization.jsonObject(with: data)).map { ($0, .json) }
    }

    private static func encode(_ value: Any, _ format: Format) -> Data? {
        switch format {
        case .binary: try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        case .xml: try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        case .json: try? JSONSerialization.data(withJSONObject: value)
        }
    }

    /// The tracked apps, or nil when Orbit can't read them (no Full Disk Access, or a shape it doesn't know).
    static func entries() -> [Entry]? {
        guard let plist = export(), let raw = plist[key] else { return nil }
        let value: Any
        if let data = raw as? Data { guard let decoded = decode(data) else { return nil }; value = decoded.0 } else { value = raw }
        var found: [Entry] = []
        visit(value) { dict in found.append(makeEntry(dict)) }
        return found
    }

    /// Calls `body` with every app entry — any dictionary carrying `isAllowed` — wherever it sits.
    private static func visit(_ value: Any, _ body: ([String: Any]) -> Void) {
        if let d = value as? [String: Any] {
            if d["isAllowed"] is Bool { body(d); return }
            d.values.forEach { visit($0, body) }
        } else if let a = value as? [Any] {
            a.forEach { visit($0, body) }
        }
    }

    private static func transform(_ value: Any, _ body: (inout [String: Any]) -> Void) -> Any {
        if var d = value as? [String: Any] {
            if d["isAllowed"] is Bool { body(&d); return d }
            for (k, v) in d { d[k] = transform(v, body) }
            return d
        }
        if let a = value as? [Any] { return a.map { transform($0, body) } }
        return value
    }

    nonisolated(unsafe) private static var bundleCache: [String: String] = [:]

    /// Which app an entry is about: a bundle id somewhere in its location, or the bundle at a path.
    /// Where its items were (`menuItemLocations`) is left out — that's not the app.
    static func bundleID(of entry: [String: Any]) -> String? {
        var strings: [String] = []
        func collect(_ v: Any) {
            if let s = v as? String { strings.append(s) }
            else if let d = v as? [String: Any] { for (k, x) in d where k != "menuItemLocations" { collect(x) } }
            else if let a = v as? [Any] { a.forEach(collect) }
            else if let data = v as? Data, let inner = decode(data) { collect(inner.0) }
        }
        collect(entry)
        for s in strings {
            if s.hasSuffix(".app") || s.hasSuffix(".app/") || s.hasPrefix("file://") || s.hasPrefix("/") {
                if let cached = bundleCache[s] { return cached }
                guard let u = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s) else { continue }
                if let id = appBundleID(at: u) { bundleCache[s] = id; return id }
            }
        }
        // A reverse-DNS string: com.vendor.App.
        return strings.first { s in
            let parts = s.split(separator: ".")
            return parts.count >= 2 && !s.contains("/") && !s.contains(" ") && s.first?.isLetter == true
        }
    }

    /// An app bundle, or a binary — tracked "ad hoc" by its path, like Electron apps run from a
    /// project — matched to the running app it is, else to the .app around it.
    private static func appBundleID(at url: URL) -> String? {
        if let id = Bundle(url: url)?.bundleIdentifier, url.pathExtension == "app" { return id }
        let path = url.standardizedFileURL.path
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.standardizedFileURL.path == path }),
           let id = app.bundleIdentifier { return id }
        var dir = url.standardizedFileURL
        while dir.path != "/" {
            if dir.pathExtension == "app" { return Bundle(url: dir)?.bundleIdentifier }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Writing

    enum Failure: Error { case unreadable, unknownShape, notTracked([String]), writeFailed }

    /// Decides every app entry's switch in one write: `decide` returns the wanted `isAllowed`, or nil
    /// to leave it. The first time Orbit changes an entry, its value from before is kept (by
    /// ``Entry/key``) for ``restoreOriginals()``. Returns how many entries changed.
    @discardableResult
    static func sync(_ decide: (Entry) -> Bool?) throws -> Int {
        guard let plist = export() else { throw Failure.unreadable }
        guard let raw = plist[key] else { throw Failure.unknownShape }
        let format: Format?
        let value: Any
        if let data = raw as? Data {
            guard let decoded = decode(data) else { throw Failure.unknownShape }
            (value, format) = (decoded.0, decoded.1)
        } else {
            (value, format) = (raw, nil)
        }
        var originals = changedApps
        var log: [String] = []
        var changes: [Change] = []
        let updated = transform(value) { dict in
            let entry = makeEntry(dict)
            guard let want = decide(entry), want != entry.isAllowed else { return }
            if originals[entry.key] == nil { originals[entry.key] = entry.isAllowed }
            dict["isAllowed"] = want
            log.append("\(entry.key)=\(want)")
            changes.append(Change(key: entry.key, bundleIDs: entry.bundleIDs, allowed: want))
        }
        lastChanges = changes
        guard !log.isEmpty else { return 0 }
        backupOnce(plist)
        Pref.defaults.set(originals, forKey: originalsKey)
        let stored: Any
        if let format {
            guard let data = encode(updated, format) else { throw Failure.writeFailed }
            stored = data
        } else {
            stored = updated
        }
        guard store(stored, whole: plist) else { throw Failure.writeFailed }
        MenuBarLog.write("agent prefs: \(log.sorted().joined(separator: ", "))")
        return log.count
    }

    struct Change {
        let key: String
        let bundleIDs: Set<String>
        let allowed: Bool
    }

    /// What the last ``sync(_:)`` changed, so the caller can check the bar followed.
    nonisolated(unsafe) private(set) static var lastChanges: [Change] = []

    /// Switches these apps — every entry whose own app, or whose items' app, it is.
    @discardableResult
    static func setAllowed(_ changes: [String: Bool]) throws -> Int {
        try sync { e in
            if let id = e.bundleID, let want = changes[id] { return want }
            return e.locationIDs.lazy.compactMap { changes[$0] }.first
        }
    }

    /// What every entry Orbit changed was before it did, by ``Entry/key``.
    private static let originalsKey = "menubar.agentOriginals"
    static var changedApps: [String: Bool] { Pref.defaults.dictionary(forKey: originalsKey) as? [String: Bool] ?? [:] }

    static func forget(_ key: String) {
        var originals = changedApps
        originals[key] = nil
        Pref.defaults.set(originals, forKey: originalsKey)
    }

    /// Entries that differ from the copy taken before Orbit's first change, and that Orbit has no
    /// original for, were changed by Orbit (earlier builds kept originals by app, not by entry):
    /// remember them so they're put back too.
    static func adoptBackupOriginals() {
        let backup = Storage.dir("MenuBar").appendingPathComponent("group.com.apple.controlcenter.original.plist")
        guard let data = try? Data(contentsOf: backup),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let raw = plist[key] else { return }
        let value: Any
        if let d = raw as? Data { guard let decoded = decode(d) else { return }; value = decoded.0 } else { value = raw }
        var before: [String: Bool] = [:]
        visit(value) { dict in let e = makeEntry(dict); before[e.key] = e.isAllowed }
        var originals = changedApps
        var adopted: [String] = []
        for e in entries() ?? [] where originals[e.key] == nil {
            if let was = before[e.key], was != e.isAllowed { originals[e.key] = was; adopted.append(e.key) }
        }
        guard !adopted.isEmpty else { return }
        Pref.defaults.set(originals, forKey: originalsKey)
        MenuBarLog.write("agent prefs: adopted originals for \(adopted.sorted())")
    }

    #if DEBUG
    /// Takes an app out of the tracked list altogether — its entry and the key paired with it — as if
    /// it had never had an icon (debug: cleaning up after a throwaway test app). Returns how many went.
    static func removeEntries(bundleID id: String) throws -> Int {
        guard let plist = export() else { throw Failure.unreadable }
        guard let raw = plist[key] else { throw Failure.unknownShape }
        let format: Format?
        let value: Any
        if let data = raw as? Data {
            guard let decoded = decode(data) else { throw Failure.unknownShape }
            (value, format) = (decoded.0, decoded.1)
        } else {
            (value, format) = (raw, nil)
        }
        guard let list = value as? [Any] else { throw Failure.unknownShape }
        let kept = list.filter { v in (v as? [String: Any]).map { bundleID(of: $0) != id } ?? true }
        let dropped = list.count - kept.count
        guard dropped > 0 else { return 0 }
        let stored: Any
        if let format {
            guard let data = encode(kept, format) else { throw Failure.writeFailed }
            stored = data
        } else {
            stored = kept
        }
        guard store(stored, whole: plist) else { throw Failure.writeFailed }
        MenuBarLog.write("agent prefs: removed \(dropped) tracked record(s) of \(id)")
        return dropped
    }
    #endif

    /// Puts back every switch Orbit flipped. Returns whether MenuBarAgent needs a restart.
    @discardableResult
    static func restoreOriginals() -> Bool {
        let originals = changedApps
        guard !originals.isEmpty else { return false }
        do { try sync { originals[$0.key] } } catch { MenuBarLog.write("agent prefs: restore failed \(error)"); return false }
        Pref.defaults.removeObject(forKey: originalsKey)
        return true
    }

    /// A copy of the whole domain as it was before Orbit's first change, just in case.
    private static func backupOnce(_ plist: [String: Any]) {
        let backup = Storage.dir("MenuBar").appendingPathComponent("group.com.apple.controlcenter.original.plist")
        guard !FileManager.default.fileExists(atPath: backup.path),
              let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? data.write(to: backup)
    }

    // MARK: MenuBarAgent

    /// MenuBarAgent reads the switches when it starts. launchd brings it straight back; this waits
    /// until the new one is up (or a few seconds pass).
    static func restartAgent() async {
        let old = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").map(\.processIdentifier)
        // SIGKILL, not SIGTERM: on a normal quit MenuBarAgent saves the switches it has in memory,
        // writing the old values back over the ones just set.
        for pid in old { kill(pid, SIGKILL) }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").map(\.processIdentifier)
            if let pid = now.first, !old.contains(pid) { break }
        }
        // Its items come back over the next moment.
        try? await Task.sleep(for: .milliseconds(500))
        MenuBarLog.write("agent: restarted")
    }

    // MARK: Helpers

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    /// The plist's shape, for working out what MenuBarAgent keeps (debug only; bundle ids are fine to log).
    static func describe() -> String {
        guard readable else { return "unreadable (no Full Disk Access)" }
        guard let plist = export() else { return "export failed" }
        var lines = plist.keys.sorted().map { "\($0): \(type(of: plist[$0]!))" }
        if let raw = plist[key] as? Data, let (value, format) = decode(raw) {
            lines.append("tracked format \(format)")
            var first = true
            visit(value) { d in
                if first { lines.append("entry keys: \(d.keys.sorted()) location: \(String(describing: d["location"]).prefix(300))"); first = false }
            }
        }
        lines.append("source \(lastSource)")
        #if DEBUG
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var report = ""
        for path in ["\(home)/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist",
                     "\(home)/Library/Containers/com.apple.MenuBarAgent/Data/Library/Preferences/com.apple.MenuBarAgent.plist",
                     "\(home)/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist",
                     "\(home)/Library/Preferences/com.apple.MenuBarAgent.plist"] {
            report += "== \(path)\n"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent) {
                report += "dir: \(entries.sorted())\n"
            } else { report += "dir unreadable\n" }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let d = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { report += "unreadable\n"; continue }
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                if let data = v as? Data, let inner = decode(data) { report += "\(k) (data):\n\(String(describing: inner.0))\n" }
                else { report += "\(k): \(String(describing: v))\n" }
            }
        }
        try? report.write(to: Storage.dir("MenuBar").appendingPathComponent("agent-files.txt"), atomically: true, encoding: .utf8)
        #endif
        lines += (entries() ?? []).map { "  \($0.key.prefix(90)) allowed \($0.isAllowed) locations \($0.locationIDs.sorted())" }
        #if DEBUG
        // The whole thing, for working out the shape (stays in Orbit's own folder).
        if let raw = plist[key] as? Data, let (value, _) = decode(raw) {
            let dump = Storage.dir("MenuBar").appendingPathComponent("tracked-dump.txt")
            try? String(describing: value).write(to: dump, atomically: true, encoding: .utf8)
            lines.append("dumped to \(dump.path)")
        }
        #endif
        return lines.joined(separator: "\n  ")
    }
}
