import AppKit
import Observation

/// Installed applications, indexed in the background and refreshed when /Applications changes.
@MainActor @Observable
final class AppIndex {
    static let shared = AppIndex()

    struct App: Hashable, Sendable {
        let name: String
        let path: String
    }

    private(set) var apps: [App] = []
    private var watchers: [DispatchSourceFileSystemObject] = []

    nonisolated private static let roots = [
        "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications",
    ]

    func start() {
        reload()
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let fd = open(root, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { AppIndex.shared.reload() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    func reload() {
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run { AppIndex.shared.apps = found }
        }
    }

    nonisolated private static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [App] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                guard seen.insert(name).inserted else { continue }
                result.append(App(name: name, path: path))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
