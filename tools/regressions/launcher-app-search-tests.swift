import AppKit
@testable import Orbit

/// Finds installed apps through the launcher by names other than the one Finder shows: on a Korean
/// Mac Home.app shows as "홈", yet "home" has to find it too. Apps that aren't installed are skipped.
@main struct LauncherAppSearchTests {
    @MainActor static func main() {
        AppIndex.shared.reload()
        let deadline = Date().addingTimeInterval(10)
        while AppIndex.shared.apps.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard !AppIndex.shared.apps.isEmpty else { print("FAIL app index stayed empty"); exit(1) }

        let model = LauncherModel()
        var failed = 0, ran = 0
        func check(_ query: String, finds path: String) {
            guard FileManager.default.fileExists(atPath: path) else { print("SKIP \(query): \(path) not installed"); return }
            ran += 1
            model.query = query
            model.refresh()
            let apps = model.items.filter { $0.id.hasPrefix("app.") }
            let ok = apps.contains { $0.id == "app.\(path)" }
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \"\(query)\" finds \(path) (apps: \(apps.map(\.title)))")
        }

        check("home", finds: "/System/Applications/Home.app")
        check("Home", finds: "/System/Applications/Home.app")
        check("홈", finds: "/System/Applications/Home.app")
        check("calendar", finds: "/System/Applications/Calendar.app")
        check("system settings", finds: "/System/Applications/System Settings.app")
        check("ㅅㅅㅌ", finds: "/System/Applications/System Settings.app")
        check("kakao", finds: "/Applications/KakaoTalk.app")
        check("카카오", finds: "/Applications/KakaoTalk.app")
        check("ㅋㅋㅇㅌ", finds: "/Applications/KakaoTalk.app")
        check("hwp", finds: "/Applications/Hancom Office HWP.app")
        check("zoom", finds: "/Applications/zoom.us.app")

        print("\(failed) of \(ran) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
