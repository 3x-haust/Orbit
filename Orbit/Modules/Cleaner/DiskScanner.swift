import AppKit
import Foundation

/// Allocated on-disk sizes, measured without following symlinks. Safe to call off the main thread.
enum DiskSize {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Folders the scanner never reads: personal data that isn't "storage to clean", and
    /// locations macOS guards with privacy prompts.
    static let protected: [String] = [
        "Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Keychains",
        "Library/Containers", "Library/Group Containers", "Library/Photos", "Library/Safari",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC", "Library/Calendars", "Library/Cookies",
    ].map { home.appendingPathComponent($0).path }

    static func isProtected(_ url: URL) -> Bool { isProtected(path: url.standardizedFileURL.path) }

    static func isProtected(path: String) -> Bool {
        if path.hasSuffix(".photoslibrary") || path.contains(".photoslibrary/") { return true }
        return protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Total allocated bytes of a file or folder. `skip` paths (and protected ones) aren't descended.
    /// Uses fts with physical traversal: never follows symlinks, and it's several times faster than URL enumeration.
    static func of(_ url: URL, skip: Set<String> = [], guarded: Bool = true) -> Int64 {
        let path = url.standardizedFileURL.path
        var total: Int64 = 0
        path.withCString { cPath in
            var roots: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(roots[0]) }
            guard let stream = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
            defer { fts_close(stream) }
            var seen = 0
            while let entry = fts_read(stream) {
                seen += 1
                if seen & 0xFFF == 0, Task.isCancelled { break }
                let info = Int32(entry.pointee.fts_info)
                if info == FTS_D {
                    if entry.pointee.fts_level > 0, !skip.isEmpty || guarded {
                        let p = String(cString: entry.pointee.fts_path)
                        if skip.contains(p) || (guarded && isProtected(path: p)) {
                            fts_set(stream, entry, FTS_SKIP)
                            continue
                        }
                    }
                    continue
                }
                guard info == FTS_F || info == FTS_DP || info == FTS_SL || info == FTS_DEFAULT,
                      let stat = entry.pointee.fts_statp else { continue }
                // Hard-linked files would be counted per link; good enough for a usage overview.
                total += Int64(stat.pointee.st_blocks) * 512
            }
        }
        return total
    }

    static func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    }
}

extension Int64 {
    /// Disk-style (base-10, like Finder) byte counts.
    var diskBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// What's filling the startup disk, by broad category.
enum StorageCategory: String, CaseIterable, Identifiable {
    case apps, documents, media, developer, caches, trash, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Applications"
        case .documents: "Documents"
        case .media: "Photos, Music & Movies"
        case .developer: "Developer"
        case .caches: "Caches & Logs"
        case .trash: "Trash"
        case .other: "System & Other"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .documents: "doc"
        case .media: "photo.on.rectangle"
        case .developer: "hammer"
        case .caches: "archivebox"
        case .trash: "trash"
        case .other: "internaldrive"
        }
    }

    /// Shades of ink, strongest first; the accent is kept for what can be cleaned.
    var shade: Double {
        switch self {
        case .apps: 1
        case .documents: 0.78
        case .media: 0.6
        case .developer: 0.45
        case .caches: 0.32
        case .trash: 0.22
        case .other: 0.12
        }
    }

    static let packageCaches = ["Library/Caches/CocoaPods", "Library/Caches/Homebrew", "Library/Caches/pip", "Library/Caches/Yarn", "Library/Caches/pnpm"]

    var paths: [URL] {
        let h = DiskSize.home
        func p(_ s: String) -> URL { h.appendingPathComponent(s) }
        switch self {
        case .apps: return [URL(fileURLWithPath: "/Applications"), p("Applications")]
        case .documents: return [p("Documents"), p("Desktop"), p("Downloads")]
        case .media: return [p("Pictures"), p("Music"), p("Movies")]
        case .developer:
            return [p("Library/Developer"), p(".npm"), p(".gradle"), p(".cache"), p(".cargo"), p(".pub-cache"),
                    p(".cocoapods"), p(".m2"), p(".bun"), p(".rustup")] + Self.packageCaches.map(p)
        case .caches: return [p("Library/Caches"), p("Library/Logs")]
        case .trash: return [p(".Trash")]
        case .other: return []
        }
    }

    /// Paths another category already counts.
    var skip: Set<String> {
        self == .caches ? Set(Self.packageCaches.map { DiskSize.home.appendingPathComponent($0).path }) : []
    }
}

struct DiskInfo: Equatable {
    var total: Int64 = 0
    var available: Int64 = 0
    var used: Int64 { max(0, total - available) }

    static func read() -> DiskInfo {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DiskInfo(total: Int64(v?.volumeTotalCapacity ?? 0), available: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
