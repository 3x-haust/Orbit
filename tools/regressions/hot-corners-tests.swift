import AppKit
@testable import Orbit

/// Checks which hot corner the pointer is in, on display layouts given as frames in AppKit's
/// screen coordinates. The pointer's points follow `NSEvent.mouseLocation`: x runs from a
/// display's minX up to (not including) maxX, y from just above minY up to maxY.
@main struct HotCornersTests {
    @MainActor static func main() {
        var failed = 0
        func check(_ point: CGPoint, on screens: [CGRect], is expected: HotCorners.Corner?, _ name: String) {
            let found = HotCorners.corner(at: point, screens: screens)
            let ok = found == expected
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name) (expected \(expected?.rawValue ?? "none"), got \(found?.rawValue ?? "none"))")
        }

        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        check(CGPoint(x: 0, y: 982), on: [laptop], is: .topLeft, "one display: top left")
        check(CGPoint(x: 1511, y: 982), on: [laptop], is: .topRight, "one display: top right")
        check(CGPoint(x: 0, y: 1), on: [laptop], is: .bottomLeft, "one display: bottom left")
        check(CGPoint(x: 1511, y: 1), on: [laptop], is: .bottomRight, "one display: bottom right")
        check(CGPoint(x: 756, y: 1), on: [laptop], is: nil, "one display: bottom edge, no corner")

        // A second display whose top-left corner touches the laptop's bottom-right one diagonally.
        let below = CGRect(x: 1512, y: -1200, width: 1920, height: 1200)
        let diagonal = [laptop, below]
        check(CGPoint(x: 1511, y: 1), on: diagonal, is: .bottomRight, "diagonal displays: laptop's bottom right")
        check(CGPoint(x: 1512, y: 0), on: diagonal, is: .topLeft, "diagonal displays: second display's top left")
        check(CGPoint(x: 1513, y: -2), on: diagonal, is: .topLeft, "diagonal displays: just inside the second display's top left")
        check(CGPoint(x: 1509, y: 3), on: diagonal, is: .bottomRight, "diagonal displays: just inside the laptop's bottom right")

        // A display beside the laptop: their shared edge has no corners the pointer stops at.
        let beside = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        check(CGPoint(x: 1511, y: 1), on: [laptop, beside], is: nil, "side by side: laptop's bottom right runs on")
        check(CGPoint(x: 3431, y: 1), on: [laptop, beside], is: .bottomRight, "side by side: outer bottom right")

        // Notification Center: a press that timed out may still have opened the panel, so the clock
        // must not be pressed again (a second press closes it). Only a refused press tries the next one.
        func press(_ result: AXError, landed expected: Bool, _ name: String) {
            let ok = HotCorners.pressLanded(result) == expected
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }
        press(.success, landed: true, "clock press: success stops")
        press(.cannotComplete, landed: true, "clock press: timed out stops, no second press")
        press(.actionUnsupported, landed: false, "clock press: unsupported tries the next element")
        press(.apiDisabled, landed: false, "clock press: Accessibility refused tries the next element")

        // Corners set to macOS's own actions are written into com.apple.dock with its codes and keys.
        func macOS(_ t: HotCorners.Target, _ m: HotCorners.Modifier, is expected: (Int, Int)?, _ name: String) {
            let found = HotCorners.macOSSetting(t, m)
            let ok = found?.code == expected?.0 && found?.modifier == expected?.1
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }
        macOS(.system(.notificationCenter), .none, is: (12, 0), "macOS corner: Notification Center")
        macOS(.system(.missionControl), .command, is: (2, 1 << 20), "macOS corner: Mission Control with ⌘")
        macOS(.system(.quickNote), .option, is: (14, 1 << 19), "macOS corner: Quick Note with ⌥")
        macOS(.system(.desktop), .shift, is: (4, 1 << 17), "macOS corner: Desktop with ⇧")
        macOS(.ring, .none, is: nil, "Orbit corner: the Ring stays with Orbit")
        macOS(.command(.lockScreen), .none, is: nil, "Orbit corner: an Orbit command stays with Orbit")
        macOS(.none, .none, is: nil, "empty corner: nothing for macOS")

        exit(failed == 0 ? 0 : 1)
    }
}
