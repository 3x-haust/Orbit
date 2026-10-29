import AppKit
import Foundation
import SwiftUI

/// One removable thing a cleanup group found.
struct CleanupItem: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    var date: Date?
    var selected: Bool
}

struct CleanupGroup: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case caches, logs, xcode, packages, downloads, large }
    let kind: Kind
    var items: [CleanupItem]
    var id: Kind { kind }

    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }

    var title: String {
        switch kind {
        case .caches: "App caches"
        case .logs: "Logs"
        case .xcode: "Xcode leftovers"
        case .packages: "Package manager caches"
        case .downloads: "Old downloads"
        case .large: "Large files"
        }
    }

    var detail: String {
        switch kind {
        case .caches: "Apps rebuild these as needed. Caches of running apps are left alone."
        case .logs: "Diagnostic logs apps wrote over time."
        case .xcode: "DerivedData, Archives older than 90 days and simulator caches."
        case .packages: "npm, Homebrew, CocoaPods, Gradle and pip download caches."
        case .downloads: "Untouched for 90 days. Review before removing."
        case .large: "Files over 500 MB in your home folder. Review before removing."
        }
    }

    var symbol: String {
        switch kind {
        case .caches: "archivebox"
        case .logs: "doc.text"
        case .xcode: "hammer"
        case .packages: "shippingbox"
        case .downloads: "arrow.down.circle"
        case .large: "externaldrive.badge.exclamationmark"
        }
    }

    /// Review groups start unchecked — they may hold things the user still wants.
    var needsReview: Bool { kind == .downloads || kind == .large }
}

struct InstalledApp: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String?
    var size: Int64?
    var lastUsed: Date?
}

/// Drives the Storage page: disk usage by category, cleanup suggestions, installed apps.
@MainActor @Observable
final class StorageModel {
    static let shared = StorageModel()

    enum Phase: Equatable { case idle, scanning, done }

    private(set) var disk = DiskInfo.read()
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var usage: [StorageCategory: Int64] = [:]
    var groups: [CleanupGroup] = []
    private(set) var trashSize: Int64?
    private(set) var apps: [InstalledApp] = []
    private(set) var cleaning = false
    private(set) var lastScan: Date?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var appsTask: Task<Void, Never>?

    var selectedSize: Int64 { groups.reduce(0) { $0 + $1.selectedSize } }
    var selectedCount: Int { groups.reduce(0) { $0 + $1.items.filter(\.selected).count } }
    var cleanableSize: Int64 { groups.filter { !$0.needsReview }.reduce(0) { $0 + $1.size } }

    // MARK: Analyze (what's using the disk)

