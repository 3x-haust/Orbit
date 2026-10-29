import AppKit
import Carbon.HIToolbox
import SwiftUI

/// What happens to a capture instead of the usual after-capture steps, picked with a key while selecting.
enum CaptureAction: CaseIterable {
    case copy, save, edit, pin, text, record, scroll

    init?(keyCode: Int) {
        guard let action = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = action
    }

    var keyCode: Int {
        switch self {
        case .copy: kVK_ANSI_C
        case .save: kVK_ANSI_S
        case .edit: kVK_ANSI_E
        case .pin: kVK_ANSI_P
        case .text: kVK_ANSI_T
        case .record: kVK_ANSI_V
        case .scroll: kVK_ANSI_L
        }
    }

    var title: String {
        switch self {
        case .copy: "Copy only"
        case .save: "Save to file"
        case .edit: "Open in Editor"
        case .pin: "Pin on screen"
        case .text: "Recognize text"
        case .record: "Record this area"
        case .scroll: "Scroll capture"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .save: "arrow.down.circle"
        case .edit: "pencil.tip.crop.circle"
        case .pin: "pin"
        case .text: "text.viewfinder"
        case .record: "record.circle"
        case .scroll: "arrow.down.doc"
        }
    }

    /// Needs the area itself (a live recording or scroll), not the frozen picture.
    var needsArea: Bool { self == .record || self == .scroll }
}

/// Full-screen selection over a frozen snapshot. One window per display.
/// Drag to select an area, Space toggles window mode, Return takes the whole display, Esc cancels.
/// While dragging: ⇧ locks the ratio, ⌥ grows from the center, Space moves, arrows nudge. Before:
/// Tab cycles ratios, R brings back the last area, ⌘C copies the color under the pointer. C S E P T V L
/// pick what happens to the result.
@MainActor
final class SelectionOverlay {
    struct Result {
        let image: CGImage
        let rect: CGRect // top-left origin, points, display-local
        let screenID: CGDirectDisplayID
        let scale: CGFloat
        var action: CaptureAction?
    }

    private static var current: SelectionOverlay?
    /// Tab's choice, kept for the next capture while Orbit runs.
    private static var lastPreset: AspectPreset = .free

    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    fileprivate var windowMode: Bool
    fileprivate let textMode: Bool
    fileprivate let targets: [CaptureService.WindowTarget]
    fileprivate let allowsActions: Bool
    fileprivate let lastArea: CaptureService.Area?
    fileprivate var preset: AspectPreset = .free
    fileprivate private(set) var action: CaptureAction?
    fileprivate weak var activeView: OverlayView?

    private init(windowMode: Bool, textMode: Bool, targets: [CaptureService.WindowTarget],
                 allowsActions: Bool = false, lastArea: CaptureService.Area? = nil) {
        self.windowMode = windowMode
        self.textMode = textMode
        self.targets = targets
        self.allowsActions = allowsActions
        self.lastArea = lastArea
    }

    static func run(shots: [CaptureService.Snapshot], windows: [CaptureService.WindowTarget],
                    startInWindowMode: Bool, textMode: Bool,
                    allowsActions: Bool = false, lastArea: CaptureService.Area? = nil) async -> Result? {
        current?.finish(nil)
        let overlay = SelectionOverlay(windowMode: startInWindowMode, textMode: textMode, targets: windows,
                                       allowsActions: allowsActions, lastArea: lastArea)
        overlay.preset = lastPreset
        current = overlay
        return await withCheckedContinuation { cont in
            overlay.continuation = cont
            overlay.present(shots)
        }
    }

    private func present(_ shots: [CaptureService.Snapshot]) {
        let hints = Pref.defaults.bool(forKey: Pref.captureKeyHints)
        for shot in shots {
            let window = OverlayWindow(shot: shot, owner: self)
            if hints { window.overlayView.installHints() }
            windows.append(window)
            window.orderFrontRegardless()
        }
        let active = windows.first { $0.shot.screen == NSScreen.active } ?? windows.first
        active?.makeKey()
        if let view = active?.overlayView { setActive(view) }
        NSCursor.crosshair.set()
    }

