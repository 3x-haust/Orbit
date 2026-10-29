import AppKit
import ApplicationServices

/// How much menu bar is free on either side of a notch, so its ears never sit on a menu title or a
/// status item. The shape is symmetric, so the narrower side decides.
enum NotchRoom {
    /// What's needed of a screen, read on the main thread.
    struct Geometry: Sendable {
        /// The notch's left and right edges, and the menu bar's band, in top-left (Accessibility) coordinates.
        var left: CGFloat
        var right: CGFloat
        var top: CGFloat
        var height: CGFloat
        var screenMinX: CGFloat
        var screenMaxX: CGFloat
        /// MenuBarAgent's slots describe the main display's bar only.
        var isMain: Bool

        @MainActor init(screen: NSScreen) {
            let n = screen.notchSize
            left = screen.notchMidX - n.width / 2
            right = screen.notchMidX + n.width / 2
            top = (NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY) - screen.frame.maxY
            height = max(n.height, screen.frame.maxY - screen.visibleFrame.maxY, 22)
            screenMinX = screen.frame.minX
            screenMaxX = screen.frame.maxX
            isMain = screen == NSScreen.screens.first
        }
    }

    /// A gap kept between an ear and the nearest menu or item.
    static let gap: CGFloat = 8

    nonisolated static func measure(_ g: Geometry, frontPID: pid_t?, ownFrames: [CGRect]) -> CGFloat {
        var left = g.left - g.screenMinX
        var right = g.screenMaxX - g.right
        guard AXIsProcessTrusted() else {
            // Nothing to measure with: stay small enough to clear most bars.
            return 44
        }
        func inBar(_ f: CGRect) -> Bool { f.width > 0 && f.midY >= g.top && f.midY <= g.top + g.height }

        // The front app's menus, left of the notch.
        if let pid = frontPID {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            if let bar: AXUIElement = attribute(app, kAXMenuBarAttribute),
               let items: [AXUIElement] = attribute(bar, kAXChildrenAttribute) {
                for item in items {
                    guard let f = frame(item), inBar(f), f.maxX <= g.left + 2 else { continue }
                    left = min(left, g.left - f.maxX)
                }
            }
        }

        // Status items, right of the notch (and left of it, when the bar is that full).
        if g.isMain {
            let layout = MenuBarHosted.read(ownFrames: ownFrames)
            for slot in layout.slots where slot.hasSlot && inBar(slot.frame) {
                if slot.frame.minX >= g.right - 2 { right = min(right, slot.frame.minX - g.right) }
                else if slot.frame.maxX <= g.left + 2 { left = min(left, g.left - slot.frame.maxX) }
            }
            if let c = layout.chevron, inBar(c) {
                if c.minX >= g.right - 2 { right = min(right, c.minX - g.right) } else if c.maxX <= g.left + 2 { left = min(left, g.left - c.maxX) }
            }
        }
        for f in ownFrames where inBar(f) {
            if f.minX >= g.right - 2 { right = min(right, f.minX - g.right) }
        }
        return max(0, min(left, right) - gap)
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    nonisolated private static func frame(_ element: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pos: AXValue = attribute(element, kAXPositionAttribute), let size: AXValue = attribute(element, kAXSizeAttribute),
              AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
