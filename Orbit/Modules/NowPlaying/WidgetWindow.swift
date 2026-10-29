import AppKit
import SwiftUI

/// Shared between the desktop widget's window and its SwiftUI content.
@MainActor @Observable
final class WidgetState {
    var style = WidgetStyle.load()
    var hovering = false
    /// Hidden after being paused for a while ("Hide when paused").
    var pausedAway = false
    var dragging = false
    /// Briefly lifted above the windows so you can find it.
    var flashing = false
}

/// The widget on the desktop (or floating above windows): placed by anchor and offset so it stays in
/// its corner whatever its size, dragged anywhere and snapped to the screen's edges and corners.
@MainActor
final class NowPlayingWidgetController {
    static let shared = NowPlayingWidgetController()
    let state = WidgetState()

    /// Room around the card for its shadow; transparent, so clicks there fall through.
    static let margin: CGFloat = 44
    private var panel: NSPanel?
    private var cardSize = CGSize(width: 320, height: 120)
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var pauseWork: DispatchWorkItem?
    private var observers: [Any] = []

    private var enabled: Bool { Pref.defaults.bool(forKey: NowPlayingPrefs.widget) }

    func update() {
        if enabled { open() } else { close() }
    }

    /// The page edits the style through here so the widget follows live.
    func setStyle(_ style: WidgetStyle, animated: Bool = false) {
        guard style != state.style else { return }
        let levelChanged = style.level != state.style.level
        let moved = style.anchor != state.style.anchor || style.dx != state.style.dx || style.dy != state.style.dy || style.display != state.style.display
        let pauseChanged = style.hideWhenPaused != state.style.hideWhenPaused || style.hideDelay != state.style.hideDelay
        state.style = style
        style.save()
        if levelChanged { applyLevel() }
        if pauseChanged { playbackChanged() }
        if moved { place(animated: true) } else if animated { place(animated: true) }
    }

    /// Lifts the widget above every window for a moment, with a little pop, then puts it back.
    func flash() {
        guard let panel else { return }
        flashWork?.cancel()
        panel.level = .floating
        panel.orderFrontRegardless()
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { state.flashing = true }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.spring(duration: 0.35)) { self.state.flashing = false }
            self.applyLevel()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private var flashWork: DispatchWorkItem?

