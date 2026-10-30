import AppKit
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    static let apps = Self("apps", default: .init(.a, modifiers: [.option, .shift]))
}

/// Every app on the Mac, for the Apps grid: found by scanning the app folders (and watching them),
/// with categories, what's running, what gets used, and what the person pinned.
@MainActor @Observable
final class AppsCatalog {
    static let shared = AppsCatalog()

    struct App: Identifiable, Hashable, Sendable {
        var id: String { path }
        let path: String
        /// The name Finder shows, in the person's language ("캘린더").
        let name: String
        /// The bundle's own name ("Calendar"), so either language finds it.
        let bundleName: String
        let bundleID: String?
        let category: Category
        let isSystem: Bool
        /// Lowercased name + bundle name; and the name's initial consonants (ㅋㄹㄷ) for Korean search.
        let haystack: String
        let initials: String

        var url: URL { URL(fileURLWithPath: path) }
    }

    enum Category: String, CaseIterable, Sendable {
        case productivity, developer, social, games, utilities, creativity, entertainment, education, business, lifestyle, other

        var title: String {
            switch self {
            case .productivity: "Productivity"
            case .developer: "Developer Tools"
            case .social: "Social"
            case .games: "Games"
            case .utilities: "Utilities"
            case .creativity: "Creativity"
            case .entertainment: "Entertainment"
            case .education: "Education"
            case .business: "Business"
            case .lifestyle: "Lifestyle"
            case .other: "Other"
            }
        }

        var symbol: String {
            switch self {
            case .productivity: "checklist"
            case .developer: "hammer"
            case .social: "bubble.left.and.bubble.right"
            case .games: "gamecontroller"
            case .utilities: "wrench.and.screwdriver"
            case .creativity: "paintbrush"
            case .entertainment: "play.rectangle"
            case .education: "graduationcap"
            case .business: "briefcase"
            case .lifestyle: "heart"
            case .other: "square.grid.2x2"
            }
        }

        /// From `LSApplicationCategoryType` (public.app-category.…).
        nonisolated init(uti: String?) {
            let c = (uti ?? "").replacingOccurrences(of: "public.app-category.", with: "")
            switch c {
            case "productivity", "reference", "news", "weather": self = .productivity
            case "developer-tools": self = .developer
            case "social-networking": self = .social
            case "utilities": self = .utilities
            case "graphics-design", "photography", "video", "music": self = .creativity
            case "entertainment": self = .entertainment
            case "education": self = .education
            case "business", "finance": self = .business
            case "lifestyle", "healthcare-fitness", "medical", "sports", "travel": self = .lifestyle
            default: self = c.contains("games") ? .games : .other
            }
        }
    }

    // MARK: Settings

    enum Folder: String, CaseIterable, Sendable {
        case applications, system, utilities, user, setapp

        var title: String {
            switch self {
            case .applications: "Applications"
            case .system: "Apple apps"
            case .utilities: "Utilities"
            case .user: "Your Applications folder"
            case .setapp: "Setapp"
            }
        }

        var subtitle: String {
            switch self {
            case .applications: "/Applications"
            case .system: "/System/Applications"
            case .utilities: "Terminal, Activity Monitor, Disk Utility…"
            case .user: "~/Applications"
            case .setapp: "/Applications/Setapp"
            }
        }

        nonisolated var paths: [String] {
            switch self {
            case .applications: ["/Applications"]
            case .system: ["/System/Applications"]
            case .utilities: ["/System/Applications/Utilities", "/Applications/Utilities"]
            case .user: [NSHomeDirectory() + "/Applications"]
            case .setapp: ["/Applications/Setapp"]
            }
        }

        var prefKey: String { "apps.folder.\(rawValue)" }
    }

    func includes(_ f: Folder) -> Bool { Pref.defaults.object(forKey: f.prefKey) as? Bool ?? true }
    func set(_ f: Folder, _ on: Bool) { Pref.defaults.set(on, forKey: f.prefKey); settingsVersion += 1; reload() }

    /// Folders the person added.
    var extraFolders: [String] {
        get { _ = settingsVersion; return Pref.defaults.stringArray(forKey: "apps.extraFolders") ?? [] }
        set { Pref.defaults.set(newValue, forKey: "apps.extraFolders"); settingsVersion += 1; reload() }
    }

    var iconSize: Double {
        get { _ = settingsVersion; return Pref.defaults.object(forKey: "apps.iconSize") as? Double ?? 72 }
        set { Pref.defaults.set(newValue, forKey: "apps.iconSize"); settingsVersion += 1; warmTiles() }
    }

    var showCategories: Bool {
        get { _ = settingsVersion; return Pref.defaults.object(forKey: "apps.showCategories") as? Bool ?? true }
        set { Pref.defaults.set(newValue, forKey: "apps.showCategories"); settingsVersion += 1 }
    }

