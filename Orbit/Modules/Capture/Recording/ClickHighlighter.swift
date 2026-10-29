import AppKit
import QuartzCore

/// Draws a ring wherever the mouse is clicked while recording. ScreenCaptureKit's own
/// `showMouseClicks` is a faint grey blip that hardly shows (and none at all in window recordings),
/// so Orbit draws its own: for an area or a screen in a click-through window that the recording
/// deliberately keeps in (Recorder adds it to the filter); for a window — whose capture can't hold
/// a second window — by handing each click to the writer, which paints the same ring into the frames.
@MainActor
final class ClickHighlighter {
    static let shared = ClickHighlighter()

    private var window: NSWindow?
    private var monitors: [Any] = []
    /// Switched off from the recording controls: the overlay stays (it's part of the capture filter)
    /// but draws nothing.
    var enabled = true

    /// The overlay's window, once it's on screen — for the recording filter to keep in.
    var windowID: CGWindowID? { window.flatMap { CGWindowID(exactly: $0.windowNumber) } }

    /// Window recordings: where each click goes instead of the overlay — the point in global
    /// top-left coordinates (CGWindowList's), and whether it was a secondary click.
    private var sink: ((CGPoint, Bool) -> Void)?

    /// Listens for clicks without an overlay, passing each one to `sink`.
    func capture(into sink: @escaping (CGPoint, Bool) -> Void) {
        stop()
        self.sink = sink
        pulses = 0
        installMonitors()
        RecordingLog.write("click rings painted into the window's frames")
    }

    /// Puts the overlay up over `screen`. Call before building the capture filter.
    func start(on screen: NSScreen) {
        stop()
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        w.isReleasedWhenClosed = false
        // Stage Manager files every window under its app's stage: with Orbit's own window open, a
        // plain overlay belongs to Orbit's stage and is put away while you record another app —
        // the rings were drawn, just never on screen. .canJoinAllApplications keeps it with
        // whichever stage is showing.
        w.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        w.contentView = view
        w.setFrame(screen.frame, display: false)
        w.orderFrontRegardless()
        window = w
        pulses = 0
        // Say in the log whether the overlay really made it on screen (and so into the video).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let id = self.windowID else { return }
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
            let onScreen = (list?.first?[kCGWindowIsOnscreen as String] as? Bool) ?? false
            RecordingLog.write("click overlay \(id) on screen \(onScreen), enabled \(self.enabled)")
        }
        installMonitors()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Mouse clicks in other apps need no Accessibility permission; clicks on Orbit come locally.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            let right = event.type == .rightMouseDown
            MainActor.assumeIsolated { ClickHighlighter.shared.pulse(at: NSEvent.mouseLocation, secondary: right) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            ClickHighlighter.shared.pulse(at: NSEvent.mouseLocation, secondary: event.type == .rightMouseDown)
            return event
        }) { monitors.append(local) }
    }

    private var pulses = 0

    func stop() {
        if window != nil || sink != nil { RecordingLog.write("clicks done after \(pulses) ring(s)") }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        sink = nil
        window?.orderOut(nil)
        window = nil
    }

    /// A soft orange disc with a ring that grows and fades — readable on light and dark content.
    private func pulse(at point: NSPoint, secondary: Bool) {
        guard enabled else { return }
        if let sink {
            // Cocoa's bottom-left origin → the main display's top-left, as CGWindowList and the frames use.
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            pulses += 1
            sink(CGPoint(x: point.x, y: top - point.y), secondary)
            return
        }
        guard let window, let layer = window.contentView?.layer, window.frame.contains(point) else { return }
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        pulses += 1
        // The overlay must be in front at the moment of the click (another overlay may have come up).
        if !window.isVisible { window.orderFrontRegardless() }
        let side: CGFloat = 46
        let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        let tint = secondary ? NSColor.systemBlue : NSColor(red: 1, green: 0.42, blue: 0.1, alpha: 1)

        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: rect, transform: nil)
        disc.fillColor = tint.withAlphaComponent(0.32).cgColor
        disc.strokeColor = tint.withAlphaComponent(0.95).cgColor
        disc.lineWidth = 2.5
        disc.shadowColor = NSColor.black.cgColor
        disc.shadowOpacity = 0.25
        disc.shadowRadius = 2
        disc.shadowOffset = .zero
        disc.position = local
        let halo = CAShapeLayer()
        halo.path = CGPath(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5), transform: nil)
        halo.fillColor = nil
        halo.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        halo.lineWidth = 1
        disc.addSublayer(halo)
        layer.addSublayer(disc)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.45
        grow.toValue = 1.15
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.45, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { disc.removeFromSuperlayer() }
        disc.add(group, forKey: "pulse")
        CATransaction.commit()
    }
}

/// ~/Library/Logs/Orbit/recording.log — what the recording did, for when something's missing from a video.
enum RecordingLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("recording.log")
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
