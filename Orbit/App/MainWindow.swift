import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, ring, capture, clipboard, windows, translate, spell, snippets, passwords, input, menubar, corners, runner, applock, sound, nowPlaying, notch, storage, awake, battery, displays, archives, apps, system, overlaps, shortcuts, setup, general
    var id: String { rawValue }

    var title: String { englishTitle.loc }

    private var englishTitle: String {
        switch self {
        case .home: "Home"
        case .ring: "Orbit Ring"
        case .capture: "Capture"
        case .clipboard: "Clipboard"
        case .windows: "Windows"
        case .translate: "Translate"
        case .spell: "Spelling"
        case .snippets: "Snippets"
        case .passwords: "Passwords"
        case .nowPlaying: "Now Playing"
        case .notch: "Notch"
        case .battery: "Battery"
        case .displays: "Displays"
        case .archives: "Archives"
        case .apps: "Apps"
        case .input: "Korean Input"
        case .menubar: "Menu Bar"
        case .corners: "Hot Corners"
        case .runner: "Runner"
        case .applock: "Face Unlock"
        case .sound: "Sound"
        case .storage: "Storage"
        case .awake: "Awake"
        case .system: "System"
        case .overlaps: "Overlapping Apps"
        case .shortcuts: "Shortcuts"
        case .setup: "Permissions"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .ring: "circle.dashed"
        case .capture: "viewfinder"
        case .clipboard: "doc.on.clipboard"
        case .windows: "rectangle.split.2x1"
        case .translate: "character.bubble"
        case .spell: "textformat.abc.dottedunderline"
        case .snippets: "text.badge.plus"
        case .passwords: "key.horizontal"
        case .nowPlaying: "music.note"
        case .notch: "rectangle.topthird.inset.filled"
        case .battery: "battery.75percent"
        case .displays: "display.2"
        case .archives: "archivebox"
        case .apps: "square.grid.3x3"
        case .input: "keyboard.badge.ellipsis"
        case .menubar: "menubar.rectangle"
        case .corners: "cursorarrow.motionlines"
        case .runner: "hare"
        case .applock: "faceid"
        case .sound: "speaker.wave.2"
        case .storage: "internaldrive"
        case .awake: "cup.and.saucer"
        case .system: "cpu"
        case .overlaps: "square.on.square.dashed"
        case .shortcuts: "keyboard"
        case .setup: "lock.shield"
        case .general: "gearshape"
        }
    }

    /// Sidebar groups; the first has no heading.
    static let sections: [(title: String?, pages: [Page])] = [
        (nil, [.home, .ring]),
        ("Essentials", [.capture, .clipboard, .windows, .translate, .spell, .snippets, .passwords]),
        ("Utilities", [.sound, .nowPlaying, .notch, .input, .awake, .menubar, .corners, .runner, .applock]),
        ("Mac", [.apps, .system, .displays, .battery, .storage, .archives]),
        ("Settings", [.overlaps, .shortcuts, .setup, .general]),
    ]
}

@MainActor @Observable
final class AppRouter {
    var page: Page = .home
    let search = SettingsSearchModel()
    /// Rows and group cards ("row:<title>", "group:<title>") glowing after search led to them.
    var focus: Set<String> = []
    /// Where to scroll once the page is up; `revealToken` changes each time.
    private(set) var pendingReveal: [String] = []
    private(set) var revealToken = 0

    /// Opens a page and points at the rows that answered a search.
    func reveal(_ page: Page, _ ids: [String]) {
        pendingReveal = ids
        if self.page != page {
            withAnimation(Motion.adaptive(.spring(duration: 0.32, bounce: 0.12))) { self.page = page }
        }
        revealToken += 1
    }
}

/// Orbit's app window. Opening it gives Orbit a Dock icon and ⌘-Tab presence; closing returns to menu-bar mode.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    let router = AppRouter()
    private var window: NSWindow?

    static func show(_ page: Page? = nil) { shared.show(page) }

    func show(_ page: Page?) {
        if let page {
            withAnimation(Motion.adaptive(.spring(duration: 0.32, bounce: 0.12))) { router.page = page }
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Orbit"
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 880, height: 680)
            w.delegate = self
            let host = NSHostingView(rootView: MainView(router: router).orbitTint())
            host.sizingOptions = []
            host.safeAreaRegions = [] // no titlebar safe-area feedback into layout (constraint-loop crash)
            // Hosted inside a plain view: a hosting view as the content view resizes the window during
            // layout, which loops "Update Constraints" until AppKit aborts (seen when a sheet closes).
            w.contentView = FloatingPanel.container(for: host)
            w.center()
            w.setFrameAutosaveName("OrbitMain")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.bringToFront()
    }

    var isOpen: Bool { window?.isVisible == true }

    func close() { window?.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu-bar app once nothing but panels is left. The whole page tree goes with
        // the window, so a closed window doesn't keep pages sampling and redrawing in the background.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            guard let w = self.window, !w.isVisible else { return }
            w.contentView = nil
            self.window = nil
        }
    }

    /// Window layouts are for the window behind Orbit's, so step aside first. Captures keep Orbit
    /// in the picture — it's something you may want to capture.
    func perform(_ action: OrbitAction) {
        if action.windowLayout != nil {
            window?.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action.perform() }
        } else {
            action.perform()
        }
    }
}

