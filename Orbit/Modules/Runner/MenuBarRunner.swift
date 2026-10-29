import AppKit
import SwiftUI
import QuartzCore
import IOKit
import Observation

extension Pref {
    static let runnerEnabled = "runner.enabled"
    /// A RunnerArt raw value, or "custom.<uuid>".
    static let runnerSelected = "runner.selected"
    /// "cpu", "memory" or "gpu".
    static let runnerSource = "runner.source"
    /// Frames per second ceiling; 0 = none.
    static let runnerFPSCap = "runner.fpsCap"
    static let runnerInvert = "runner.invert"
    static let runnerShowPercent = "runner.showPercent"
    static let runnerPaused = "runner.paused"
    /// Faces the other way.
    static let runnerFlip = "runner.flip"
    /// One-color runners take the system accent color instead of the menu bar's.
    static let runnerAccent = "runner.accent"
    /// "off", "all" or "mono": swap to a random runner every 10 minutes.
    static let runnerShuffle = "runner.shuffle"
}

/// A little character in the menu bar that runs faster the busier the Mac is.
@MainActor @Observable
final class MenuBarRunner: NSObject, NSMenuDelegate {
    static let shared = MenuBarRunner()

    enum Source: String, CaseIterable {
        case cpu, memory, gpu
        var title: String {
            switch self {
            case .cpu: "CPU"
            case .memory: "Memory"
            case .gpu: "GPU"
            }
        }
    }

    static let minFPS = 2.0, maxFPS = 20.0

    /// 0…1 reading of the chosen source.
    private(set) var level: Double = 0
    private(set) var fps = minFPS
    private(set) var gpu: Double?
    private(set) var customs: [CustomRunner] = []

    @ObservationIgnored private var item: NSStatusItem?
    var button: NSStatusBarButton? { item?.button }
    @ObservationIgnored private var frames: [NSImage] = []
    @ObservationIgnored private var frameIndex = 0
    @ObservationIgnored private var frameTimer: Timer?
    @ObservationIgnored private var target = minFPS
    @ObservationIgnored private var phase = 0.0
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var metricTimer: Timer?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var statItems: [String: NSMenuItem] = [:]
    @ObservationIgnored private var cache: [String: [NSImage]] = [:]
    @ObservationIgnored private var shuffleTimer: Timer?

    var selected: String { Pref.defaults.string(forKey: Pref.runnerSelected) ?? RunnerArt.orbit.rawValue }
    var source: Source { Source(rawValue: Pref.defaults.string(forKey: Pref.runnerSource) ?? "") ?? .cpu }
    var paused: Bool { Pref.defaults.bool(forKey: Pref.runnerPaused) }

