import SwiftUI
import QuartzCore
import KeyboardShortcuts

@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The planet is an AppKit status item (OrbitPlanet), only there when the user wants it, so
        // the app's one scene is an empty, never-opened Settings.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { MainWindow.show(.general) }.keyboardShortcut(",")
                }
            }
    }
}

/// Orbit's planet in the menu bar — off by default (General); the ✦, the ring and shortcuts
/// reach everything without it. Added and removed outright, so no empty slot stays behind.
@MainActor
enum OrbitPlanet {
    private static var item: NSStatusItem?

    static func apply() {
        let show = Pref.defaults.bool(forKey: Pref.showOrbitIcon)
        if show, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // The name SwiftUI used to give it, so it comes back where the user left it.
            item.autosaveName = "Item-0"
            item.menu = NSHostingMenu(rootView: MenuContent())
            self.item = item
            refreshIcon()
        } else if !show, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// The dot on the planet while the Mac is kept awake.
    static func refreshIcon() {
        guard let item else { return }
        item.button?.image = KeepAwake.shared.isOn ? MenuBarIcon.awake : MenuBarIcon.image
        withObservationTracking { _ = KeepAwake.shared.isOn } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { refreshIcon() } }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // SwiftUI's MenuBarExtra item; keep Orbit's mark next to the calendar on the right.
        Pref.seedMenuBarPosition("Item-0", 120)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        NotchPrefs.register()
        _ = Permissions.shared
        ClipboardStore.shared.start()
        Paster.start()
        SnippetEngine.shared.start()
        Vault.shared.start()
        AppIndex.shared.start()
        MouseTrigger.shared.start()
        HotCorners.shared.start()
        Knock.shared.start() // only when it's on
        Gestures.shared.start() // each source only while a rule needs it
        AppsCatalog.shared.start()
        Shelf.shared.startEdgeReveal()
        KeepAwake.shared.recoverIfNeeded()
        TranslateController.shared.start()
        AudioMixer.shared.start()
        MenuBarHider.shared.apply()
        OrbitPlanet.apply()
        MenuBarCalendar.shared.apply()
        FanControl.shared.start()
        BatteryManager.shared.start()
        DisplayManager.shared.start() // only when Displays is on
        FaceUnlock.start()
        ScrollReverser.shared.start()
        MacUnlock.shared.start()
        MenuBarRunner.shared.start()
        Archives.shared.start()
        NowPlaying.shared.update() // listens only if a Now Playing feature is on
        NotchCenter.shared.apply()
        Updater.shared.start() // first look 30s in, then every 6 hours
        ReleaseNotes.shared.launched() // what's new, once after an update
        TaviBridge.shared.startUpdates() // Tavi too: a minute in, then daily
        // The Storage page opens with last time's breakdown; refresh it quietly once Orbit has settled in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { StorageModel.shared.refreshInBackground() }
        // The panels people open by shortcut, built ahead (once launch has settled) so even the first
        // open shows at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            LauncherPanel.shared.prewarm()
            ClipboardPanel.shared.prewarm()
            AppsPanel.shared.prewarm()
        }
        registerShortcuts()
        Overlaps.shared.refresh()
        #if DEBUG
        DebugHook.install()
        #endif

        // Accessibility may be granted later — start the mouse trigger once it is.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                MouseTrigger.shared.start()
                TranslateController.shared.start() // key monitoring starts working once Accessibility is granted
                FanControl.shared.refresh() // the helper may have just been allowed in System Settings
                Overlaps.shared.refresh()
            }
        }

        if !Pref.defaults.bool(forKey: Pref.onboarded) {
            OnboardingWindow.show()
        }
    }

    /// Archives double-clicked in Finder once Orbit opens them (Archives page).
    func application(_ application: NSApplication, open urls: [URL]) {
        Archives.shared.open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioMixer.shared.shutdown() // never leave an app's audio muted behind a dead tap
    }

    /// ⌘Q or Dock → Quit while the window is open only closes the window: Orbit keeps running in
    /// the menu bar. Quitting for real goes through "Quit Orbit" in the menu bar menu (or General).
    /// Logging out, restarting and shutting down always quit.
    /// Closed-lid mode must never outlive Orbit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !AppQuit.confirmed, !AppQuit.systemIsEnding, MainWindow.shared.isOpen {
            MainWindow.shared.close()
            return .terminateCancel
        }
        guard KeepAwake.shared.closedLidActive else { return .terminateNow }
        Task {
            await KeepAwake.shared.restoreForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Clicking Orbit in the Dock or Finder while it's running opens the app window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .ring) { OrbitRing.shared.open(hold: true) }
        KeyboardShortcuts.onKeyUp(for: .ring) { OrbitRing.shared.release() }

        for action in OrbitAction.allCases {
            guard let name = action.shortcutName else { continue }
            KeyboardShortcuts.onKeyDown(for: name) { action.perform() }
        }
    }
}

