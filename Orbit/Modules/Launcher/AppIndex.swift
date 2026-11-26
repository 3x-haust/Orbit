import AppKit
import Observation

/// Installed applications, indexed in the background and refreshed when /Applications changes.
@MainActor @Observable
final class AppIndex {
    static let shared = AppIndex()

    struct App: Hashable, Sendable {
        /// As Finder shows it, in the user's language ("홈" for Home.app on a Korean Mac).
        let name: String
        let path: String
        /// The app's other names: its file name and the unlocalized bundle names ("Home", "KakaoTalk").
        var aliases: [String] = []
        /// Korean initials of `name` ("카카오톡" → "ㅋㅋㅇㅌ").
        var initials = ""

        /// How well a launcher query matches any of the app's names; nil = no match.
        func score(_ query: String) -> Int? {
            var best = Fuzzy.score(query, name)
            for alias in aliases {
                if let s = Fuzzy.score(query, alias) { best = max(best ?? .min, s - 5) }
            }
            if query.unicodeScalars.allSatisfy({ (0x3131...0x314E).contains($0.value) }) {
                if initials.hasPrefix(query) { best = max(best ?? .min, 820) }
                else if initials.contains(query) { best = max(best ?? .min, 640) }
            }
            return best
        }
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
                let info = Bundle(path: path)?.infoDictionary ?? [:]
                var aliases: [String] = []
                for other in [String(entry.dropLast(4)), info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String] {
                    guard let other, !other.isEmpty, other.lowercased() != name.lowercased(),
                          !aliases.contains(where: { $0.lowercased() == other.lowercased() }) else { continue }
                    aliases.append(other)
                }
                result.append(App(name: name, path: path, aliases: aliases, initials: Hangul.initials(name)))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
