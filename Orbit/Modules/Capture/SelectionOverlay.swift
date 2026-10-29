import AppKit
import Carbon.HIToolbox

/// Full-screen selection over a frozen snapshot. One window per display.
/// Drag to select an area, Space toggles window mode, Return takes the whole display, Esc cancels.
@MainActor
final class SelectionOverlay {
    struct Result {
        let image: CGImage
        let rect: CGRect // top-left origin, points, display-local
        let screenID: CGDirectDisplayID
        let scale: CGFloat
    }

    private static var current: SelectionOverlay?

    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    fileprivate var windowMode: Bool
    fileprivate let textMode: Bool
    fileprivate let targets: [CaptureService.WindowTarget]

    private init(windowMode: Bool, textMode: Bool, targets: [CaptureService.WindowTarget]) {
        self.windowMode = windowMode
        self.textMode = textMode
        self.targets = targets
    }

    static func run(shots: [CaptureService.Snapshot], windows: [CaptureService.WindowTarget],
                    startInWindowMode: Bool, textMode: Bool) async -> Result? {
        current?.finish(nil)
        let overlay = SelectionOverlay(windowMode: startInWindowMode, textMode: textMode, targets: windows)
        current = overlay
        return await withCheckedContinuation { cont in
            overlay.continuation = cont
            overlay.present(shots)
        }
    }

    private func present(_ shots: [CaptureService.Snapshot]) {
        for shot in shots {
            let window = OverlayWindow(shot: shot, owner: self)
            windows.append(window)
            window.orderFrontRegardless()
        }
        let active = windows.first { $0.shot.screen == NSScreen.active } ?? windows.first
        active?.makeKey()
        NSCursor.crosshair.set()
    }

    fileprivate func toggleWindowMode() {
        guard !textMode, !targets.isEmpty else { return }
        windowMode.toggle()
        windows.forEach { $0.overlayView.needsDisplay = true }
    }

    fileprivate func complete(rect local: CGRect, in window: OverlayWindow) {
        let shot = window.shot
        let h = shot.screen.frame.height
        let topLeft = CGRect(x: local.minX, y: h - local.maxY, width: local.width, height: local.height)
        let pixels = topLeft.applying(.init(scaleX: shot.scale, y: shot.scale)).integral
        guard let cropped = shot.image.cropping(to: pixels) else { finish(nil); return }
        finish(Result(image: cropped, rect: topLeft, screenID: shot.screen.displayID, scale: shot.scale))
    }

    fileprivate func complete(window target: CaptureService.WindowTarget, in window: OverlayWindow) {
        close()
        Task {
            if let (image, scale) = try? await CaptureService.shared.captureWindow(target) {
                finish(Result(image: image, rect: .zero, screenID: window.shot.screen.displayID, scale: scale))
            } else {
                finish(nil)
            }
        }
    }

    fileprivate func finish(_ result: Result?) {
        close()
        continuation?.resume(returning: result)
        continuation = nil
        if Self.current === self { Self.current = nil }
    }

    private func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
    }
}

private final class OverlayWindow: NSPanel {
    let shot: CaptureService.Snapshot
    let overlayView: OverlayView

    init(shot: CaptureService.Snapshot, owner: SelectionOverlay) {
        self.shot = shot
        overlayView = OverlayView(shot: shot, owner: owner)
        super.init(contentRect: shot.screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        // The frozen screen must appear exactly in place: no system open animation (a slight zoom)…
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        contentView = overlayView
        setFrame(shot.screen.frame, display: true)
        overlayView.window?.makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }

    /// …and no nudging below the menu bar, which would squeeze the picture.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class OverlayView: NSView {
    private let shot: CaptureService.Snapshot
    private unowned let owner: SelectionOverlay
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: CaptureService.WindowTarget?

    init(shot: CaptureService.Snapshot, owner: SelectionOverlay) {
        self.shot = shot
        self.owner = owner
        super.init(frame: CGRect(origin: .zero, size: shot.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        mouse = convert(event.locationInWindow, from: nil)
        if owner.windowMode { hoveredWindow = window(at: mouse!) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        var rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(rect.width, rect.height)
            rect.size = CGSize(width: side, height: side)
            if p.x < start.x { rect.origin.x = start.x - side }
            if p.y < start.y { rect.origin.y = start.y - side }
        }
        selection = rect.intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let selection, selection.width >= 4, selection.height >= 4 {
            owner.complete(rect: selection, in: window as! OverlayWindow)
            return
        }
        // A click without a drag captures the hovered window.
        if let target = owner.windowMode ? hoveredWindow : window(at: convert(event.locationInWindow, from: nil)), !owner.textMode {
            owner.complete(window: target, in: window as! OverlayWindow)
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
            if let mouse { hoveredWindow = owner.windowMode ? window(at: mouse) : nil }
        case kVK_Return:
            owner.complete(rect: bounds, in: window as! OverlayWindow)
        default:
            super.keyDown(with: event)
        }
    }

    private func window(at local: CGPoint) -> CaptureService.WindowTarget? {
        let global = CGPoint(x: local.x + shot.screen.frame.minX, y: local.y + shot.screen.frame.minY)
        return owner.targets.first { $0.frame.contains(global) }
    }

    private func local(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.draw(shot.image, in: bounds)

        let dim = NSColor.black.withAlphaComponent(owner.textMode ? 0.42 : 0.36)
        let hole: CGRect? = selection ?? (owner.windowMode ? hoveredWindow.map { local($0.frame) } : nil)

        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole { path.addPath(roundedPath(hole)) }
        ctx.addPath(path)
        ctx.setFillColor(dim.cgColor)
        ctx.fillPath(using: .evenOdd)

        if let selection {
            drawSelection(selection, in: ctx)
        } else if owner.windowMode, let target = hoveredWindow {
            drawWindowHighlight(target, in: ctx)
        } else if let mouse {
            drawCrosshair(at: mouse, in: ctx)
        }

        if let mouse, dragStart == nil || selection != nil, !owner.windowMode {
            drawLoupe(at: mouse, in: ctx)
        }
        if mouse != nil, selection == nil { drawHint(in: ctx) }
    }

    private func roundedPath(_ rect: CGRect) -> CGPath {
        CGPath(rect: rect, transform: nil)
    }

    private func drawSelection(_ rect: CGRect, in ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))

        // Corner handles
        ctx.setFillColor(NSColor.white.cgColor)
        for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            ctx.fillEllipse(in: CGRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6))
        }

