import AppKit
import Carbon.HIToolbox

/// Picks what to record over the live screen (not a frozen snapshot, so you see what will move).
/// Drag for an area, click a window, Space switches area/window, Return takes the whole display, Esc cancels.
@MainActor
final class RecordPicker {
    struct Candidate {
        let frame: CGRect // Cocoa global coordinates
        let windowID: CGWindowID
        let name: String
    }

    private static var current: RecordPicker?

    private var windows: [PickerWindow] = []
    private var continuation: CheckedContinuation<RecordTarget?, Never>?
    fileprivate var windowMode: Bool
    fileprivate let candidates: [Candidate]

    private init(windowMode: Bool) {
        self.windowMode = windowMode
        candidates = Self.windowCandidates()
    }

    static func run(windowMode: Bool) async -> RecordTarget? {
        current?.finish(nil)
        let picker = RecordPicker(windowMode: windowMode)
        current = picker
        return await withCheckedContinuation { cont in
            picker.continuation = cont
            picker.present()
        }
    }

    private func present() {
        for screen in NSScreen.screens {
            let w = PickerWindow(screen: screen, owner: self)
            windows.append(w)
            w.orderFrontRegardless()
        }
        (windows.first { $0.display == NSScreen.active } ?? windows.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    fileprivate func toggleWindowMode() {
        guard !candidates.isEmpty else { return }
        windowMode.toggle()
        windows.forEach { $0.pickerView.needsDisplay = true }
    }

    fileprivate func finish(_ target: RecordTarget?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        continuation?.resume(returning: target)
        continuation = nil
        if Self.current === self { Self.current = nil }
    }

    /// On-screen app windows, front to back. Orbit's own windows count too (its chrome sits above layer 0).
    private static func windowCandidates() -> [Candidate] {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 40, height > 40 else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let title = w[kCGWindowName as String] as? String ?? ""
            return Candidate(frame: CGRect(x: x, y: mainHeight - y - height, width: width, height: height),
                             windowID: id, name: title.isEmpty ? owner : "\(owner) — \(title)")
        }
    }
}

private final class PickerWindow: NSPanel {
    let display: NSScreen
    let pickerView: PickerView

    init(screen: NSScreen, owner: RecordPicker) {
        display = screen
        pickerView = PickerView(screen: screen, owner: owner)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        contentView = pickerView
        setFrame(screen.frame, display: true)
        makeFirstResponder(pickerView)
    }

    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class PickerView: NSView {
    private let screen: NSScreen
    private unowned let owner: RecordPicker
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: RecordPicker.Candidate?

    init(screen: NSScreen, owner: RecordPicker) {
        self.screen = screen
        self.owner = owner
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hovered = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        hovered = owner.windowMode ? candidate(at: p) : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, !owner.windowMode else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        var rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(rect.width, rect.height)
            rect.size = CGSize(width: side, height: side)
            if p.x < start.x { rect.origin.x = start.x - side }
            if p.y < start.y { rect.origin.y = start.y - side }
        }
        selection = rect.intersection(bounds).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let selection, selection.width >= 16, selection.height >= 16 {
            owner.finish(RecordTarget(kind: .area, screen: screen, frame: global(selection)))
            return
        }
        // A click without a drag records the window under the pointer.
        if let c = candidate(at: convert(event.locationInWindow, from: nil)) {
            owner.finish(RecordTarget(kind: .window, screen: screen, frame: c.frame, windowID: c.windowID))
            return
        }
        selection = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            if selection != nil, dragStart != nil { selection = nil; dragStart = nil; needsDisplay = true }
            else { owner.finish(nil) }
        case kVK_Space:
            owner.toggleWindowMode()
            selection = nil
            hovered = owner.windowMode ? mouse.flatMap(candidate) : nil
            needsDisplay = true
        case kVK_Return:
            owner.finish(.screen(screen))
        default:
            super.keyDown(with: event)
        }
    }

    private func candidate(at local: CGPoint) -> RecordPicker.Candidate? {
        let p = CGPoint(x: local.x + screen.frame.minX, y: local.y + screen.frame.minY)
        return owner.candidates.first { $0.frame.contains(p) }
    }

    private func global(_ local: CGRect) -> CGRect { local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }
    private func local(_ global: CGRect) -> CGRect { global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hole = selection ?? hovered.map { local($0.frame) }
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole { path.addRect(hole) }
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let selection {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            ctx.setLineDash(phase: 0, lengths: [])
            let scale = screen.backingScaleFactor
            let label = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
            let below = selection.minY - 30 > 0
            pill(label, at: CGPoint(x: selection.midX, y: below ? selection.minY - 30 : selection.maxY + 8))
        } else if let hovered {
            let rect = local(hovered.frame)
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
            pill(String(hovered.name.prefix(60)), at: CGPoint(x: rect.midX, y: rect.midY - 11), large: true)
        } else if let mouse {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.move(to: CGPoint(x: 0, y: mouse.y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: mouse.y))
            ctx.move(to: CGPoint(x: mouse.x, y: 0)); ctx.addLine(to: CGPoint(x: mouse.x, y: bounds.maxY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if mouse != nil, selection == nil {
            let hint = owner.windowMode
                ? "Click a window to record  ·  Space for area  ·  ↩ full screen  ·  Esc to cancel".loc
                : "Drag to record an area  ·  Space for window  ·  ↩ full screen  ·  Esc to cancel".loc
            pill(hint, at: CGPoint(x: bounds.midX, y: bounds.maxY - 72), large: true, dot: true)
        }
    }

    private func pill(_ text: String, at center: CGPoint, large: Bool = false, dot: Bool = false) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: large ? 13 : 11, weight: .medium)
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = s.size()
        let pad = CGSize(width: large ? 14 : 8, height: large ? 7 : 4)
        let dotSpace: CGFloat = dot ? 16 : 0
        let rect = CGRect(x: center.x - (size.width + dotSpace) / 2 - pad.width, y: center.y - pad.height,
                          width: size.width + dotSpace + pad.width * 2, height: size.height + pad.height * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        if dot {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.minX + pad.width, y: rect.midY - 4, width: 8, height: 8)).fill()
        }
        s.draw(at: CGPoint(x: rect.minX + pad.width + dotSpace, y: rect.minY + pad.height))
    }
}