private struct MenuContent: View {
    private var capture: CaptureService { .shared }

    var body: some View {
        Button("Open Orbit") { MainWindow.show() }
        Divider()
        Button("Open Orbit Ring") { OrbitRing.shared.open(hold: false) }
        Button("Open Launcher") { LauncherPanel.shared.show() }
        Button("Clipboard History") { ClipboardPanel.shared.show() }
        Divider()
        Section("Capture") {
            ForEach([OrbitAction.captureArea, .captureWindow, .captureScreen, .captureText]) { a in
                Button { a.perform() } label: { Label(a.title, systemImage: a.symbol) }
            }
            if !capture.recent.isEmpty {
                Menu("Recent Captures") {
                    ForEach(capture.recent.prefix(8)) { c in
                        Button(c.date.formatted(date: .omitted, time: .shortened) + " · " + c.fileURL.deletingPathExtension().lastPathComponent) {
                            EditorWindow.open(image: c.image, fileURL: c.fileURL)
                        }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.open(CaptureService.dir) }
                }
            }
        }
        Divider()
        Menu(KeepAwake.shared.isOn ? "Awake · " + KeepAwake.describe(KeepAwake.shared.session ?? .indefinite) : "Keep Mac Awake") {
            if KeepAwake.shared.isOn {
                Button("Turn Off") { KeepAwake.shared.stop() }
                Divider()
            }
            Button("15 Minutes") { KeepAwake.shared.start(for: 900) }
            Button("1 Hour") { KeepAwake.shared.start(for: 3600) }
            Button("4 Hours") { KeepAwake.shared.start(for: 14400) }
            Button("Until I Turn It Off") { KeepAwake.shared.start(for: nil) }
            Divider()
            Toggle("Closed-Lid Mode", isOn: Binding(get: { KeepAwake.closedLid }, set: { KeepAwake.shared.setClosedLid($0) }))
            Button("More Options…") { MainWindow.show(.awake) }
        }
        Button("Shelf") { Shelf.shared.toggle() }
        Button("Pick Color") { SystemActions.pickColor() }
        Toggle("Pause Clipboard", isOn: Binding(get: { ClipboardStore.shared.paused },
                                                set: { $0 ? ClipboardStore.shared.pause(for: nil) : ClipboardStore.shared.resume() }))
        Divider()
        Button("Settings…") { MainWindow.show(.general) }.keyboardShortcut(",")
        Button("Quit Orbit") { AppQuit.now() }.keyboardShortcut("q")
    }
}

/// The Orbit mark; gains its satellite while Keep Awake runs.
/// Template menu bar glyph: the Orbit mark, rendered once and tinted by the menu bar.
enum MenuBarIcon {
    @MainActor static let image = render(dot: false)
    @MainActor static let awake = render(dot: true)

    @MainActor private static func render(dot: Bool) -> NSImage {
        let renderer = ImageRenderer(content: OrbitMark(size: 20, color: .black, dot: dot).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true
        return image
    }
}

enum AppQuit {
    @MainActor static var confirmed = false

    /// Quit for real (menu bar menu, General page).
    @MainActor static func now() {
        confirmed = true
        NSApp.terminate(nil)
    }

    /// A quit Apple event that carries a reason comes from logout, restart or shutdown.
    static var systemIsEnding: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else { return false }
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
}

#if DEBUG
/// Lets scripts open any surface for visual checks:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().post(name: .init("com.lyu.orbit.debug"), object: "ring")'
enum DebugHook {
    @MainActor static func install() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.lyu.orbit.debug"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
    }