    private func open() {
        guard panel == nil else { place(animated: false); return }
        let p = WidgetPanel(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.animationBehavior = .none
        p.title = "Orbit Now Playing"
        // Takes the first click without needing focus; hover is tracked here too, since a window that
        // never becomes key in a background app doesn't always get SwiftUI's hover.
        let host = FirstMouseHostingView(rootView: WidgetHost(state: state, controller: self).orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = []
        let container = HoverContainer { [weak self] inside in
            guard let self, self.state.hovering != inside else { return }
            self.state.hovering = inside
            if !inside { self.playbackChanged() } // a paused widget can hide once the pointer leaves
        }
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        p.contentView = container
        panel = p
        applyLevel()
        place(animated: false)
        p.orderFrontRegardless()

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place(animated: false) }
        })
        // A floating widget would sit on top of Orbit's own window and swallow its clicks (the page's
        // switches are right under it in the top-right corner). While an Orbit window is in front,
        // the widget steps behind it; it floats again once that window loses focus.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.yieldToOrbitWindows() }
            })
        }
        watchPlayback()
        yieldToOrbitWindows()
    }

    private func close() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        pauseWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Orbit's own titled window that has focus, if any (not panels, toasts or overlays).
    private var focusedOrbitWindow: NSWindow? {
        guard let key = NSApp.keyWindow, key !== panel, key.styleMask.contains(.titled), key.isVisible else { return nil }
        return key
    }

    private func yieldToOrbitWindows() {
        guard let panel, flashWork == nil || state.flashing == false else { return }
        if state.style.level == .floating, let front = focusedOrbitWindow {
            panel.level = .normal
            panel.order(.below, relativeTo: front.windowNumber)
        } else {
            applyLevel()
        }
    }

    private func applyLevel() {
        guard let panel else { return }
        if state.style.level == .floating, let front = focusedOrbitWindow, !state.flashing {
            panel.level = .normal
            panel.order(.below, relativeTo: front.windowNumber)
            return
        }
        switch state.style.level {
        case .desktop:
            // Just above the desktop icons: under every window, like a widget on the wallpaper.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        }
    }

    // MARK: Hide when paused

    private func watchPlayback() {
        withObservationTracking {
            _ = NowPlaying.shared.playing
            _ = NowPlaying.shared.track
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel != nil else { return }
                self.playbackChanged()
                self.watchPlayback()
            }
        }
        playbackChanged()
    }

    private func playbackChanged() {
        pauseWork?.cancel()
        if NowPlaying.shared.playing || !state.style.hideWhenPaused {
            if state.pausedAway { withAnimation(.easeOut(duration: 0.3)) { state.pausedAway = false } }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !NowPlaying.shared.playing, !self.state.hovering else { return }
            withAnimation(.easeInOut(duration: 0.5)) { self.state.pausedAway = true }
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, state.style.hideDelay), execute: work)
    }

    // MARK: Placement

    func contentSized(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != cardSize else { return }
        cardSize = size
        if !state.dragging { place(animated: false) }
    }

    var screen: NSScreen {
        let name = state.style.display
        return NSScreen.screens.first { !name.isEmpty && $0.localizedName == name } ?? NSScreen.screens.first ?? NSScreen.main!
    }

    /// The card's frame for the current anchor and offsets.
    static func cardFrame(style: WidgetStyle, size: CGSize, in vf: CGRect) -> CGRect {
        let a = style.anchor
        let x: CGFloat = switch a {
        case .topLeft, .left, .bottomLeft: vf.minX + style.dx
        case .top, .center, .bottom: vf.midX - size.width / 2 + style.dx
        case .topRight, .right, .bottomRight: vf.maxX - style.dx - size.width
        }
        let y: CGFloat = switch a {
        case .topLeft, .top, .topRight: vf.maxY - style.dy - size.height
        case .left, .center, .right: vf.midY - size.height / 2 + style.dy
        case .bottomLeft, .bottom, .bottomRight: vf.minY + style.dy
        }
        // Never off screen, whatever was saved.
        return CGRect(x: min(max(x, vf.minX), vf.maxX - size.width), y: min(max(y, vf.minY), vf.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private func place(animated: Bool) {
        guard let panel else { return }
        let vf = screen.visibleFrame
        let card = Self.cardFrame(style: state.style, size: cardSize, in: vf)
        let frame = card.insetBy(dx: -Self.margin, dy: -Self.margin)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: Dragging

    func drag(_ value: DragGesture.Value?) {
        guard let panel, !state.style.locked else { return }
        guard value != nil else { endDrag(); return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, panel.frame.origin)
            state.dragging = true
        }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }

    private func endDrag() {
        guard let panel, dragStart != nil else { return }
        dragStart = nil
        state.dragging = false
        let card = panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
        let target = NSScreen.screens.max { $0.frame.intersection(card).area < $1.frame.intersection(card).area } ?? screen
        var style = state.style
        style.display = target == NSScreen.screens.first ? "" : target.localizedName
        Self.snap(card, in: target.visibleFrame, into: &style)
        if style == state.style { place(animated: true) }
        setStyle(style, animated: true)
    }

    /// Picks the anchor of the ninth of the screen the card's center is in, and the offsets from it,
    /// pulling to the standard margin (or dead center) when close.
    static func snap(_ card: CGRect, in vf: CGRect, into style: inout WidgetStyle) {
        let col = card.midX < vf.minX + vf.width / 3 ? 0 : card.midX > vf.maxX - vf.width / 3 ? 2 : 1
        let row = card.midY > vf.maxY - vf.height / 3 ? 0 : card.midY < vf.minY + vf.height / 3 ? 2 : 1
        let anchors: [[WidgetStyle.Anchor]] = [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]]
        style.anchor = anchors[row][col]
        let edge: Double = 24, pull: Double = 18
        var dx: Double = switch col {
        case 0: card.minX - vf.minX
        case 1: card.midX - vf.midX
        default: vf.maxX - card.maxX
        }
        var dy: Double = switch row {
        case 0: vf.maxY - card.maxY
        case 1: card.midY - vf.midY
        default: card.minY - vf.minY
        }
        if col == 1 { if abs(dx) < pull { dx = 0 } } else if abs(dx - edge) < pull || dx < edge { dx = edge }
        if row == 1 { if abs(dy) < pull { dy = 0 } } else if abs(dy - edge) < pull || dy < edge { dy = edge }
        style.dx = dx.rounded()
        style.dy = dy.rounded()
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// Reports whether the pointer is over the card (the window minus its transparent shadow margin).
private final class HoverContainer: NSView {
    private let changed: (Bool) -> Void
    private var inside = false

    init(changed: @escaping (Bool) -> Void) {
        self.changed = changed
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseMoved(with event: NSEvent) { update(event) }
    override func mouseEntered(with event: NSEvent) { update(event) }
    override func mouseExited(with event: NSEvent) { set(false) }

    private func update(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        set(bounds.insetBy(dx: NowPlayingWidgetController.margin, dy: NowPlayingWidgetController.margin).contains(p))
    }

    private func set(_ v: Bool) {
        guard v != inside else { return }
        inside = v
        changed(v)
    }
}

/// Never takes focus from the app you're in, but still takes clicks.
private final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct WidgetHost: View {
    @Bindable var state: WidgetState
    let controller: NowPlayingWidgetController

    var body: some View {
        let style = state.style
        let content = WidgetContent.current() ?? (style.hideWhenIdle ? nil : .idle)
        ZStack {
            if let content, !state.pausedAway {
                NowPlayingWidgetView(style: style, content: content, hovering: state.hovering) { controller.drag($0) }
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { controller.contentSized($0) }
                    .scaleEffect(state.flashing ? 1.04 : 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .contextMenu { WidgetMenu(state: state, controller: controller) }
            }
        }
        .padding(NowPlayingWidgetController.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: content == nil)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: style)
    }
}

private struct WidgetMenu: View {
    let state: WidgetState
    let controller: NowPlayingWidgetController

    var body: some View {
        Button(state.style.locked ? "Unlock Position" : "Lock Position") {
            var s = state.style; s.locked.toggle(); controller.setStyle(s)
        }
        Button(state.style.level == .desktop ? "Float Above Windows" : "Keep on Desktop") {
            var s = state.style; s.level = s.level == .desktop ? .floating : .desktop; controller.setStyle(s)
        }
        if NowPlaying.shared.track != nil {
            Button("Open %@".loc(NowPlaying.shared.track?.appName ?? "Player".loc)) { NowPlaying.shared.openSource() }
        }
        Divider()
        Button("Now Playing Settings…") { MainWindow.show(.nowPlaying) }
        Button("Hide Widget") {
            Pref.defaults.set(false, forKey: NowPlayingPrefs.widget)
            NowPlaying.shared.update()
        }
    }
}

extension WidgetContent {
    /// "Not Playing", for when the widget stays up with nothing on.
    @MainActor static let idle = WidgetContent(title: "Not Playing".loc, artist: "", album: "", artwork: nil, palette: .neutral,
                                               playing: false, liked: false, duration: 0, elapsed: { _ in 0 },
                                               appIcon: nil, appName: nil, generation: -1, live: false)
}
