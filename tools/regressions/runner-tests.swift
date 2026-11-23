import AppKit
@testable import Orbit

/// Checks the colors of the runner's menu bar percentage, and that the runner's own color
/// isn't left dimmed after the menu bar showed it faded for a moment.
@main struct RunnerTests {
    @MainActor static func main() async {
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        typealias Load = MenuBarRunner.Load
        for source in [MenuBarRunner.Source.cpu, .gpu] {
            check(Load(percent: 0, source: source) == .low, "\(source) 0% is green")
            check(Load(percent: 59, source: source) == .low, "\(source) 59% is green")
            check(Load(percent: 60, source: source) == .busy, "\(source) 60% is orange")
            check(Load(percent: 79, source: source) == .busy, "\(source) 79% is orange")
            check(Load(percent: 80, source: source) == .high, "\(source) 80% is red")
            check(Load(percent: 100, source: source) == .high, "\(source) 100% is red")
        }
        check(Load(percent: 79, source: .memory) == .low, "memory 79% is green")
        check(Load(percent: 80, source: .memory) == .busy, "memory 80% is orange")
        check(Load(percent: 94, source: .memory) == .busy, "memory 94% is orange")
        check(Load(percent: 95, source: .memory) == .high, "memory 95% is red")
        check(Load.low.color != Load.busy.color && Load.busy.color != Load.high.color, "each step has its own color")

        // A real menu bar item, as after waking from sleep: the menu bar's appearance comes back while
        // the item is still drawn faded, then the fading ends with no further appearance change.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain([Pref.runnerEnabled: true, Pref.runnerShowPercent: false, Pref.runnerAccent: false],
                                                forName: UserDefaults.argumentDomain)
        let runner = MenuBarRunner.shared
        runner.start()
        try? await Task.sleep(for: .milliseconds(800))
        if let button = runner.button {
            func alpha() -> CGFloat {
                button.layer?.sublayers?.last?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.alphaComponent } ?? -1
            }
            let full = alpha()
            button.alphaValue = 0.36
            button.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(500))
            button.appearance = nil
            try? await Task.sleep(for: .milliseconds(500))
            button.alphaValue = 1
            try? await Task.sleep(for: .seconds(1))
            print(String(format: "runner glyph alpha %.2f, after fading %.2f", full, alpha()))
            check(full > 0 && abs(alpha() - full) < 0.02, "runner keeps its full color after the menu bar faded it")
        } else {
            check(false, "runner keeps its full color after the menu bar faded it (no menu bar item)")
        }
        exit(failed == 0 ? 0 : 1)
    }
}
