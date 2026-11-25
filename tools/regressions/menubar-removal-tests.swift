import AppKit
@testable import Orbit

/// Checks the hidden icons Orbit lists while hiding by switching icons off: what MenuBarAgent's
/// tracked list can hold never takes Orbit down or hangs it, and Orbit's own icons are never
/// taken for an app to switch off.
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

        exit(failed == 0 ? 0 : 1)
    }
}

private final class LockedResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String??
    var value: String?? { lock.withLock { stored } }
    func set(_ value: String?) { lock.withLock { stored = .some(value) } }
}
