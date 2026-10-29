import AppKit
import ApplicationServices

/// Rectangle-style window snapping through the Accessibility API.
/// AX uses top-left-origin global coordinates; NSScreen uses bottom-left. Everything here is AX space.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    enum Layout: Equatable {
        case left, right, top, bottom, maximize, center, restore, nextDisplay, previousDisplay
        case topLeft, topRight, bottomLeft, bottomRight
        case firstThird, centerThird, lastThird
    }

    private var originals: [CFHashCode: CGRect] = [:]
    private var lastAction: (layout: Layout, window: CFHashCode, step: Int, at: Date)?

    // MARK: Targets

    func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return attribute(element, kAXFocusedWindowAttribute) as AXUIElement?
    }

    /// The window under a Cocoa-space point, e.g. the mouse when the Ring opened.
    func window(at cocoaPoint: CGPoint) -> AXUIElement? {
        let ax = CGPoint(x: cocoaPoint.x, y: mainHeight - cocoaPoint.y)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(ax.x), Float(ax.y), &element) == .success,
              var current = element else { return nil }
        for _ in 0..<12 {
            if (attribute(current, kAXRoleAttribute) as String?) == kAXWindowRole { return current }
            if let window = attribute(current, kAXWindowAttribute) as AXUIElement? { return window }
            guard let parent = attribute(current, kAXParentAttribute) as AXUIElement? else { break }
            current = parent
        }
        return nil
    }

    // MARK: Apply

    func apply(_ layout: Layout, to target: AXUIElement? = nil) {
        guard AXIsProcessTrusted() else {
            PermissionPrompt.show(.accessibility)
            return
        }
        guard let window = target ?? focusedWindow(), let frame = frame(of: window) else {
            NSSound.beep()
            return
        }
        let key = CFHash(window)
        if layout == .restore {
            if let original = originals.removeValue(forKey: key) { set(window, to: original) }
            return
        }
        if originals[key] == nil { originals[key] = frame }

        let screens = NSScreen.screens.map(axVisibleFrame)
        // The display the window is mostly on (its middle can sit under the menu bar or off a visible frame).
        let index = Self.screenIndex(for: frame, in: NSScreen.screens.map(axFullFrame))
        let current = screens[index]

        if layout == .nextDisplay || layout == .previousDisplay {
            guard screens.count > 1 else {
                WindowLog.write("\(layout): only one display")
                Toast.show("Only one display is connected", symbol: "display")
                return
            }
            let step = layout == .nextDisplay ? 1 : screens.count - 1
            let next = screens[(index + step) % screens.count]
            // Same spot relative to the display, clamped so it fits.
            let w = min(frame.width, next.width), h = min(frame.height, next.height)
            let rx = current.width > w ? (frame.minX - current.minX) / (current.width - w) : 0
            let ry = current.height > h ? (frame.minY - current.minY) / (current.height - h) : 0
            let target = CGRect(x: next.minX + max(0, min(1, rx)) * (next.width - w),
                                y: next.minY + max(0, min(1, ry)) * (next.height - h), width: w, height: h)
            WindowLog.write("\(layout): \(frame) on display \(index) → \(target)")
            set(window, to: target, crossingDisplays: true)
            return
        }

        // Pressing the same half again cycles 1/2 → 2/3 → 1/3: right after the last press, or
        // whenever the window still sits exactly where a step of this layout put it.
        var step = 0
        if let last = lastAction, last.layout == layout, last.window == key, Date().timeIntervalSince(last.at) < 1.5 {
            step = (last.step + 1) % 3
        } else if let at = (0..<3).first(where: { Self.close(rect(for: layout, in: current, step: $0, window: frame), frame) }) {
            step = (at + 1) % 3
        }
        lastAction = (layout, key, step, Date())
        WindowLog.write("\(layout) step \(step): \(frame) in \(current)")
        set(window, to: rect(for: layout, in: current, step: step, window: frame))
    }

    private func rect(for layout: Layout, in s: CGRect, step: Int, window: CGRect) -> CGRect {
        let gap = CGFloat(Pref.defaults.double(forKey: Pref.windowGap))
        let fraction: CGFloat = [0.5, 2.0 / 3.0, 1.0 / 3.0][step]
        var r: CGRect
        switch layout {
        case .left: r = CGRect(x: s.minX, y: s.minY, width: s.width * fraction, height: s.height)
        case .right: r = CGRect(x: s.maxX - s.width * fraction, y: s.minY, width: s.width * fraction, height: s.height)
        case .top: r = CGRect(x: s.minX, y: s.minY, width: s.width, height: s.height * fraction)
        case .bottom: r = CGRect(x: s.minX, y: s.maxY - s.height * fraction, width: s.width, height: s.height * fraction)
        case .topLeft: r = CGRect(x: s.minX, y: s.minY, width: s.width / 2, height: s.height / 2)
        case .topRight: r = CGRect(x: s.midX, y: s.minY, width: s.width / 2, height: s.height / 2)
        case .bottomLeft: r = CGRect(x: s.minX, y: s.midY, width: s.width / 2, height: s.height / 2)
        case .bottomRight: r = CGRect(x: s.midX, y: s.midY, width: s.width / 2, height: s.height / 2)
        case .firstThird: r = CGRect(x: s.minX, y: s.minY, width: s.width / 3, height: s.height)
        case .centerThird: r = CGRect(x: s.minX + s.width / 3, y: s.minY, width: s.width / 3, height: s.height)
        case .lastThird: r = CGRect(x: s.minX + s.width * 2 / 3, y: s.minY, width: s.width / 3, height: s.height)
        case .maximize: r = s
        case .center:
            let w = min(window.width, s.width), h = min(window.height, s.height)
            return CGRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h)
        case .restore, .nextDisplay, .previousDisplay: return window
        }
        return gap > 0 ? r.insetBy(dx: gap / 2, dy: gap / 2) : r
    }

    // MARK: AX plumbing

    private var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Usable area in AX coordinates: below the menu bar, beside the Dock, and clear of the Stage Manager strip.
    private func axVisibleFrame(_ screen: NSScreen) -> CGRect {
        var v = screen.visibleFrame
        let full = axFullFrame(screen)
        // macOS's reserve for the Dock stops a few points short of its rounded background, so
        // windows laid against that edge tuck under it. Clear the Dock as it's actually drawn.
        if let dock = Self.dockFrame(), full.intersects(dock) {
            let d = CGRect(x: dock.minX, y: mainHeight - dock.maxY, width: dock.width, height: dock.height) // AppKit coords
            switch Self.dockEdge() {
            case "left": v = CGRect(x: max(v.minX, d.maxX), y: v.minY, width: v.maxX - max(v.minX, d.maxX), height: v.height)
            case "right": v.size.width = min(v.maxX, d.minX) - v.minX
            default: v = CGRect(x: v.minX, y: max(v.minY, d.maxY), width: v.width, height: v.maxY - max(v.minY, d.maxY))
            }
        }
        if let strip = Self.stageStrip(on: screen) {
            v.size.width -= strip.width
            if strip.onLeft { v.origin.x += strip.width }
        }
        return CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
    }

    private func axFullFrame(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
    }

    /// The screen holding most of `frame`; the first one if it's on none.
    private static func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int {
        let areas = screens.map { s -> CGFloat in let i = s.intersection(frame); return i.isNull ? 0 : i.width * i.height }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return 0 }
        return best
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 8 && abs(a.minY - b.minY) <= 8 && abs(a.width - b.width) <= 8 && abs(a.height - b.height) <= 8
    }

    /// Where the Dock is pinned: "bottom", "left" or "right".
    static func dockEdge() -> String {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        return CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
    }

    /// The Dock's drawn frame in AX coordinates (its icon list plus the background around it), or
    /// nil while it auto-hides — then it only covers windows for a moment, like macOS intends.
    static func dockFrame() -> CGRect? {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        if CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool == true { return nil }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = (kids as? [AXUIElement])?.first(where: { el in
                  var role: CFTypeRef?
                  AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                  return role as? String == kAXListRole
              }) else { return nil }
        var p: CFTypeRef?, sz: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &sz) == .success,
              let p, let sz, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(sz) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sz as! AXValue, .cgSize, &size)
        guard size.width > 10, size.height > 10 else { return nil }
        // The icon list sits inside the Dock's background; 8pt covers the background and its shadow edge.
        return CGRect(origin: origin, size: size).insetBy(dx: -8, dy: -8)
    }

    /// Width and side of the Stage Manager recent-apps strip, when it's on screen.
    static func stageStrip() -> (width: CGFloat, onLeft: Bool)? {
        NSScreen.screens.lazy.compactMap { stageStrip(on: $0) }.first
    }

    /// The strip only takes room while it's really drawn: Stage Manager being on isn't enough — with
    /// no other stages, or once a window covers its edge, macOS takes the strip away and layouts
    /// should use the whole screen. Its thumbnails are WindowManager windows along the screen's edge.
    static func stageStrip(on screen: NSScreen) -> (width: CGFloat, onLeft: Bool)? {
        guard Pref.defaults.bool(forKey: Pref.windowStageManager) else { return nil }
        let wm = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(wm)
        let enabled = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, wm) as? Bool ?? false
        guard enabled else { return nil }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let f = screen.frame
        let ax = CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let thumbs: [CGRect] = list.compactMap { info in
            guard (info[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 20, r.width < 320, r.height > 40,
                  ax.intersects(r) else { return nil }
            return r
        }
        let left = thumbs.filter { $0.minX < ax.minX + 120 }
        let right = thumbs.filter { $0.maxX > ax.maxX - 120 }
        let side: (thumbs: [CGRect], onLeft: Bool)? = left.count >= right.count ? (left.isEmpty ? nil : (left, true)) : (right, false)
        guard let side else { return nil }
        let measured = side.onLeft ? (side.thumbs.map(\.maxX).max() ?? ax.minX) - ax.minX : ax.maxX - (side.thumbs.map(\.minX).min() ?? ax.maxX)
        let width = max(measured + 10, 60)
        return (width, side.onLeft)
    }

    func frame(of window: AXUIElement) -> CGRect? {
        guard let pos = attribute(window, kAXPositionAttribute) as AXValue?,
              let size = attribute(window, kAXSizeAttribute) as AXValue? else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &p)
        AXValueGetValue(size, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Size → position → size: apps with minimum sizes or screen-edge clamping settle correctly.
    /// Moving to another display goes position first, so the size isn't clamped to the old screen,
    /// then position again in case the new size pushed it off.
    private func set(_ window: AXUIElement, to rect: CGRect, crossingDisplays: Bool = false) {
        var p = rect.origin, s = rect.size
        func size() { if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) } }
        func position() { if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) } }
        if crossingDisplays {
            position(); size(); position()
        } else {
            size(); position(); size()
        }
        if let now = frame(of: window), !Self.close(now, rect) { WindowLog.write("  settled at \(now) instead of \(rect)") }
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

/// ~/Library/Logs/Orbit/window.log — what each layout did, for when one doesn't take.
enum WindowLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("window.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
