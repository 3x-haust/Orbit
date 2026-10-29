import AppKit
import SwiftUI

/// A borderless, non-activating panel that can still take keyboard focus.
/// Typing goes to the panel while the user's app stays frontmost, so paste targets stay correct.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Bool)?

    init(contentRect: NSRect, focusable: Bool = true) {
        var mask: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        mask.insert(.nonactivatingPanel)
        // A zero-size window makes a hosting view's layout loop until AppKit throws; start off-screen at a real size.
        let rect = contentRect.isEmpty ? NSRect(x: -20000, y: -20000, width: 400, height: 400) : contentRect
        super.init(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = !focusable
        self.focusable = focusable
    }

    private var focusable = true
    override var canBecomeKey: Bool { focusable }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        if onEscape?() == true { return }
        orderOut(nil)
    }

    func setContent<V: View>(_ view: V) {
        let host = FirstMouseHostingView(rootView: view.orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = [] // no titlebar safe-area feedback into layout (constraint-loop crash)
        contentView = Self.container(for: host)
    }

    /// Hosts SwiftUI one level below the content view. As the content view itself, NSHostingView
    /// still resizes the window to its ideal size on layout (even with no sizing options), which
    /// loops update-constraints passes until AppKit aborts the app.
    static func container(for host: NSView) -> NSView {
        let container = NSView()
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        return container
    }

    /// Fade + small rise, per Motion.panelEnter.
    func present(at frame: NSRect) {
        setFrame(frame, display: false)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = 0
        if !reduce { setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - 6)) }
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.08 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().alphaValue = 1
            if !reduce { animator().setFrameOrigin(frame.origin) }
        }
    }

    func dismiss(completion: (() -> Void)? = nil) {
        guard isVisible else { completion?(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
            completion?()
        })
    }
}

/// Drags its window when pressed. SwiftUI's hosting view swallows background drags, so
/// `isMovableByWindowBackground` alone never moves a panel; put this behind the draggable area.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Clicks land on the first try even though the panel never activates Orbit.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSWindow {
    /// Orbit is a menu-bar app, so cooperative activation would leave its windows behind the current app.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

extension NSScreen {
    /// The screen under the mouse pointer — where transient surfaces should appear.
    static var active: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
