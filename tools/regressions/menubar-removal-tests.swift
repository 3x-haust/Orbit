import AppKit
@testable import Orbit

/// Checks the hidden icons Orbit lists while hiding by switching icons off: what MenuBarAgent's
/// tracked list can hold never takes Orbit down or hangs it, Orbit's own icons are never taken for
/// an app to switch off, an icon whose label changed is listed once, and an app that isn't running
/// isn't listed.
@main struct MenuBarRemovalTests {
    @MainActor static func main() async {
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }

        // MenuBarAgent's tracked list names some apps by location. Each of these is read off the main
        // thread with a deadline: a lookup that never returns fails instead of hanging the run.
        func lookup(_ location: String) async -> String?? {
            let result = LockedResult()
            Thread.detachNewThread { result.set(MenuBarAgentPrefs.bundleID(of: ["location": location])) }
            for _ in 0..<40 {
                if let value = result.value { return value }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        check(await lookup("file:///System/Applications/Calculator.app") == .some("com.apple.calculator"), "an app bundle by path")
        check(await lookup("file:///System/Applications/Calculator.app/Contents/MacOS/Calculator") == .some("com.apple.calculator"),
              "a binary inside an app bundle")
        check(await lookup("file:///.file/id=6571367.1234") == .some(nil), "a file reference URL is no app, and no exception")
        check(await lookup("file://") == .some(nil), "an empty file URL is no app, and returns")
        check(await lookup("file://localhost") == .some(nil), "a file URL with only a host is no app, and returns")

        // Orbit's own icons carry the id prefix of its first bundle id, whatever Orbit's bundle id is now.
        let own = MenuBarRemoval.bundleID(ofItem: MenuBarItems.toggleID)
        check(!MenuBarRemoval.switchable(own), "Orbit's own icons aren't an app to switch off")
        check(!MenuBarRemoval.switchable(Bundle.main.bundleIdentifier ?? own), "Orbit's bundle isn't an app to switch off")
        check(MenuBarRemoval.switchable("com.kakao.KakaoTalkMac"), "another app is")

        // What earlier builds kept: Orbit's own icons, one app's icon under three labels it once had,
        // an app that isn't running, and one of macOS's own.
        typealias Removed = MenuBarRemoval.Removed
        let counter = "com.example.counter", finder = "com.apple.finder", gone = "com.example.gone"
        let kept: [String: Removed] = [
            MenuBarItems.toggleID: Removed(bundleID: own, name: "Orbit button", section: "hidden", order: 1),
            "\(own)|runner": Removed(bundleID: own, name: "Runner", section: "hidden", order: 2),
            "\(counter)|": Removed(bundleID: counter, name: "Counter", section: "hidden", order: 3),
            "\(counter)| ●4": Removed(bundleID: counter, name: "Counter", section: "hidden", order: 4),
            "\(counter)| ▶︎3 ●5": Removed(bundleID: counter, name: "Counter", section: "always", order: 5),
            "\(finder)|": Removed(bundleID: finder, name: "Finder", section: "hidden", order: 6),
            "\(gone)|": Removed(bundleID: gone, name: "Gone", section: "hidden", order: 7),
            "com.apple.systemuiserver|VPN": Removed(bundleID: "com.apple.systemuiserver", name: "VPN", section: "hidden", order: 8,
                                                     system: "extra:/System/Library/CoreServices/Menu Extras/VPN.menu"),
        ]
        let defaults = UserDefaults.standard
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(arguments.merging(["menubar.removed": try! JSONEncoder().encode(kept)]) { $1 },
                                   forName: UserDefaults.argumentDomain)
        let removal = MenuBarRemoval.shared
        check(!removal.removed.keys.contains { $0.hasPrefix(own + "|") }, "Orbit's own icons kept by an earlier build are dropped")

        // The app lists the one icon it has now, under yet another label.
        removal.follow([counter: [(id: "\(counter)| ▶︎1 ●5", name: "Counter")], finder: [(id: "\(finder)|", name: "Finder")]])
        let counters = removal.removed.filter { $0.value.bundleID == counter }
        check(counters.keys.sorted() == ["\(counter)| ▶︎1 ●5"], "an icon whose label changed is kept once, under its label now")
        check(counters.values.first?.section == "hidden" && counters.values.first?.order == 3, "in the section and place its app had")
        check(removal.removed["\(finder)|"] == kept["\(finder)|"], "an app whose icons are unchanged keeps its entry")
        removal.follow(["com.example.visible": [(id: "com.example.visible|", name: "Visible")]])
        check(removal.removed["com.example.visible|"] == nil, "an app the user didn't hide isn't added")

        let listed = Set(removal.listable.keys)
        check(listed.contains("\(finder)|"), "a running app's icon is listed")
        check(!listed.contains("\(gone)|") && removal.removed["\(gone)|"] != nil, "an app that isn't running isn't listed, and is still kept")
        check(listed.contains("com.apple.systemuiserver|VPN"), "macOS's own switched-off icon is listed")
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defaults.removeObject(forKey: "menubar.removed")

        exit(failed == 0 ? 0 : 1)
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String??
    var value: String?? { lock.withLock { stored } }
    func set(_ value: String?) { lock.withLock { stored = .some(value) } }
}