        let w = Int((rect.width * shot.scale).rounded()), h = Int((rect.height * shot.scale).rounded())
        let label = "\(w) × \(h)"
        let below = rect.minY - 30 > 0
        let origin = CGPoint(x: rect.midX, y: below ? rect.minY - 30 : rect.maxY + 8)
        drawPill(label, centeredAt: origin)
    }

    private func drawWindowHighlight(_ target: CaptureService.WindowTarget, in ctx: CGContext) {
        let rect = local(target.frame)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)
        let name = target.title.isEmpty ? target.appName : "\(target.appName) — \(target.title)"
        drawPill(String(name.prefix(60)), centeredAt: CGPoint(x: rect.midX, y: rect.midY - 11), large: true)
    }

    private func drawCrosshair(at p: CGPoint, in ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(0.5)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: 0, y: p.y)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: p.y))
        ctx.move(to: CGPoint(x: p.x, y: 0)); ctx.addLine(to: CGPoint(x: p.x, y: bounds.maxY))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// Pixel-precise magnifier, offset away from the cursor and kept on screen.
    private func drawLoupe(at p: CGPoint, in ctx: CGContext) {
        let size: CGFloat = 116, cells: CGFloat = 15
        var origin = CGPoint(x: p.x + 24, y: p.y - size - 24)
        if origin.x + size > bounds.maxX { origin.x = p.x - size - 24 }
        if origin.y < 0 { origin.y = p.y + 24 }
        let frame = CGRect(origin: origin, size: CGSize(width: size, height: size))

        let px = p.x * shot.scale, py = (bounds.height - p.y) * shot.scale
        let src = CGRect(x: floor(px - cells / 2), y: floor(py - cells / 2), width: cells, height: cells)
        guard let crop = shot.image.cropping(to: src) else { return }

        ctx.saveGState()
        let clip = CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(clip); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        ctx.addPath(clip); ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: frame)

        let cell = size / cells
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<Int(cells) {
            let o = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: frame.minX + o, y: frame.minY)); ctx.addLine(to: CGPoint(x: frame.minX + o, y: frame.maxY))
            ctx.move(to: CGPoint(x: frame.minX, y: frame.minY + o)); ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY + o))
        }
        ctx.strokePath()
        let center = CGRect(x: frame.midX - cell / 2, y: frame.midY - cell / 2, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(center)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(clip); ctx.strokePath()

        drawPill("\(Int(px)), \(Int(py))", centeredAt: CGPoint(x: frame.midX, y: frame.minY - 26))
    }

    private func drawHint(in ctx: CGContext) {
        let text: String
        if owner.textMode { text = "Select text to copy  ·  Esc to cancel" }
        else if owner.windowMode { text = "Click a window  ·  Space for area  ·  Esc to cancel" }
        else { text = "Drag to capture  ·  Space for window  ·  ↩ full screen  ·  Esc to cancel" }
        drawPill(text, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 72), large: true)
    }

    private func drawPill(_ text: String, centeredAt center: CGPoint, large: Bool = false) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: large ? 13 : 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pad = CGSize(width: large ? 14 : 8, height: large ? 7 : 4)
        let rect = CGRect(x: center.x - size.width / 2 - pad.width, y: center.y - pad.height,
                          width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        s.draw(at: CGPoint(x: rect.minX + pad.width, y: rect.minY + pad.height))
    }
}
