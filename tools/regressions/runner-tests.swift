import AppKit
@testable import Orbit

/// Checks the colors of the runner's menu bar percentage.
@main struct RunnerTests {
    @MainActor static func main() {
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
        exit(failed == 0 ? 0 : 1)
    }
}
