import AppKit
import Foundation

/// Finds what can go. Everything here only reads; removal happens in StorageModel after the user confirms.
enum Cleanup {
    private static var home: URL { DiskSize.home }
    private static let ninetyDays: TimeInterval = 90 * 86_400
    private static let largeFile: Int64 = 500_000_000

    static func find(_ kind: CleanupGroup.Kind, running: Set<String>) -> CleanupGroup {
        let items: [CleanupItem]
        switch kind {
        case .caches: items = caches(running: running)
        case .logs: items = children(of: home.appendingPathComponent("Library/Logs"), selected: true)
        case .xcode: items = xcode()
        case .packages: items = packages()
        case .downloads: items = oldDownloads()
        case .large: items = largeFiles()
        }
        return CleanupGroup(kind: kind, items: items.filter { $0.size > 0 }.sorted { $0.size > $1.size })
    }

    /// Roots the cleaner looks inside but must never remove themselves.
    private static let roots: Set<String> = [
        "Library", "Library/Caches", "Library/Logs", "Library/Developer", "Library/Developer/Xcode",
        "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Documents", "Desktop",
        "Downloads", "Pictures", "Music", "Movies", "Applications", ".Trash", ".cache", ".npm", ".gradle",
    ]

    /// Only things inside the home folder, never symlinks, never protected personal data.
    nonisolated static func isSafeToRemove(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/") else { return false }
        let relative = String(path.dropFirst(home.path.count + 1))
        guard !relative.isEmpty, !roots.contains(relative),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              !DiskSize.isProtected(url) else { return false }
        return true
    }

    // MARK: Groups

    private static func caches(running: Set<String>) -> [CleanupItem] {
        let root = home.appendingPathComponent("Library/Caches")
        let packageNames = Set(StorageCategory.packageCaches.map { ($0 as NSString).lastPathComponent })
        return children(of: root, selected: true) { url in
            let name = url.lastPathComponent
            let lower = name.lowercased()
            // Apple's own caches are mostly locked by the system; package caches have their own group.
            return !lower.hasPrefix("com.apple.") && !packageNames.contains(name) && !running.contains(lower)
                && !["cloudkit", "familycircle", "com.apple.ap.adprivacyd"].contains(lower)
        }
    }

    private static func xcode() -> [CleanupItem] {
        let dev = home.appendingPathComponent("Library/Developer")
        var items: [CleanupItem] = []
        let derived = dev.appendingPathComponent("Xcode/DerivedData")
        items += children(of: derived, selected: true)
        let archives = dev.appendingPathComponent("Xcode/Archives")
        // Archives are grouped by day folders; keep anything recent.
        items += children(of: archives, selected: true) { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return Date().timeIntervalSince(date) > ninetyDays
        }
        let simCaches = dev.appendingPathComponent("CoreSimulator/Caches")
        if DiskSize.exists(simCaches) { items.append(item(simCaches, name: "Simulator caches".loc, selected: true)) }
        let deviceSupport = dev.appendingPathComponent("Xcode/iOS DeviceSupport")
        items += children(of: deviceSupport, selected: false)
        return items
    }

    private static func packages() -> [CleanupItem] {
        let fixed: [(String, String, Bool)] = [
            (".npm/_cacache", "npm", true), ("Library/Caches/Homebrew", "Homebrew", true),
            ("Library/Caches/CocoaPods", "CocoaPods", true), (".gradle/caches", "Gradle", true),
            ("Library/Caches/pip", "pip", true), ("Library/Caches/Yarn", "Yarn", true),
            ("Library/Caches/pnpm", "pnpm", true), (".cargo/registry/cache", "Cargo", true),
            (".pub-cache/hosted", "Dart / Flutter pub", false), (".m2/repository", "Maven", false),
        ]
        var items = fixed.compactMap { rel, name, on -> CleanupItem? in
            let url = home.appendingPathComponent(rel)
            return DiskSize.exists(url) ? item(url, name: name, selected: on) : nil
        }
        // ~/.cache mixes tool caches with downloaded models; each is listed, none pre-checked.
        items += children(of: home.appendingPathComponent(".cache"), selected: false).map {
            CleanupItem(url: $0.url, name: "~/.cache/" + $0.name, size: $0.size, date: $0.date, selected: false)
        }
        return items
    }

    private static func oldDownloads() -> [CleanupItem] {
        let root = home.appendingPathComponent("Downloads")
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey, .addedToDirectoryDateKey, .isSymbolicLinkKey]
        guard let list = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return list.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { return nil }
            let last = [v.contentAccessDate, v.contentModificationDate, v.addedToDirectoryDate].compactMap { $0 }.max() ?? Date()
            guard Date().timeIntervalSince(last) > ninetyDays else { return nil }
            return CleanupItem(url: url, name: url.lastPathComponent, size: DiskSize.of(url), date: last, selected: false)
        }
    }

    /// Asks the Spotlight index instead of walking the whole home folder — seconds instead of minutes
    /// on a disk full of VM and container images.
    private static func largeFiles() -> [CleanupItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", home.path, "kMDItemFSSize >= \(largeFile)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let skipTop = ["Library", ".Trash", "Applications"].map { home.appendingPathComponent($0).path + "/" }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let found = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> CleanupItem? in
            let path = String(line)
            // Skip system-ish folders and the insides of bundles (apps, libraries count as one thing).
            guard !skipTop.contains(where: path.hasPrefix),
                  !path.contains(".app/"), !path.contains(".bundle/"), !path.contains(".photoslibrary/") else { return nil }
            let url = URL(fileURLWithPath: path)
            guard !DiskSize.isProtected(url), let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isSymbolicLink != true, v.isRegularFile == true,
                  let size = v.totalFileAllocatedSize, Int64(size) >= largeFile else { return nil }
            return CleanupItem(url: url, name: url.lastPathComponent, size: Int64(size), date: v.contentModificationDate, selected: false)
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(30))
    }

    // MARK: Helpers

    private static func children(of root: URL, selected: Bool, where keep: (URL) -> Bool = { _ in true }) -> [CleanupItem] {
        guard let list = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [] }
        return list.filter { url in
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                && url.lastPathComponent != ".DS_Store" && keep(url)
        }
        .map { item($0, selected: selected) }
    }

    private static func item(_ url: URL, name: String? = nil, selected: Bool) -> CleanupItem {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return CleanupItem(url: url, name: name ?? url.lastPathComponent, size: DiskSize.of(url), date: date, selected: selected)
    }

    // MARK: Apps

    static func installedApps() -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), home.appendingPathComponent("Applications")]
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            guard let list = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for url in list where url.pathExtension == "app" && seen.insert(url.path).inserted {
                let bundle = Bundle(url: url)
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                apps.append(InstalledApp(url: url, name: name, bundleID: bundle?.bundleIdentifier))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