    func start() {
        customs = RunnerStore.load()
        if let saved = Pref.defaults.string(forKey: Pref.runnerSelected), RunnerArt.resolve(saved) != saved {
            Pref.defaults.set(RunnerArt.resolve(saved), forKey: Pref.runnerSelected)
        }
        apply()
        // Nobody sees the runner while the displays sleep or the session is locked away.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuBarRunner.shared.setAsleep(true) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuBarRunner.shared.setAsleep(false) }
            }
        }
    }

    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var hiddenAway = false

    private func setAsleep(_ on: Bool) {
        guard asleep != on else { return }
        asleep = on
        if on {
            frameTimer?.invalidate(); frameTimer = nil
            metricTimer?.fireDate = .distantFuture
            if watching { SystemMonitor.shared.watch(false, light: true); watching = false }
        } else if item != nil {
            if !watching { SystemMonitor.shared.watch(true, light: true); watching = true }
            metricTimer?.fireDate = Date(timeIntervalSinceNow: 1)
            retime()
        }
    }

    /// Shows or removes the menu bar item to match the setting.
    func apply() {
        if Pref.defaults.bool(forKey: Pref.runnerEnabled) {
            if item == nil {
                let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                i.autosaveName = "OrbitRunner"
                i.button?.imageScaling = .scaleProportionallyDown
                i.button?.target = self
                i.button?.action = #selector(clicked(_:))
                i.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item = i
            }
            if !watching { SystemMonitor.shared.watch(true, light: true); watching = true }
            if metricTimer == nil {
                let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { MenuBarRunner.shared.measure() } }
                RunLoop.main.add(t, forMode: .common) // keep running while the menu is open
                metricTimer = t
            }
            reload()
            measure()
            scheduleShuffle()
        } else {
            shuffleTimer?.invalidate(); shuffleTimer = nil
            frameTimer?.invalidate(); frameTimer = nil
            metricTimer?.invalidate(); metricTimer = nil
            if watching { SystemMonitor.shared.watch(false, light: true); watching = false }
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shownTitle = nil; shownAccent = nil; lengthKey = nil
        }
    }

    /// Picks up a new character (or new frames for a custom one).
    func reload() {
        cache[selected] = nil
        frames = frames(for: selected)
        frameIndex = 0
        drawFrame()
        applyTint()
        fixLength()
        retime()
    }

    /// Frames depend on the flip setting; rebuild them all.
    func flushFrames() {
        cache.removeAll()
        reload()
    }

    func select(_ id: String) {
        Pref.defaults.set(id, forKey: Pref.runnerSelected)
        reload()
    }

    /// Runs every 10 minutes while shuffling is on; "mono" keeps to one-color runners.
    func scheduleShuffle() {
        shuffleTimer?.invalidate(); shuffleTimer = nil
        let mode = Pref.defaults.string(forKey: Pref.runnerShuffle) ?? "off"
        guard mode != "off", item != nil else { return }
        let t = Timer(timeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarRunner.shared.shuffle() }
        }
        RunLoop.main.add(t, forMode: .common)
        shuffleTimer = t
    }

    private func shuffle() {
        let mono = Pref.defaults.string(forKey: Pref.runnerShuffle) == "mono"
        // Built-in runners are all one color.
        let ids = RunnerArt.allCases.map(\.rawValue) + customs.filter { !mono || $0.template }.map(Self.id)
        if let next = ids.filter({ $0 != selected }).randomElement() { select(next) }
    }

    func setPaused(_ on: Bool) {
        Pref.defaults.set(on, forKey: Pref.runnerPaused)
        retime()
    }

    // MARK: Runners

    func frames(for id: String) -> [NSImage] {
        if let cached = cache[id] { return cached }
        var made: [NSImage]
        if let art = RunnerArt(rawValue: id) {
            made = art.frames()
        } else if let runner = custom(id) {
            made = RunnerStore.frames(for: runner)
        } else {
            made = RunnerArt.orbit.frames()
        }
        if Pref.defaults.bool(forKey: Pref.runnerFlip) { made = made.map(Self.mirrored) }
        // Drawn once into bitmaps: the code-drawn art would otherwise be redrawn from its paths every
        // time macOS snapshots the item for each menu bar it shows in, several times a frame.
        made = made.map(Self.rasterized)
        cache[id] = made
        return made
    }

    private static func rasterized(_ image: NSImage) -> NSImage {
        let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let size = image.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        out.isTemplate = image.isTemplate
        return out
    }

    private static func mirrored(_ image: NSImage) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.width, yBy: 0)
            t.scaleX(by: -1, yBy: 1)
            t.concat()
            image.draw(in: rect)
            return true
        }
        out.isTemplate = image.isTemplate
        return out
    }

    func custom(_ id: String) -> CustomRunner? {
        guard id.hasPrefix("custom.") else { return nil }
        return customs.first { "custom.\($0.id.uuidString)" == id }
    }

    static func id(_ runner: CustomRunner) -> String { "custom.\(runner.id.uuidString)" }

    func importRunner(_ urls: [URL]) throws {
        let runner = try RunnerStore.importFiles(urls)
        customs.append(runner)
        select(Self.id(runner))
    }

    func update(_ runner: CustomRunner) {
        guard let i = customs.firstIndex(where: { $0.id == runner.id }) else { return }
        customs[i] = runner
        RunnerStore.save(runner)
        cache[Self.id(runner)] = nil
        if selected == Self.id(runner) { reload() }
    }

    func delete(_ runner: CustomRunner) {
        RunnerStore.delete(runner.id)
        customs.removeAll { $0.id == runner.id }
        cache[Self.id(runner)] = nil
        if selected == Self.id(runner) { select(RunnerArt.orbit.rawValue) }
    }

    // MARK: Animation

    /// Reads the chosen source (sampled by SystemMonitor) and sets the pace.
    private func measure() {
        let monitor = SystemMonitor.shared
        if source == .gpu || menuOpen { gpu = GPUUsage.read() }
        let value: Double = switch source {
        case .cpu: monitor.cpu.last ?? 0
        case .memory: monitor.memoryTotal > 0 ? monitor.memoryUsed / monitor.memoryTotal : 0
        case .gpu: gpu ?? 0
        }
        level = min(1, max(0, value))
        // Folded away behind Orbit's hidden section (pushed off the screen), nobody sees it run.
        if let f = item?.button?.window?.frame {
            hiddenAway = !NSScreen.screens.contains { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) }
        }
        retime()
        drawTitle()
        if menuOpen { refreshStats() }
    }

    /// Frames per second for the current level: idle → 2, flat out → 20 (or the other way round).
    static func pace(level: Double, invert: Bool, cap: Int) -> Double {
        let l = invert ? 1 - level : level
        var fps = minFPS + (maxFPS - minFPS) * l
        if cap > 0 { fps = min(fps, Double(cap)) }
        return fps
    }

    /// One steady ticker; the pace only changes how fast the stride advances. Restarting a timer
    /// whenever the pace changed made the runner hitch, so instead the speed glides toward the
    /// target and frames step whenever enough of a frame has gone by.
    private func retime() {
        guard item != nil, frames.count > 1, !paused, !asleep, !hiddenAway else {
            frameTimer?.invalidate(); frameTimer = nil
            return
        }
        target = Self.pace(level: level, invert: Pref.defaults.bool(forKey: Pref.runnerInvert), cap: Pref.defaults.integer(forKey: Pref.runnerFPSCap))
        guard frameTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        if fps <= 0 { fps = target }
        // Wakes once per frame (2–20 a second) instead of a fixed 40Hz ticker; the pace still
        // glides, it's just applied when each frame is due.
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarRunner.shared.tick() }
        }
        t.fireDate = Date(timeIntervalSinceNow: 1 / max(1, fps))
        RunLoop.main.add(t, forMode: .common)
        frameTimer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(1, now - lastTick)
        lastTick = now
        // About a second to settle into a new pace.
        fps += (target - fps) * min(1, dt * 2.5)
        frameIndex = (frameIndex + 1) % max(1, frames.count)
        drawFrame()
        let interval = 1 / max(1, fps)
        frameTimer?.tolerance = interval * 0.1
        frameTimer?.fireDate = Date(timeIntervalSinceNow: interval)
    }

    private func advance() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        drawFrame()
    }

    private func drawFrame() {
        guard let button = item?.button, !frames.isEmpty else { return }
        button.image = frames[min(frameIndex, frames.count - 1)]
    }

    /// Everything about the item other than the frame, set only when it changes: each change makes
    /// macOS lay the item out and re-snapshot it for every menu bar.
    @ObservationIgnored private var shownTitle: String?
    @ObservationIgnored private var shownAccent: Bool?
    @ObservationIgnored private var lengthKey: String?

    private func applyTint() {
        guard let button = item?.button else { return }
        let accent = Pref.defaults.bool(forKey: Pref.runnerAccent)
        guard shownAccent != accent else { return }
        shownAccent = accent
        // Tints one-color frames only; colored ones draw as they are.
        button.contentTintColor = accent ? .controlAccentColor : nil
    }

    /// A fixed width (the widest frame, plus room for "100%"), so stepping frames or a changing
    /// percentage never resizes the item; a resize moves every icon to its left.
    private func fixLength() {
        guard let item, let button = item.button, !frames.isEmpty else { return }
        let percent = Pref.defaults.bool(forKey: Pref.runnerShowPercent)
        let widest = frames.map(\.size.width).max() ?? 0
        let key = "\(widest)|\(percent)"
        guard lengthKey != key else { return }
        lengthKey = key
        let title = button.attributedTitle
        let image = button.image
        item.length = NSStatusItem.variableLength
        button.image = frames.max { $0.size.width < $1.size.width }
        if percent { button.attributedTitle = Self.percentTitle(100) }
        button.layoutSubtreeIfNeeded()
        let width = ceil(button.fittingSize.width)
        button.attributedTitle = title
        button.image = image
        if width > 0 { item.length = width }
    }

    private static func percentTitle(_ value: Int) -> NSAttributedString {
        NSAttributedString(string: " \(value)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .baselineOffset: 0.5,
        ])
    }

    private func drawTitle() {
        guard let button = item?.button else { return }
        let percent = Pref.defaults.bool(forKey: Pref.runnerShowPercent)
        let text = percent ? "\(Int((level * 100).rounded()))" : ""
        guard shownTitle != text else { return }
        shownTitle = text
        if percent {
            button.imagePosition = .imageLeading
            button.attributedTitle = Self.percentTitle(Int((level * 100).rounded()))
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
        fixLength()
    }

    /// Re-applies settings that only change how the item looks.
    func refreshLook() {
        shownTitle = nil
        drawTitle()
        drawFrame()
        applyTint()
        fixLength()
        retime()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        statItems.removeAll()
        for key in ["cpu", "gpu", "memory", "storage", "battery", "network"] {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            statItems[key] = item
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let runners = NSMenuItem(title: "Runner".loc, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let all = RunnerArt.allCases.map { ($0.rawValue, $0.title.loc) } + customs.map { (Self.id($0), $0.name) }
        for (id, name) in all {
            let entry = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = id
            entry.state = id == selected ? .on : .off
            sub.addItem(entry)
        }
        runners.submenu = sub
        menu.addItem(runners)

        let pause = NSMenuItem(title: paused ? "Resume Animation".loc : "Pause Animation".loc, action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let choose = NSMenuItem(title: "Choose Runner…".loc, action: #selector(openPage), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        let monitor = NSMenuItem(title: "Activity Monitor".loc, action: #selector(openActivityMonitor), keyEquivalent: "")
        monitor.target = self
        menu.addItem(monitor)
        refreshStats()
    }

    @ObservationIgnored private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        // The card is built when it opens and dropped when it closes, so a closed card doesn't keep
        // re-rendering every time the CPU reading changes.
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated {
                let r = MenuBarRunner.shared
                r.popover.contentViewController = nil
                r.statsTimer?.invalidate(); r.statsTimer = nil
                r.menuOpen = false
            }
        }
        return p
    }()

    private func statsHost() -> NSViewController {
        let host = NSHostingController(rootView: RunnerStatsView(close: { [weak self] in self?.popover.performClose(nil) }).orbitTint())
        host.sizingOptions = [.preferredContentSize]
        return host
    }
    @ObservationIgnored private var statsTimer: Timer?

    /// Left click: the status card. Right click: the quick menu (runner list, pause).
    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.delegate = self
            item?.menu = menu
            sender.performClick(nil)
            item?.menu = nil
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        menuOpen = true
        gpu = GPUUsage.read()
        SystemMonitor.shared.sample()
        RunnerStats.shared.refresh()
        if popover.contentViewController == nil { popover.contentViewController = statsHost() }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        statsTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let r = MenuBarRunner.shared
                guard r.popover.isShown else { r.statsTimer?.invalidate(); r.statsTimer = nil; r.menuOpen = false; return }
                r.gpu = GPUUsage.read()
                SystemMonitor.shared.sample()
                RunnerStats.shared.refresh()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        statsTimer = t
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        gpu = GPUUsage.read()
        refreshStats()
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func refreshStats() {
        let m = SystemMonitor.shared
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        set("cpu", "CPU", pct(m.cpu.last ?? 0))
        if let gpu { set("gpu", "GPU", pct(gpu)) } else { statItems["gpu"]?.isHidden = true }
        set("memory", "Memory".loc, "%@ of %@".loc(m.memoryUsed.orbitBytes, m.memoryTotal.orbitBytes))
        set("storage", "Storage".loc, "%@ free".loc(m.diskFree.orbitBytes))
        if let b = m.battery {
            set("battery", "Battery".loc, pct(Double(b.percent) / 100) + (b.charging ? " · " + "Charging".loc : ""))
        } else {
            statItems["battery"]?.isHidden = true
        }
        set("network", "Network".loc, "↓ \(m.download.orbitRate)   ↑ \(m.upload.orbitRate)")
    }

    private func set(_ key: String, _ label: String, _ value: String) {
        guard let item = statItems[key] else { return }
        item.isHidden = false
        let text = NSMutableAttributedString(string: label + "\t", attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor]))
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 84)]
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        item.attributedTitle = text
    }

    @objc private func pick(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { select(id) }
    }

    @objc private func togglePause() { setPaused(!paused) }
    @objc private func openPage() { MainWindow.show(.runner) }
    @objc private func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"), configuration: .init())
    }
}

/// GPU busy share from the graphics driver's own statistics; nil when it doesn't report one.
enum GPUUsage {
    struct Detail: Equatable {
        var renderer: Double?
        var tiler: Double?
        /// Memory the GPU is using, in bytes.
        var memory: Double?
    }

    /// The driver's breakdown, for the runner's status card.
    static func detail() -> Detail {
        var d = Detail()
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return d }
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let r = stats["Renderer Utilization %"] as? NSNumber { d.renderer = r.doubleValue / 100 }
            if let t = stats["Tiler Utilization %"] as? NSNumber { d.tiler = t.doubleValue / 100 }
            if let m = (stats["In use system memory"] ?? stats["inUseVidMemoryBytes"]) as? NSNumber { d.memory = m.doubleValue }
        }
        return d
    }

    static func read() -> Double? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let u = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber {
                best = max(best ?? 0, u.doubleValue / 100)
            }
        }
        return best
    }
}
