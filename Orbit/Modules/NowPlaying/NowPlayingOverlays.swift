import AppKit
import SwiftUI

// MARK: - Song-change banner

/// A short banner when the song changes: cover, title, artist. Click it to open the player.
@MainActor
final class TrackPopup {
    static let shared = TrackPopup()

    enum Place: String, CaseIterable { case notch, topRight, bottom }

    private var panel: FloatingPanel?
    private var hideWork: DispatchWorkItem?
    private let model = PopupModel()

    func show(_ track: NowPlaying.Track) {
        let d = Pref.defaults
        guard d.bool(forKey: NowPlayingPrefs.popup) else { return }
        // The player in front already shows it.
        if let bundle = track.bundle, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle { return }
        if d.object(forKey: NowPlayingPrefs.popupOnlyHidden) as? Bool ?? true,
           d.bool(forKey: NowPlayingPrefs.widget), NowPlayingWidgetController.shared.state.style.level == .floating { return }
        present()
    }

    /// Shows the banner for the current song, from the settings page's "Try it".
    func preview() { present(force: true) }

    /// The song's cover (or anything else about it) came in after the banner went up: show it there too.
    func refresh() {
        guard let content = WidgetContent.current() else { return }
        NotchPlayer.shared.refreshBanner(content)
        if model.shown, model.content.generation == content.generation {
            withAnimation(.easeOut(duration: 0.2)) { model.content = content }
        }
    }

    private func present(force: Bool = false) {
        guard let content = WidgetContent.current() ?? (force ? .sample : nil) else { return }
        let place = Place(rawValue: Pref.defaults.string(forKey: NowPlayingPrefs.popupPlace) ?? "") ?? .notch
        // From the notch, it's the notch itself that grows; a separate panel is only for screens without one.
        if place == .notch, NotchPlayer.shared.showBanner(content) { return }
        let p = panel ?? {
            let p = FloatingPanel(contentRect: .zero, focusable: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.hasShadow = false
            p.collectionBehavior.insert(.stationary)
            p.setContent(PopupView(model: model))
            return p
        }()
        panel = p
        model.content = content
        model.place = place
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = CGSize(width: 380, height: 120)
        let f = screen.frame, vf = screen.visibleFrame
        let origin: CGPoint = switch place {
        case .notch: CGPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
        case .topRight: CGPoint(x: vf.maxX - size.width - 4, y: vf.maxY - size.height + 8)
        case .bottom: CGPoint(x: vf.midX - size.width / 2, y: vf.minY + 12)
        }
        p.setFrame(CGRect(origin: origin, size: size), display: false)
        model.notchHeight = screen.safeAreaInsets.top
        p.orderFrontRegardless()
        withAnimation(.spring(duration: 0.5, bounce: 0.22)) { model.shown = true }
        scheduleHide()
        model.onHover = { [weak self] h in
            if h { self?.hideWork?.cancel() } else { self?.scheduleHide(after: 1.2) }
        }
    }

    private func scheduleHide(after delay: Double = 3.6) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.model.shown = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if !self.model.shown { self.panel?.orderOut(nil) } }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

@MainActor @Observable
private final class PopupModel {
    var content: WidgetContent = .idle
    var place: TrackPopup.Place = .notch
    var shown = false
    var notchHeight: CGFloat = 0
    var onHover: ((Bool) -> Void)?
}

private struct PopupView: View {
    let model: PopupModel

