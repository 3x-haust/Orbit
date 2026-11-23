import AppKit
import QuickLookThumbnailing

/// The folder the notch's Folder tab shows (Screenshots, say): its files newest first, as
/// thumbnails to drag out. Read again each time the tab appears.
@MainActor @Observable
final class NotchFolder {
    static let shared = NotchFolder()

    struct Entry: Identifiable, Hashable, Sendable {
        let url: URL
        let date: Date
        var id: String { url.path + "|\(date.timeIntervalSinceReferenceDate)" }
        var name: String { url.lastPathComponent }
        /// The file itself, the way the shelf's tiles hand theirs to a drag.
        var provider: NSItemProvider { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
    }

    enum Contents: Equatable {
        case loading
        case files([Entry])
        case empty
        case unreadable
    }

    private(set) var contents: Contents = .loading
    @ObservationIgnored private var loadedPath: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let thumbnails = NSCache<NSString, NSImage>()

    private init() {}

    /// The chosen folder, or nil while none is.
    nonisolated static var url: URL? {
        #if DEBUG
        if let debugURL { return debugURL }
        #endif
        let path = Pref.defaults.string(forKey: NotchPrefs.folderPath) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    #if DEBUG
    /// Promo frames and checks: a folder for this run only, never written to the settings.
    nonisolated(unsafe) static var debugURL: URL?
    #endif

    /// Lists the folder off the main thread. What it showed stays up until the new list is in.
    func reload() {
        guard let folder = Self.url else { contents = .empty; loadedPath = nil; return }
        if loadedPath != folder.path { contents = .loading }
        loadedPath = folder.path
        loadTask?.cancel()
        loadTask = Task {
            let result = await Task.detached(priority: .userInitiated) { Self.list(folder) }.value
            guard !Task.isCancelled, loadedPath == folder.path else { return }
            let next: Contents = result.map { $0.isEmpty ? .empty : .files($0) } ?? .unreadable
            if next != contents { contents = next }
        }
    }

    private nonisolated static func list(_ folder: URL) -> [Entry]? {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { return nil }
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return Entry(url: url, date: v?.creationDate ?? v?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: Thumbnails

    func cachedThumbnail(_ entry: Entry) -> NSImage? { thumbnails.object(forKey: entry.id as NSString) }

    /// Quick Look's picture of the file's content, at `size` points; nil for files without one
    /// (folders, apps), which keep their icon, uncropped.
    func thumbnail(_ entry: Entry, size: CGSize) async -> NSImage? {
        if let cached = cachedThumbnail(entry) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: entry.url, size: size, scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        thumbnails.setObject(image, forKey: entry.id as NSString)
        return image
    }

    // MARK: Actions

    func open(_ entry: Entry) {
        NotchCenter.shared.close()
        NSWorkspace.shared.open(entry.url)
    }

    func reveal(_ url: URL) {
        NotchCenter.shared.close()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The picture and the file, so it pastes into chats as an image and into Finder as a file.
    func copy(_ entry: Entry) {
        NSPasteboard.general.clearContents()
        if let type = try? entry.url.resourceValues(forKeys: [.contentTypeKey]).contentType, type.conforms(to: .image),
           let image = NSImage(contentsOf: entry.url) {
            NSPasteboard.general.writeObjects([image, entry.url as NSURL])
        } else {
            NSPasteboard.general.writeObjects([entry.url as NSURL])
        }
        ClipboardStore.shared.markOwnWrite()
        Toast.show("Copied")
    }

    /// A drag over the notch that came out of this folder (one of its own tiles): not a drop for
    /// the shelf.
    static func isOwnDrag(_ pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        guard let folder = url?.standardizedFileURL,
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        return urls.allSatisfy { $0.standardizedFileURL.deletingLastPathComponent().path == folder.path }
    }
}
