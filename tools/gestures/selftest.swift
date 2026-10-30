// Runs the trackpad recognizer's self-test outside the app:
//   swiftc -D DEBUG Orbit/Modules/Gestures/TouchRecognizer.swift tools/gestures/selftest.swift -o /tmp/gesture-selftest && /tmp/gesture-selftest
import Foundation

@main
struct GestureSelfTest {
    static func main() {
        let lines = TouchRecognizer.selfTest()
        lines.forEach { print($0) }
        let failed = lines.filter { $0.hasPrefix("FAIL") }.count
        print(failed == 0 ? "all \(lines.count) passed" : "\(failed) of \(lines.count) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