    var body: some View {
        let c = model.content
        let notch = model.place == .notch
        VStack {
            if !notch { Spacer(minLength: 0) }
            if model.shown {
                HStack(spacing: 12) {
                    Group {
                        if let art = c.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                        else { CoverPlaceholder(appIcon: c.appIcon, side: 46) }
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Now Playing".loc.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                            .foregroundStyle(c.palette.accent)
                        Text(c.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        if !c.artist.isEmpty { Text(c.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
                    }
                    .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Equalizer(playing: c.playing, color: c.palette.accent).frame(width: 16, height: 14)
                }
                .padding(.horizontal, 14)
                .padding(.top, notch ? max(10, model.notchHeight + 6) : 10)
                .padding(.bottom, 10)
                .frame(width: 340)
                .background {
                    ZStack {
                        if notch { Color.black } else { c.palette.background }
                        if !notch, let art = c.artwork { Image(nsImage: art).resizable().scaleEffect(1.5).blur(radius: 30).opacity(0.6) }
                    }
                }
                .clipShape(HangingShape(radius: notch ? 22 : 20, top: notch ? 0 : 20))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .onHover { model.onHover?($0) }
                .onTapGesture { NowPlaying.shared.openSource() }
                .transition(notch ? .move(edge: .top).combined(with: .opacity) : .scale(scale: 0.9).combined(with: .opacity))
            }
            if notch { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Notch live activity

/// Wings either side of the notch while music plays — the cover on the left, dancing bars on the right —
/// that open into a little player when the pointer comes near. The song-change banner grows out of the
/// same shape. Only on screens with a notch.
@MainActor
final class NotchPlayer {
    static let shared = NotchPlayer()
    private var panel: NSPanel?
    let model = NotchPlayerModel()
    private var observers: [Any] = []
    private var bannerWork: DispatchWorkItem?

    private var enabled: Bool { Pref.defaults.bool(forKey: NowPlayingPrefs.notch) }

    static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil } }

    func update() {
        // Orbit's notch draws the music itself.
        if NotchCenter.enabled {
            model.wings = false
            if model.banner == nil { close() }
            return
        }
        model.wings = enabled
        if enabled { open() } else if model.banner == nil { close() }
    }

    /// The banner, grown out of the notch. False when there's no notch to grow it from.
    func showBanner(_ content: WidgetContent) -> Bool {
        if NotchCenter.enabled { return NotchCenter.shared.showBanner(content) }
        guard Self.notchScreen != nil else { return false }
        open()
        model.banner = content
        model.onHover = { [weak self] h in
            guard let self, self.model.banner != nil else { return }
            if h { self.bannerWork?.cancel() } else { self.scheduleBannerEnd(after: 1.2) }
        }
        scheduleBannerEnd(after: 3.6)
        return true
    }

    func refreshBanner(_ content: WidgetContent) {
        if NotchCenter.enabled { NotchCenter.shared.refreshBanner(content); return }
        guard let banner = model.banner, banner.generation == content.generation else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.banner = content }
    }

    private func scheduleBannerEnd(after delay: Double) {
        bannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.model.banner = nil
            // Shrunk back into the notch; then out of the way if the wings are off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !self.enabled, self.model.banner == nil { self.close() }
            }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func open() {
        guard let screen = Self.notchScreen else { close(); return }
        let p = panel ?? {
            let p = NotchPanel(contentRect: NSRect(x: -20000, y: -20000, width: 440, height: 210),
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.animationBehavior = .none
            let host = FirstMouseHostingView(rootView: NotchPlayerView(model: model).orbitTint())
            host.sizingOptions = []
            host.safeAreaRegions = []
            p.contentView = FloatingPanel.container(for: host)
            return p
        }()
        if panel == nil {
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NotchPlayer.shared.update() }
            })
        }
        panel = p
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            model.notch = CGSize(width: screen.frame.width - l.width - r.width, height: screen.frame.maxY - min(l.minY, r.minY))
        }
        let size = CGSize(width: 440, height: 210)
        p.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
    }

    private func close() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Flush with the top of the screen: AppKit would otherwise nudge a window off the menu bar.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct NotchPlayerView: View {
    @Bindable var model: NotchPlayerModel

    var body: some View {
        // Out of the way while App Lock's face check uses the notch.
        NotchPlayerBody(model: model, content: NotchHUD.shared.isShowing ? nil : WidgetContent.current())
    }
}