    @MainActor static func run(_ command: String) {
        switch command {
        case "ring": OrbitRing.shared.open(hold: true) // hold: no dwell or flick fires while a script inspects it
        case "launcher": LauncherPanel.shared.show()
        case "clipboard": ClipboardPanel.shared.show()
        case "onboarding": OnboardingWindow.show()
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "system": NSApp.appearance = nil
        case "close": OrbitRing.shared.close(); LauncherPanel.shared.hide(); ClipboardPanel.shared.hide(); AppsPanel.shared.hide()
        case let c where c.hasPrefix("fan:"):
            FanControl.shared.mode = FanControl.Mode(rawValue: String(c.dropFirst(4))) ?? .auto
        case let c where c.hasPrefix("page:"):
            MainWindow.show(Page(rawValue: String(c.dropFirst(5))) ?? .home)
        case let c where c.hasPrefix("type:"):
            LauncherPanel.shared.debugType(String(c.dropFirst(5)))
        case let c where c.hasPrefix("editor:"):
            if let image = NSImage(contentsOfFile: String(c.dropFirst(7))) { EditorWindow.open(image: image, fileURL: nil) }
        case "apps": AppsPanel.shared.show()
        case "gestures-selftest":
            // The trackpad recognizer against made-up touches; results land in gestures.log.
            let lines = TouchRecognizer.selfTest()
            lines.forEach { GestureLog.write("selftest \($0)") }
            GestureLog.write("selftest: \(lines.filter { $0.hasPrefix("FAIL") }.count) of \(lines.count) failed")
        case "playpause": NowPlaying.shared.togglePlayPause(heard: true)
        case "widget-themes": NowPlayingWidgetController.shared.debugCycleThemes()
        case "bench-apps":
            // Opens the Apps grid five times and logs how its first two seconds play: main-thread
            // frame gaps are what reads as lag.
            FrameMeter.bench(label: "apps", runs: 5, open: { AppsPanel.shared.show() }, close: { AppsPanel.shared.hide() })
        case let c where c.hasPrefix("movable:"):
            NSApp.windows.first { $0.title == "Orbit" }?.isMovableByWindowBackground = c.hasSuffix("1")
        case "bench-layout":
            // Lays the main window out 20 times at alternating widths: what a resize or a
            // relayout costs.
            guard let w = NSApp.windows.first(where: { $0.title == "Orbit" && $0.isVisible }) else { break }
            let original = w.frame
            let started = CACurrentMediaTime()
            for i in 0..<20 {
                var f = original
                f.size.width += i % 2 == 0 ? 8 : 0
                w.setFrame(f, display: true)
                w.contentView?.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
            }
            w.setFrame(original, display: true)
            let ms = (CACurrentMediaTime() - started) * 1000 / 20
            let line = "\(Date()) bench-layout movable=\(w.isMovableByWindowBackground): \(String(format: "%.1f", ms))ms per layout\n"
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit/perf.log")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? Data(line.utf8).write(to: url) }
        case let c where c.hasPrefix("promo:"):
            promo(URL(fileURLWithPath: String(c.dropFirst(6))))
        case let c where c.hasPrefix("time:"):
            // How long a command takes until its window has drawn (two run-loop turns later).
            let inner = String(c.dropFirst(5))
            let started = CACurrentMediaTime()
            run(inner)
            DispatchQueue.main.async {
                CATransaction.flush()
                DispatchQueue.main.async {
                    let ms = (CACurrentMediaTime() - started) * 1000
                    let line = "\(Date()) \(inner): \(String(format: "%.1f", ms))ms\n"
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit/perf.log")
                    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? Data(line.utf8).write(to: url) }
                }
            }
        default: break
        }
    }

    @MainActor static func perfLog(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit/perf.log")
        let line = "\(Date()) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    /// Promo frames from Orbit's real components. The JSON spec names a `kind` and its state; window
    /// kinds write their window number to `wid` for `screencapture -l`, render kinds write PNGs to `out`.
    @MainActor private static func promo(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = spec["kind"] as? String else { return }
        func point(_ key: String) -> CGPoint {
            let v = spec[key] as? [Double] ?? [0, 0]
            return CGPoint(x: v[0], y: v[1])
        }
        func image(_ key: String) -> NSImage? {
            guard let path = spec[key] as? String, let im = NSImage(contentsOfFile: path),
                  let rep = im.representations.first else { return nil }
            im.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2) // 2x pictures
            return im
        }
        func png(_ view: some View, scale: CGFloat, to path: String) {
            let renderer = ImageRenderer(content: view.orbitTint().environment(\.colorScheme, .dark))
            renderer.scale = scale
            guard let cg = renderer.cgImage else { return }
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        var wid: Int?
        switch kind {
        case "overlay":
            SelectionOverlay.debugRender(spec: url)
        case "ring":
            wid = OrbitRing.shared.debugPose(appear: spec["appear"] as? Double ?? 1, angle: spec["angle"] as? Double)
        case "ring-close":
            OrbitRing.shared.debugClose()
        case "toast":
            guard let backdrop = image("backdrop") else { return }
            wid = Toast.debugStage(spec["message"] as? String ?? "Copied", symbol: spec["symbol"] as? String ?? "checkmark.circle.fill",
                                   detail: spec["detail"] as? String, backdrop: backdrop, bottom: spec["bottom"] as? Double ?? 64)
        case "toast-close":
            Toast.debugUnstage()
        case "quickaccess":
            guard let picture = image("image") else { return }
            wid = QuickAccess.shared.debugShow(picture, fileURL: URL(fileURLWithPath: spec["image"] as? String ?? "/tmp/Orbit.png"))
        case "quickaccess-close":
            QuickAccess.shared.debugClear()
        case "editor-drag", "editor-end":
            wid = EditorWindow.debugDrag(from: spec["from"] == nil ? nil : point("from"), to: point("to"),
                                         done: kind == "editor-end", tool: spec["tool"] as? String)
        case "editor-close":
            EditorWindow.debugCloseAll()
        case "notch-info":
            // `probe`: test a point instead of the pointer (no event is sent), then go back to the real one.
            var probed: [[String: Any]] = []
            // `fullScreen`: window rects [x, y, w, h] (CG) to classify against the main screen.
            if let rects = spec["fullScreen"] as? [[Double]], let out = spec["out"] as? String, let screen = NSScreen.screens.first {
                let result = rects.map { r in
                    ["rect": r, "full": NotchCenter.fillsScreen(CGRect(x: r[0], y: r[1], width: r[2], height: r[3]),
                                                             CGRect(origin: .zero, size: screen.frame.size), housing: screen.safeAreaInsets.top)] as [String: Any]
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { try? data.write(to: URL(fileURLWithPath: out)) }
                return
            }
            if let probe = spec["probe"] as? [Double] {
                NotchCenter.shared.pointerMoved(NSPoint(x: probe[0], y: probe[1]))
                probed = NotchCenter.shared.debugInfo()
                NotchCenter.shared.pointerMoved(NSEvent.mouseLocation)
            }
            if !probed.isEmpty, let out = spec["out"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: ["probe": probed, "after": NotchCenter.shared.debugInfo()], options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            } else if let out = spec["out"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: NotchCenter.shared.debugInfo(), options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
        case "notch":
            if let title = spec["title"] as? String {
                NowPlaying.shared.debugPlaceholder(title: title, artist: spec["artist"] as? String ?? "", duration: spec["duration"] as? Double ?? 200,
                                                   elapsed: spec["elapsed"] as? Double ?? 60, artwork: image("artwork"))
            }
            if let events = spec["events"] as? [[String: Any]] {
                NotchCalendar.shared.debugPlaceholder(events.map { ($0["title"] as? String ?? "", $0["hour"] as? Int ?? 9, $0["minute"] as? Int ?? 0, $0["minutes"] as? Int ?? 30) })
            }
            let state = spec["state"] as? String ?? "reset"
            // Captures never show the user's own songs or calendar: made-up ones unless the spec gives its own.
            if state != "reset" {
                if spec["title"] == nil {
                    NowPlaying.shared.debugPlaceholder(title: "Night Drive", artist: "Orbit", duration: 214, elapsed: 72, artwork: WidgetContent.sampleArtwork)
                }
                if spec["events"] == nil {
                    NotchCalendar.shared.debugPlaceholder([("Orbit 1.0 출시", 14, 0, 60), ("디자인 리뷰", 16, 30, 30)])
                }
            }
            if state == "reset" {
                NowPlaying.shared.debugPlaceholder(title: nil, artist: "", duration: 0, elapsed: 0, artwork: nil)
                NotchCalendar.shared.debugPlaceholder(nil)
            }
            wid = NotchCenter.shared.debugState(state, speed: spec["speed"] as? Double ?? 1, percent: spec["percent"] as? Int ?? 80)
        case "menubar-icon":
            png(OrbitMark(size: 20, color: .white, dot: false), scale: spec["scale"] as? Double ?? 4, to: spec["out"] as? String ?? "")
        case "keycap":
            png(KeyCap(label: spec["label"] as? String ?? "⌘"), scale: spec["scale"] as? Double ?? 6, to: spec["out"] as? String ?? "")
        case "symbol":
            png(Image(systemName: spec["name"] as? String ?? "wifi").font(.system(size: spec["size"] as? Double ?? 15, weight: .medium))
                .foregroundStyle(.white), scale: 4, to: spec["out"] as? String ?? "")
        case "symbols":
            // The actions' own glyphs, white, one PNG each.
            let dir = spec["out"] as? String ?? ""
            for action in OrbitAction.allCases {
                png(Image(systemName: action.symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white),
                    scale: 4, to: "\(dir)/\(action.rawValue).png")
            }
        default: break
        }
        if let wid, let path = spec["wid"] as? String {
            // After two run-loop turns, when the window has drawn its new state.
            DispatchQueue.main.async {
                CATransaction.flush()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    try? Data("\(wid)".utf8).write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}
#endif

#if DEBUG
/// Times a surface's opening the way a person feels it: how long `open` blocks, then every
/// display-link tick for the next two seconds. A tick that comes late is a dropped frame.
@MainActor
final class FrameMeter: NSObject {
    private static var current: FrameMeter?
    private var ticks: [CFTimeInterval] = []
    private var link: CADisplayLink?
    private var results: [String] = []

    static func bench(label: String, runs: Int, open: @escaping () -> Void, close: @escaping () -> Void) {
        let meter = FrameMeter()
        current = meter
        meter.run(label: label, left: runs, total: runs, open: open, close: close)
    }

    private func run(label: String, left: Int, total: Int, open: @escaping () -> Void, close: @escaping () -> Void) {
        guard left > 0 else {
            DebugHook.perfLog("bench \(label):\n" + results.joined(separator: "\n"))
            FrameMeter.current = nil
            return
        }
        ticks = []
        let link = NSScreen.main!.displayLink(target: self, selector: #selector(tick(_:)))
        let fps = Float(NSScreen.main?.maximumFramesPerSecond ?? 120)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
        let started = CACurrentMediaTime()
        open()
        let blocked = (CACurrentMediaTime() - started) * 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            link.invalidate()
            let frame = 1000 / Double(NSScreen.main?.maximumFramesPerSecond ?? 120)
            let gaps = zip(ticks.dropFirst(), ticks).map { ($0 - $1) * 1000 }
            let first = ((ticks.first ?? started) - started) * 1000
            let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / frame).rounded()) - 1) }
            // Frames shown per quarter second: when the dropping happens.
            let quarters = (0..<8).map { q in ticks.filter { ($0 - started) >= Double(q) * 0.25 && ($0 - started) < Double(q + 1) * 0.25 }.count }
            results.append(String(format: "  run %d: open() %.1fms, first tick %.1fms, worst gap %.1fms, dropped %d of %d frames, per ¼s %@",
                                  total - left + 1, blocked, first, gaps.max() ?? 0, dropped, Int(2000 / frame), quarters.map(String.init).joined(separator: " ")))
            close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.run(label: label, left: left - 1, total: total, open: open, close: close)
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) { ticks.append(CACurrentMediaTime()) }
}
#endif
