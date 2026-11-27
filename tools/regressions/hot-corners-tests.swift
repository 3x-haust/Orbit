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

        // Notification Center opens through macOS's "Show Notification Center" shortcut (hot key 163).
        func entry(_ enabled: Bool, _ params: [Int]) -> [String: Any] {
            ["enabled": NSNumber(value: enabled), "value": ["parameters": params.map { NSNumber(value: $0) }, "type": "standard"]]
        }
        func shortcut(_ e: Any?, is expected: (Int, UInt64)?, _ name: String) {
            let found = HotCorners.shortcut(from: e)
            let ok = found.map { Int($0.keyCode) } == expected?.0 && found?.flags.rawValue == expected?.1
            if !ok { failed += 1 }
            print("\(ok ? "PASS" : "FAIL") \(name)")
        }
        let orbit = HotCorners.orbitShortcut
        shortcut(entry(true, orbit), is: (80, UInt64(orbit[2])), "shortcut: Orbit's ⌃⌥⇧⌘F19")
        shortcut(entry(true, [110, 45, 1_835_008]), is: (45, 1_835_008), "shortcut: one you set yourself is used")
        shortcut(entry(false, [110, 45, 1_835_008]), is: nil, "shortcut: turned off")
        shortcut(entry(true, [65535, 65535, 0]), is: nil, "shortcut: on but without a key")
        shortcut(nil, is: nil, "shortcut: never set")
        let flags = CGEventFlags(rawValue: UInt64(orbit[2]))
        let all: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        let ok = flags == all
        if !ok { failed += 1 }
        print("\(ok ? "PASS" : "FAIL") shortcut: Orbit's keys are ⌃⌥⇧⌘ with fn, as macOS stores F-keys")

        exit(failed == 0 ? 0 : 1)
    }
}