struct MainView: View {
    @Bindable var router: AppRouter

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(router: router)
                .frame(width: 228)
            Rectangle().fill(Palette.hairline).frame(width: 1)
            // The reader sits outside the per-page scroll view, so it sees a search reveal that
            // arrives together with the page change.
            ScrollViewReader { proxy in
                ZStack {
                    Palette.page
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id(Self.top)
                            page
                            PageShortcuts(page: router.page)
                        }
                            .padding(.horizontal, 40)
                            .padding(.top, 52)
                            .padding(.bottom, 40)
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.automatic)
                    .id(router.page)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                }
                .onChange(of: router.revealToken) { reveal(proxy) }
            }
            .clipped()
        }
        .frame(minWidth: 880, minHeight: 680)
        .onAppear {
            Permissions.shared.watch(true)
            router.search.install(router: router)
        }
        .onDisappear {
            Permissions.shared.watch(false)
            router.search.uninstall()
        }
    }

    /// Scrolls to what search found once the new page has laid out, then makes it glow twice.
    private func reveal(_ proxy: ScrollViewProxy) {
        let ids = router.pendingReveal
        let token = router.revealToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard router.revealToken == token else { return }
            if ids.isEmpty {
                withAnimation(Motion.adaptive(.spring(duration: 0.4))) { proxy.scrollTo(Self.top, anchor: .top) }
                return
            }
            // A ternary title has an anchor per wording; only the one on screen exists to scroll to.
            withAnimation(Motion.adaptive(.spring(duration: 0.45, bounce: 0.08))) {
                for id in ids { proxy.scrollTo(id, anchor: .center) }
            }
            try? await Task.sleep(for: .milliseconds(320))
            for (on, pause) in [(true, 380), (false, 180), (true, 900), (false, 0)] {
                guard router.revealToken == token else { return }
                withAnimation(.easeInOut(duration: on ? 0.22 : 0.35)) { router.focus = on ? Set(ids) : [] }
                if pause > 0 { try? await Task.sleep(for: .milliseconds(pause)) }
            }
        }
    }

    private static let top = "page-top"

    @ViewBuilder private var page: some View {
        switch router.page {
        case .home: HomePage(router: router)
        case .ring: RingPage()
        case .capture: CapturePage()
        case .clipboard: ClipboardPage()
        case .windows: WindowsPage()
        case .awake: AwakePage()
        case .system: SystemPage()
        case .translate: TranslatePage()
        case .spell: SpellPage()
        case .input: InputPage()
        case .menubar: MenuBarPage()
        case .corners: HotCornersPage()
        case .runner: RunnerPage()
        case .applock: AppLockPage()
        case .sound: SoundPage()
        case .storage: StoragePage()
        case .snippets: SnippetsPage()
        case .passwords: PasswordsPage()
        case .nowPlaying: NowPlayingPage()
        case .notch: NotchPage()
        case .battery: BatteryPage()
        case .displays: DisplaysPage()
        case .archives: ArchivesPage()
        case .apps: AppsPage()
        case .overlaps: OverlapsPage()
        case .shortcuts: ShortcutsPage()
        case .setup: SetupPage()
        case .general: GeneralPage()
        }
    }
}

private struct Sidebar: View {
    @Bindable var router: AppRouter
    @Namespace private var selection
    private var permissions: Permissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: Brand.logo).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Orbit").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("Every Mac utility, all in one").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.top, 48)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)

            SettingsSearchField(model: router.search)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if router.search.active {
                SettingsSearchResults(model: router.search)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Page.sections, id: \.pages) { section in
                        if let title = section.title {
                            Text(title.loc.uppercased())
                                .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(Palette.inkSecondary.opacity(0.8))
                                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 5)
                        }
                        VStack(spacing: 2) {
                            ForEach(section.pages) { item(for: $0) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            }
            // Only while something still needs allowing; once everything is ready it gets out of the way.
            if !(permissions.screenCapture && permissions.accessibility) {
                statusCard
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.35), value: permissions.screenCapture && permissions.accessibility)
        .background(Palette.sidebar)
    }

    private func item(for page: Page) -> some View {
        let selected = router.page == page
        return Button {
            withAnimation(Motion.adaptive(.spring(duration: 0.32, bounce: 0.12))) { router.page = page }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if page == .awake, KeepAwake.shared.isOn {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                }
                if page == .setup, !(permissions.screenCapture && permissions.accessibility) {
                    Circle().fill(Palette.accent).frame(width: 7, height: 7)
                }
            }
            .foregroundStyle(selected ? Palette.ink : Palette.inkSecondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 10)
    }

    private var statusCard: some View {
        let ready = permissions.screenCapture && permissions.accessibility
        return Button { withAnimation(.spring(duration: 0.3)) { router.page = .setup } } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(Palette.hairline, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat([permissions.screenCapture, permissions.accessibility].filter { $0 }.count) / 2)
                        .stroke(ready ? Palette.ink : Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .animation(.spring(duration: 0.5), value: ready)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ready ? "All set" : "Finish setup").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(ready ? "Every feature is ready" : "Allow access to unlock everything")
                        .font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