    /// The display being worked on shows the key hints; the others don't.
    fileprivate func setActive(_ view: OverlayView) {
        guard activeView !== view else { return }
        activeView = view
        for w in windows where w.overlayView !== view { w.overlayView.hideHints() }
        view.pokeHints()
    }

    private func redrawAll() {
        windows.forEach { $0.overlayView.stateChanged() }
    }

    fileprivate func toggleWindowMode() {
        guard !textMode, !targets.isEmpty else { return }
        windowMode.toggle()
        redrawAll()
    }

    fileprivate func cyclePreset(backward: Bool) {
        preset = preset.next(backward: backward)
        Self.lastPreset = preset
        redrawAll()
    }

    /// Pressing the picked key again goes back to the usual after-capture steps.
    fileprivate func toggleAction(_ a: CaptureAction) {
        guard allowsActions else { return }
        action = action == a ? nil : a
        redrawAll()
    }

    /// R: the last captured area, on the display it was on. Return captures it, Esc goes back.
    fileprivate func restoreLast() {
        guard let last = lastArea, let window = windows.first(where: { $0.shot.screen.displayID == last.screenID }) else {
            NSSound.beep(); return
        }
        let view = window.overlayView
        let h = window.shot.screen.frame.height
        let local = CGRect(x: last.rect.minX, y: h - last.rect.maxY, width: last.rect.width, height: last.rect.height)
            .intersection(view.bounds)
        guard local.width >= 4, local.height >= 4 else { NSSound.beep(); return }
        if windowMode { windowMode = false }
        windows.forEach { $0.overlayView.clearRestore() }
        view.restore(local)
        window.makeKey()
        window.makeFirstResponder(view)
        setActive(view)
        redrawAll()
    }

    /// Return: the brought-back or half-dragged area if there is one, else the whole display.
    fileprivate func confirm(from view: OverlayView) {
        if let w = windows.first(where: { $0.overlayView.pendingRect != nil }), let rect = w.overlayView.pendingRect {
            complete(rect: rect, in: w)
        } else if let w = view.window as? OverlayWindow {
            complete(rect: view.bounds, in: w)
        }
    }

    fileprivate func complete(rect local: CGRect, in window: OverlayWindow) {
        let shot = window.shot
        let h = shot.screen.frame.height
        let topLeft = CGRect(x: local.minX, y: h - local.maxY, width: local.width, height: local.height)
        let pixels = topLeft.applying(.init(scaleX: shot.scale, y: shot.scale)).integral
        guard let cropped = shot.image.cropping(to: pixels) else { finish(nil); return }
        finish(Result(image: cropped, rect: topLeft, screenID: shot.screen.displayID, scale: shot.scale, action: action))
    }