    var showFrequent: Bool {
        get { _ = settingsVersion; return Pref.defaults.object(forKey: "apps.showFrequent") as? Bool ?? true }
        set { Pref.defaults.set(newValue, forKey: "apps.showFrequent"); settingsVersion += 1 }
    }

    private var settingsVersion = 0

    // MARK: State

    private(set) var apps: [App] = []
    private(set) var running: Set<String> = []
    private(set) var pinned: [String] = Pref.defaults.stringArray(forKey: "apps.pinned") ?? []
    /// path → (uses, last use).
    /// Kept in a file, not in preferences: it changes on every app switch, and every preference
    /// write makes SwiftUI re-check (and re-lay out) every open settings page.
    private var usage: [String: [Double]] = Storage.load([String: [Double]].self, from: "app-usage.json")
        ?? Pref.defaults.dictionary(forKey: "apps.usage") as? [String: [Double]] ?? [:]
    @ObservationIgnored private var usageSave: DispatchWorkItem?
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var started = false
    private var reloadWork: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        reload()
        refreshRunning()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppsCatalog.shared.refreshRunning() }
            }
        }
        // Real use, not just launches from here: whatever the person switches to counts.
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
            MainActor.assumeIsolated { if let path { AppsCatalog.shared.noteUse(path) } }
        }
    }

    func reload() {
        let roots = scanRoots()
        watch(roots)
        Task.detached(priority: .utility) {
            let found = Self.scan(roots)
            await MainActor.run {
                let catalog = AppsCatalog.shared
                if catalog.apps != found { catalog.apps = found }
                catalog.warmTiles()
            }
        }
    }

    private func scanRoots() -> [String] {
        Folder.allCases.filter(includes).flatMap(\.paths) + extraFolders
    }

    /// Re-scans shortly after something is installed or removed.
    private func watch(_ roots: [String]) {
        watchers.forEach { $0.cancel() }
        watchers = roots.compactMap { root in
            let fd = open(root, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { AppsCatalog.shared.scheduleReload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            return source
        }
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { AppsCatalog.shared.reload() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    nonisolated private static func scan(_ roots: [String]) -> [App] {
        let fm = FileManager.default
        var seenPaths = Set<String>(), seenIDs = Set<String>()
        var result: [App] = []

        func add(_ path: String) {
            guard seenPaths.insert(path).inserted else { return }
            let bundle = Bundle(path: path)
            let info = bundle?.infoDictionary ?? [:]
            // Helpers and agents that live inside app folders aren't apps people open.
            if (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1" { return }
            if (info["LSBackgroundOnly"] as? Bool) == true { return }
            let id = bundle?.bundleIdentifier
            if let id, !seenIDs.insert(id).inserted { return }
            let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
            let bundleName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? name
            var category = Category(uti: info["LSApplicationCategoryType"] as? String)
            if category == .other, path.contains("/Utilities/") { category = .utilities }
            result.append(App(path: path, name: name, bundleName: bundleName, bundleID: id, category: category,
                              isSystem: path.hasPrefix("/System/"),
                              haystack: (name + " " + bundleName).lowercased(),
                              initials: Hangul.initials(name)))
        }

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let path = (root as NSString).appendingPathComponent(entry)
                if entry.hasSuffix(".app") { add(path); continue }
                // One folder deep, the way vendors ship suites ("Adobe Photoshop 2026/…app").
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                      !roots.contains(path),
                      let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for sub in inner where sub.hasSuffix(".app") { add((path as NSString).appendingPathComponent(sub)) }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refreshRunning() {
        let now = Set(NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular ? $0.bundleURL?.path : nil })
        // Setting it, even unchanged, re-lays out the whole grid.
        if now != running { running = now }
    }

    func runningApp(_ app: App) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == app.path }
    }

    // MARK: Use

    func noteUse(_ path: String) {
        var entry = usage[path] ?? [0, 0]
        // One switch-to burst counts once.
        let now = Date().timeIntervalSince1970
        if now - entry[1] > 60 { entry[0] += 1 }
        entry[1] = now
        usage[path] = entry
        usageSave?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { AppsCatalog.shared.saveUsage() } }
        usageSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func saveUsage() {
        Storage.save(usage, to: "app-usage.json")
        if Pref.defaults.object(forKey: "apps.usage") != nil { Pref.defaults.removeObject(forKey: "apps.usage") }
    }

    /// Uses, fading with a two-week half-life since the last one.
    func frecency(_ path: String) -> Double {
        guard let e = usage[path] else { return 0 }
        let days = (Date().timeIntervalSince1970 - e[1]) / 86_400
        return e[0] * pow(0.5, days / 14)
    }

    func frequent(limit: Int) -> [App] {
        let pinnedSet = Set(pinned)
        return apps.filter { !pinnedSet.contains($0.path) && frecency($0.path) > 0.5 }
            .sorted { frecency($0.path) > frecency($1.path) }
            .prefix(limit).map { $0 }
    }

    // MARK: Pins

    var pinnedApps: [App] {
        let byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return pinned.compactMap { byPath[$0] }
    }

    func isPinned(_ app: App) -> Bool { pinned.contains(app.path) }

    func togglePin(_ app: App) {
        if let i = pinned.firstIndex(of: app.path) { pinned.remove(at: i) } else { pinned.append(app.path) }
        Pref.defaults.set(pinned, forKey: "apps.pinned")
    }

    /// Drag-to-reorder within the Pinned row.
    func movePin(_ path: String, before target: String) {
        guard path != target, let from = pinned.firstIndex(of: path) else { return }
        pinned.remove(at: from)
        let to = pinned.firstIndex(of: target) ?? pinned.count
        pinned.insert(path, at: to)
        Pref.defaults.set(pinned, forKey: "apps.pinned")
    }

    // MARK: Search

    func search(_ query: String, in category: Category?) -> [App] {
        let pool = category.map { c in apps.filter { $0.category == c } } ?? apps
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pool }
        let jamoOnly = q.unicodeScalars.allSatisfy { (0x3131...0x314E).contains($0.value) }
        let scored: [(App, Int)] = pool.compactMap { app in
            var best = Fuzzy.score(q, app.name) ?? -1
            if let s = Fuzzy.score(q, app.bundleName) { best = max(best, s - 5) }
            if jamoOnly {
                if app.initials.hasPrefix(q) { best = max(best, 820) }
                else if app.initials.contains(q) { best = max(best, 640) }
            }
            guard best >= 0 else { return nil }
            return (app, best + Int(min(120, frecency(app.path) * 12)))
        }
        // Subsequence hits are noise once something matches properly.
        let top = scored.map(\.1).max() ?? 0
        let floor = top >= 600 ? 400 : 0
        return scored.filter { $0.1 >= floor }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: Icons

    /// Icons and names drawn once into bitmaps at the grid's size, off the main thread. A workspace
    /// icon is drawn afresh by IconServices at every size it's shown at, and as SwiftUI Text every
    /// name was drawn again each time the grid opened: dozens of them on the main thread, and the
    /// grid froze instead of cascading in.
    @ObservationIgnored private var icons: [String: CGImage] = [:]
    @ObservationIgnored private var labels: [String: CGImage] = [:]
    /// The icon size and screen scale the cache is drawn for; a new icon size redraws it all
    /// (keeping the old ones on screen until then).
    @ObservationIgnored private var drawn: (size: Double, scale: CGFloat)?
    @ObservationIgnored private var tilesLoading = false
    /// Bumped when a batch is ready, so the grid picks it up.
    private(set) var tilesVersion = 0

    func icon(_ app: App) -> CGImage? { tile(app, in: icons) }
    func label(_ app: App) -> CGImage? { tile(app, in: labels) }

    private func tile(_ app: App, in cache: [String: CGImage]) -> CGImage? {
        _ = tilesVersion
        if let cached = cache[app.path] { return cached }
        DispatchQueue.main.async { AppsCatalog.shared.warmTiles() } // not while a view is being drawn
        return nil
    }

    /// Draws every icon and name not drawn yet, at the current icon size on the sharpest screen.
    func warmTiles() {
        guard !tilesLoading else { return }
        let size = iconSize, scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let resize = drawn.map { $0.size != size || $0.scale != scale } ?? true
        let missing = apps.filter { resize || icons[$0.path] == nil || labels[$0.path] == nil }.map { ($0.path, $0.name) }
        guard !missing.isEmpty else { return }
        tilesLoading = true
        Task.detached(priority: .userInitiated) {
            var madeIcons: [String: CGImage] = [:], madeLabels: [String: CGImage] = [:]
            let pixels = Int((size * scale).rounded())
            for (path, name) in missing {
                madeIcons[path] = Self.render(path, pixels: pixels)
                madeLabels[path] = TileLabel.render(name, iconSize: size, scale: scale)
            }
            let newIcons = madeIcons, newLabels = madeLabels
            await MainActor.run {
                let catalog = AppsCatalog.shared
                catalog.tilesLoading = false
                if resize {
                    catalog.icons = newIcons
                    catalog.labels = newLabels
                    catalog.drawn = (size, scale)
                } else {
                    catalog.icons.merge(newIcons) { old, _ in old }
                    catalog.labels.merge(newLabels) { old, _ in old }
                }
                catalog.tilesVersion += 1
                catalog.warmTiles() // anything that changed while this batch was drawing
            }
        }
    }

    nonisolated private static func render(_ path: String, pixels: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSWorkspace.shared.icon(forFile: path).draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Korean initial-consonant search: "ㅋㅋㅇㅌ" finds 카카오톡.
enum Hangul {
    private static let choseong: [Character] = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]

    nonisolated static func initials(_ s: String) -> String {
        String(s.unicodeScalars.compactMap { u -> Character? in
            guard (0xAC00...0xD7A3).contains(u.value) else { return nil }
            return choseong[Int((u.value - 0xAC00) / 588)]
        })
    }
}