    /// The disk breakdown is remembered across launches: the page opens with the last result, and
    /// Orbit quietly measures again in the background once per launch.
    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("storage-usage.json")
    }

    private struct Cache: Codable {
        var usage: [String: Int64]
        var date: Date
    }

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            for (k, v) in cache.usage { if let c = StorageCategory(rawValue: k) { usage[c] = v } }
            trashSize = usage[.trash]
            lastScan = cache.date
            phase = .done
        }
    }

    private func saveCache() {
        let cache = Cache(usage: Dictionary(uniqueKeysWithValues: usage.map { ($0.key.rawValue, $0.value) }), date: lastScan ?? Date())
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }

    /// Once per launch, a little after start-up: refresh the breakdown without being asked.
    /// Skipped while the saved breakdown is still fresh; the Storage page's 검사 always rescans.
    func refreshInBackground() {
        guard phase != .scanning else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < 6 * 3600 { return }
        scan(quiet: true)
    }

    func scan(quiet: Bool = false) {
        scanTask?.cancel()
        disk = DiskInfo.read()
        phase = .scanning
        progress = 0
        let measured = StorageCategory.allCases.filter { $0 != .other }
        let steps = Double(measured.count)

        scanTask = Task {
            var done = 0.0
            var fresh: [StorageCategory: Int64] = [:]
            await withTaskGroup(of: (StorageCategory, Int64).self) { group in
                // A quiet re-scan walks one folder at a time at background priority, so it never
                // takes over the cores while you're working; the one you ask for runs them all at once.
                var pending = measured[...]
                func next() {
                    guard let category = pending.popFirst() else { return }
                    group.addTask(priority: quiet ? .background : .userInitiated) {
                        (category, category.paths.reduce(Int64(0)) { $0 + DiskSize.of($1, skip: category.skip) })
                    }
                }
                for _ in 0..<(quiet ? 1 : measured.count) { next() }
                for await (category, size) in group {
                    next()
                    guard !Task.isCancelled else { continue }
                    done += 1
                    fresh[category] = size
                    // A first scan fills in as it goes; a re-scan swaps in the new numbers at the end.
                    if usage.isEmpty || !quiet { usage[category] = size }
                    withAnimation(.easeOut(duration: 0.3)) { progress = done / steps }
                }
            }
            guard !Task.isCancelled else { return }
            let known = fresh.values.reduce(0, +)
            fresh[.other] = max(0, disk.used - known)
            withAnimation(.spring(duration: 0.5, bounce: 0.12)) { usage = fresh }
            trashSize = usage[.trash]
            lastScan = Date()
            saveCache()
            withAnimation(.spring(duration: 0.5, bounce: 0.15)) { phase = .done }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        withAnimation(.spring(duration: 0.3)) { phase = lastScan == nil ? .idle : .done }
    }

    // MARK: Find (what can be cleaned)

    private(set) var findPhase: Phase = .idle
    private(set) var findProgress: Double = 0
    private(set) var lastFind: Date?
    @ObservationIgnored private var findTask: Task<Void, Never>?

    func findCleanable() {
        findTask?.cancel()
        findPhase = .scanning
        findProgress = 0
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).map { $0.lowercased() })
        let kinds = CleanupGroup.Kind.allCases
        findTask = Task {
            var done = 0.0
            var found: [CleanupGroup] = []
            await withTaskGroup(of: CleanupGroup.self) { group in
                for kind in kinds { group.addTask { Cleanup.find(kind, running: running) } }
                for await g in group {
                    guard !Task.isCancelled else { continue }
                    done += 1
                    if !g.items.isEmpty { found.append(g) }
                    withAnimation(.easeOut(duration: 0.3)) { findProgress = done / Double(kinds.count) }
                }
            }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.4, bounce: 0.12)) {
                groups = found.sorted { $0.kind.order < $1.kind.order }
                findPhase = .done
            }
            lastFind = Date()
            if MainWindow.shared.router.page != .storage || NSApp.keyWindow == nil {
                Toast.show("Cleanup check finished", symbol: "sparkles",
                           detail: "%@ can be cleaned up".loc(Double(cleanableSize).orbitBytes))
            }
        }
    }

    func cancelFind() {
        findTask?.cancel()
        findTask = nil
        withAnimation(.spring(duration: 0.3)) { findPhase = lastFind == nil ? .idle : .done }
    }

    // MARK: Selection

    func toggle(_ kind: CleanupGroup.Kind, item: String? = nil) {
        guard let g = groups.firstIndex(where: { $0.kind == kind }) else { return }
        if let item, let i = groups[g].items.firstIndex(where: { $0.id == item }) {
            groups[g].items[i].selected.toggle()
        } else {
            let on = !groups[g].items.allSatisfy(\.selected)
            for i in groups[g].items.indices { groups[g].items[i].selected = on }
        }
    }

    // MARK: Clean

    func cleanSelected() {
        let items = groups.flatMap { $0.items.filter(\.selected) }
        guard !items.isEmpty, !cleaning else { return }
        let total = items.reduce(0) { $0 + $1.size }

        let alert = NSAlert()
        alert.messageText = "Move %ld items to the Trash?".loc(items.count)
        alert.informativeText = "This frees up about %@. You can still restore them from the Trash until you empty it.".loc(total.diskBytes)
        alert.addButton(withTitle: "Move to Trash".loc)
        alert.addButton(withTitle: "Cancel".loc)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let urls = items.map(\.url).filter(Cleanup.isSafeToRemove)
        cleaning = true
        Task {
            var moved = Set<String>()
            // One at a time so a single locked file doesn't abort the rest.
            for url in urls {
                if (try? await NSWorkspace.shared.recycle([url])) != nil { moved.insert(url.path) }
            }
            let freed = items.filter { moved.contains($0.url.path) }.reduce(0) { $0 + $1.size }
            withAnimation(.spring(duration: 0.4)) {
                for g in groups.indices { groups[g].items.removeAll { moved.contains($0.url.path) } }
                groups.removeAll { $0.items.isEmpty }
            }
            cleaning = false
            disk = DiskInfo.read()
            let skipped = urls.count - moved.count + (items.count - urls.count)
            Toast.show("Moved %@ to the Trash".loc(freed.diskBytes), symbol: "trash.fill",
                       detail: skipped > 0 ? "%ld items were in use and skipped".loc(skipped) : "Empty the Trash to free the space".loc)
            usage[.trash] = (usage[.trash] ?? 0) + freed
            trashSize = usage[.trash]
        }
    }

    func emptyTrash() {
        SystemActions.emptyTrash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.disk = DiskInfo.read()
            let size = DiskSize.of(DiskSize.home.appendingPathComponent(".Trash"))
            self.usage[.trash] = size
            self.trashSize = size
        }
    }

    // MARK: Apps

    func loadApps() {
        guard appsTask == nil else { return }
        let found = Cleanup.installedApps()
        apps = found
        appsTask = Task {
            await withTaskGroup(of: (String, Int64, Date?).self) { group in
                for app in found {
                    group.addTask {
                        let size = DiskSize.of(app.url, guarded: false)
                        let used = NSMetadataItem(url: app.url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
                        return (app.id, size, used)
                    }
                }
                for await (id, size, used) in group {
                    if let i = apps.firstIndex(where: { $0.id == id }) {
                        apps[i].size = size
                        apps[i].lastUsed = used
                    }
                }
            }
            withAnimation(.spring(duration: 0.4)) { apps.sort { ($0.size ?? 0) > ($1.size ?? 0) } }
            appsTask = nil
        }
    }

    func reloadApps() {
        appsTask?.cancel()
        appsTask = nil
        loadApps()
    }

    func appRemoved(_ url: URL) {
        withAnimation(.spring(duration: 0.4)) { apps.removeAll { $0.url.path == url.path } }
        disk = DiskInfo.read()
    }
}

extension CleanupGroup.Kind {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