    fileprivate func complete(window target: CaptureService.WindowTarget, in window: OverlayWindow) {
        close()
        let action = action
        Task {
            if let (image, scale) = try? await CaptureService.shared.captureWindow(target) {
                finish(Result(image: image, rect: .zero, screenID: window.shot.screen.displayID, scale: scale, action: action))
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
    /// Set while the mouse is down (a drag in progress).
    private var dragStart: CGPoint?
    private var geometry: SelectionGeometry?
    private var selection: CGRect?
    private var hoveredWindow: CaptureService.WindowTarget?
    /// The selection is the last area brought back with R, waiting for Return.
    private var restored = false
    /// The brought-back area when the mouse went down, so a click inside it takes it.
    private var restoredAtMouseDown: CGRect?
    /// Space held mid-drag: the selection moves instead of resizing.
    private var carrying = false
    private var mods: NSEvent.ModifierFlags = []
    private var hintHost: HintHostingView?
    private var hintItems: [KeyHint] = []
    private var hintFade: DispatchWorkItem?

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

    private var dragging: Bool { dragStart != nil && geometry != nil }

    /// What Return takes from this display, if anything.
    var pendingRect: CGRect? {
        guard let selection, restored || dragging, selection.width >= 4, selection.height >= 4 else { return nil }
        return selection
    }

    /// The drag's ratio: Tab's preset, or a square while ⇧ is held.
    private var aspect: CGFloat? { owner.preset.ratio ?? (mods.contains(.shift) ? 1 : nil) }
    private var fromCenter: Bool { mods.contains(.option) }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        owner.setActive(self)
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
        restoredAtMouseDown = restored ? selection : nil
        restored = false
        dragStart = p
        geometry = SelectionGeometry(start: p)
        mods = event.modifierFlags
        selection = nil
        refreshHints()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, var g = geometry else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        mods = event.modifierFlags
        g.move(pointer: p, carrying: carrying, aspect: aspect, fromCenter: fromCenter, in: bounds)
        geometry = g
        updateSelection()
    }

    private func updateSelection() {
        guard dragging, let geometry else { return }
        selection = geometry.rect(aspect: aspect, fromCenter: fromCenter, in: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return } // Esc called the drag off
        defer { dragStart = nil; geometry = nil; carrying = false; restoredAtMouseDown = nil; refreshHints() }
        let ow = window as! OverlayWindow
        if let selection, selection.width >= 4, selection.height >= 4 {
            owner.complete(rect: selection, in: ow)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        // A click inside the brought-back area takes it.
        if let last = restoredAtMouseDown, last.contains(p) {
            owner.complete(rect: last, in: ow)
            return
        }
        // A click without a drag captures the hovered window.
        if let target = owner.windowMode ? hoveredWindow : window(at: p), !owner.textMode {
            if owner.action?.needsArea == true {
                owner.complete(rect: local(target.frame).intersection(bounds), in: ow)
            } else {
                owner.complete(window: target, in: ow)
            }
            return
        }
        selection = nil
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        let before = mods.intersection([.shift, .option])
        mods = event.modifierFlags
        pokeHints()
        if before != mods.intersection([.shift, .option]) { updateSelection() }
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, Int(event.keyCode) == kVK_ANSI_C {
            pokeHints()
            copyColor()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        let shift = event.modifierFlags.contains(.shift)
        pokeHints()
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        switch code {
        case kVK_Escape:
            if dragging, selection != nil {
                selection = nil; dragStart = nil; geometry = nil; carrying = false
                stateChanged()
            } else if restored {
                clearRestore()
                stateChanged()
            } else {
                owner.finish(nil)
            }
        case kVK_Space:
            guard !event.isARepeat else { return }
            if dragging {
                carrying = true
            } else {
                owner.toggleWindowMode()
                if let mouse { hoveredWindow = owner.windowMode ? window(at: mouse) : nil }
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            owner.confirm(from: self)
        case kVK_Tab:
            owner.cyclePreset(backward: shift)
        case kVK_ANSI_R where !dragging:
            guard !event.isARepeat else { return }
            owner.restoreLast()
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            let step: CGFloat = shift ? 10 : 1
            let d: CGVector = switch code {
            case kVK_LeftArrow: CGVector(dx: -step, dy: 0)
            case kVK_RightArrow: CGVector(dx: step, dy: 0)
            case kVK_UpArrow: CGVector(dx: 0, dy: step)
            default: CGVector(dx: 0, dy: -step)
            }
            if dragging, var g = geometry {
                g.nudge(d, in: bounds)
                geometry = g
                updateSelection()
            } else if restored, let selection {
                self.selection = SelectionGeometry.shifted(selection, by: d, in: bounds)
                needsDisplay = true
            }
        default:
            if owner.allowsActions, let action = CaptureAction(keyCode: code) {
                if !event.isARepeat { owner.toggleAction(action) }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { carrying = false; return }
        super.keyUp(with: event)
    }

    fileprivate func restore(_ rect: CGRect) {
        dragStart = nil
        geometry = nil
        selection = rect
        restored = true
        stateChanged()
    }

    fileprivate func clearRestore() {
        guard restored else { return }
        restored = false
        selection = nil
        needsDisplay = true
    }

    /// Preset, action, mode or phase changed.
    fileprivate func stateChanged() {
        updateSelection()
        refreshHints()
        needsDisplay = true
    }

    private func window(at local: CGPoint) -> CaptureService.WindowTarget? {
        let global = CGPoint(x: local.x + shot.screen.frame.minX, y: local.y + shot.screen.frame.minY)
        return owner.targets.first { $0.frame.contains(global) }
    }

    private func local(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -shot.screen.frame.minX, dy: -shot.screen.frame.minY)
    }

    // MARK: Color

    /// Where the magnifier looks: the moving corner while dragging, else the pointer.
    private var loupePoint: CGPoint? {
        if dragging, let tip = geometry?.tip {
            return CGPoint(x: min(max(tip.x, bounds.minX), bounds.maxX), y: min(max(tip.y, bounds.minY), bounds.maxY))
        }
        return mouse
    }

    /// The magnifier's center pixel, as "#RRGGBB".
    private func hexColor(at p: CGPoint) -> String? {
        let cells: CGFloat = 15
        let px = p.x * shot.scale, py = (bounds.height - p.y) * shot.scale
        let src = CGRect(x: floor(px - cells / 2) + floor(cells / 2), y: floor(py - cells / 2) + floor(cells / 2), width: 1, height: 1)
        guard let pixel = shot.image.cropping(to: src), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? SelectionGeometry.hex(r: bytes[0], g: bytes[1], b: bytes[2]) : nil
    }

    private func copyColor() {
        guard let p = loupePoint, let hex = hexColor(at: p) else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        // Above the overlay, which sits at the screen-saver level.
        Toast.show("%@ copied to clipboard".loc(hex), symbol: "eyedropper", level: NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1))
    }

    // MARK: Key hints

    fileprivate func installHints() {
        guard hintHost == nil else { return }
        let host = HintHostingView(rootView: KeyHintStrip(items: []))
        host.appearance = NSAppearance(named: .darkAqua)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.wantsLayer = true
        host.alphaValue = 0
        addSubview(host)
        hintHost = host
        refreshHints()
    }

    private func currentHints() -> [KeyHint] {
        let actions = owner.allowsActions ? [KeyHint(keys: ["C·S·E·P·T·V·L"], title: "Action")] : []
        if restored {
            return [KeyHint(keys: ["↩"], title: "Capture it"), KeyHint(keys: ["Esc"], title: "Pick again"),
                    KeyHint(keys: ["←↑↓→"], title: "Move selection")] + actions
        }
        if dragging {
            return [KeyHint(keys: ["⇧"], title: "Lock ratio"), KeyHint(keys: ["⌥"], title: "From center"),
                    KeyHint(keys: ["Space"], title: "Move selection"), KeyHint(keys: ["←↑↓→"], title: "Nudge")] + actions
        }
        if owner.windowMode {
            return [KeyHint(keys: ["Space"], title: "Select an area")] + actions
        }
        return [KeyHint(keys: ["⇧"], title: "Lock ratio"), KeyHint(keys: ["⌥"], title: "From center"),
                KeyHint(keys: ["Tab"], title: "Ratio"), KeyHint(keys: ["R"], title: "Last area"),
                KeyHint(keys: ["⌘C"], title: "Copy color")] + actions
    }

    /// Updates what the strip says, without showing it.
    private func refreshHints() {
        guard let host = hintHost else { return }
        let items = currentHints()
        guard items != hintItems else { return }
        hintItems = items
        host.rootView = KeyHintStrip(items: items)
        // Measured on a plain hosting view: with no sizing options the live one reports zero.
        let size = NSHostingView(rootView: KeyHintStrip(items: items)).fittingSize
        host.frame = CGRect(x: (bounds.width - size.width) / 2, y: 28, width: size.width, height: size.height).integral
    }

    /// A key was pressed: show the strip, then fade it after a few quiet seconds.
    fileprivate func pokeHints() {
        guard let host = hintHost, owner.activeView === self else { return }
        refreshHints()
        hintFade?.cancel()
        if host.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                host.animator().alphaValue = 1
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.hideHints() }
        hintFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    fileprivate func hideHints() {
        hintFade?.cancel()
        guard let host = hintHost, host.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.4
            host.animator().alphaValue = 0
        }
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

        if mouse != nil, let p = loupePoint, dragStart == nil || selection != nil, !owner.windowMode {
            drawLoupe(at: p, in: ctx)
        }
        if mouse != nil, selection == nil { drawHint(in: ctx) }
    }

    private func roundedPath(_ rect: CGRect) -> CGPath {
        CGPath(rect: rect, transform: nil)
    }

    /// The ratio and action chips that ride next to the size label (or the pointer's pill before a drag).
    private func chips(dragging: Bool) -> [Pill] {
        var chips: [Pill] = []
        let ratio = owner.preset != .free ? owner.preset : (dragging && mods.contains(.shift) ? .square : nil)
        if let ratio { chips.append(Pill(text: ratio.label, symbol: "aspectratio")) }
        if let action = owner.action {
            chips.append(Pill(text: action.title.loc, symbol: action.symbol, filled: true, accentSymbol: action == .record))
        }
        return chips
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
        drawPills([Pill(text: label)] + chips(dragging: true), centeredAt: origin)
    }

    private func drawWindowHighlight(_ target: CaptureService.WindowTarget, in ctx: CGContext) {
        let rect = local(target.frame)
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)
        let name = target.title.isEmpty ? target.appName : "\(target.appName) — \(target.title)"
        let action = owner.action.map { [Pill(text: $0.title.loc, symbol: $0.symbol, filled: true, accentSymbol: $0 == .record)] } ?? []
        drawPills([Pill(text: String(name.prefix(60)))] + action, centeredAt: CGPoint(x: rect.midX, y: rect.midY - 11), large: true)
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

        // Before a drag the chips ride here; once a selection exists they sit by its size.
        let chips = selection == nil ? chips(dragging: false) : []
        drawPills([Pill(text: "\(Int(px)), \(Int(py))")] + chips, centeredAt: CGPoint(x: frame.midX, y: frame.minY - 26))
    }

    private func drawHint(in ctx: CGContext) {
        let text: String
        if owner.textMode { text = "Select text to copy  ·  Esc to cancel" }
        else if owner.windowMode { text = "Click a window  ·  Space for area  ·  Esc to cancel" }
        else { text = "Drag to capture  ·  Space for window  ·  ↩ full screen  ·  Esc to cancel" }
        drawPill(text, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 72), large: true)
    }

    /// A label capsule: dark glass with white text, or — for the picked action — inverted, like a selected Chip.
    fileprivate struct Pill {
        let text: String
        var symbol: String?
        var filled = false
        /// The record dot in Orbit's accent: the one spot of color.
        var accentSymbol = false
    }

    private func drawPill(_ text: String, centeredAt center: CGPoint, large: Bool = false) {
        drawPills([Pill(text: text)], centeredAt: center, large: large)
    }

    /// One or more pills in a row, the row centered on `center` (its baseline row at `center.y`).
    private func drawPills(_ pills: [Pill], centeredAt center: CGPoint, large: Bool = false) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: large ? 13 : 11, weight: .medium)
        let pad = CGSize(width: large ? 14 : 8, height: large ? 7 : 4)
        let gap: CGFloat = 6, iconGap: CGFloat = 4
        let measured = pills.map { pill -> (Pill, NSAttributedString, NSImage?, CGFloat) in
            let s = NSAttributedString(string: pill.text, attributes: [.font: font, .foregroundColor: pill.filled ? NSColor.black : NSColor.white])
            let icon = pill.symbol.flatMap { symbolImage($0, size: font.pointSize, color: pill.accentSymbol ? NSColor(Palette.accent) : (pill.filled ? .black : .white)) }
            let width = s.size().width + pad.width * 2 + (icon.map { $0.size.width + iconGap } ?? 0)
            return (pill, s, icon, width)
        }
        let total = measured.reduce(0) { $0 + $1.3 } + gap * CGFloat(max(0, measured.count - 1))
        var x = center.x - total / 2
        for (pill, s, icon, width) in measured {
            let textSize = s.size()
            let rect = CGRect(x: x, y: center.y - pad.height, width: width, height: textSize.height + pad.height * 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (pill.filled ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.72)).setFill()
            path.fill()
            if !pill.filled {
                NSColor.white.withAlphaComponent(0.14).setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            var tx = rect.minX + pad.width
            if let icon {
                icon.draw(in: CGRect(x: tx, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
                tx += icon.size.width + iconGap
            }
            s.draw(at: CGPoint(x: tx, y: rect.minY + pad.height))
            x += width + gap
        }
    }

    private func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size - 1, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

/// The strip itself never takes the mouse: drags start right through it.
private final class HintHostingView: NSHostingView<KeyHintStrip> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct KeyHint: Hashable {
    let keys: [String]
    let title: String
}

/// The key-hint strip at the bottom of the screen while selecting: keycaps and what they do,
/// on the same dark capsule as the overlay's other labels.
private struct KeyHintStrip: View {
    let items: [KeyHint]

    var body: some View {
        HStack(spacing: Space.standard) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: Space.tight + 2) {
                    HStack(spacing: 3) { ForEach(item.keys, id: \.self) { ShortcutKeys(text: $0) } }
                    Text(item.title.loc)
                        .font(.orbitCaption)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, Space.related + 2)
        .padding(.vertical, Space.compact - 1)
        .background(Capsule().fill(.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

#if DEBUG
extension SelectionOverlay {
    /// Debug: draws the real overlay offscreen over a given picture, one JPEG per state, for promo frames.
    /// The spec (JSON) gives the picture, the screen size in points, the scale, an output folder and the
    /// states: pointer, drag start and selection, top-left origin. Writes `done` into the folder at the end.
    static func debugRender(spec url: URL) {
        guard let data = try? Data(contentsOf: url),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let shotPath = spec["shot"] as? String, let out = spec["out"] as? String,
              let dims = spec["size"] as? [Double], let scale = spec["scale"] as? Double,
              let frames = spec["frames"] as? [[String: Any]],
              let picture = NSImage(contentsOfFile: shotPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.main else { return }
        let size = CGSize(width: dims[0], height: dims[1])
        let owner = SelectionOverlay(windowMode: false, textMode: false, targets: [])
        let view = OverlayView(shot: CaptureService.Snapshot(screen: screen, image: picture, scale: scale), owner: owner)
        view.frame = CGRect(origin: .zero, size: size)
        func point(_ v: Any?) -> CGPoint? {
            (v as? [Double]).map { CGPoint(x: $0[0], y: size.height - $0[1]) }
        }
        for (i, frame) in frames.enumerated() {
            let selection = (frame["sel"] as? [Double]).map { CGRect(x: $0[0], y: size.height - $0[1] - $0[3], width: $0[2], height: $0[3]) }
            view.debugSet(mouse: point(frame["mouse"]), dragStart: point(frame["start"]), selection: selection)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])
            try? jpeg?.write(to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "overlay_%04d.jpg", i)))
        }
        try? Data("\(frames.count)".utf8).write(to: URL(fileURLWithPath: out).appendingPathComponent("done"))
    }
}

extension OverlayView {
    fileprivate func debugSet(mouse: CGPoint?, dragStart: CGPoint?, selection: CGRect?) {
        self.mouse = mouse
        self.dragStart = dragStart
        self.selection = selection
    }
}
#endif
