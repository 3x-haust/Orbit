import AppKit
import CoreAudio
import CoreGraphics
import Observation

/// One screen Orbit can brighten, dim or turn up.
@MainActor @Observable
final class ManagedDisplay: Identifiable {
    enum Kind: String {
        case builtIn, apple, ddc, software

        var label: String {
            switch self {
            case .builtIn: "Built-in"
            case .apple: "Apple display"
            case .ddc: "DDC/CI"
            case .software: "Software dimming"
            }
        }
    }

    /// How brightness is set when Orbit has a choice.
    enum Method: String, CaseIterable { case auto, ddc, software }

    let id: CGDirectDisplayID
    let name: String
    /// Survives reconnecting and new display IDs: vendor, model and serial.
    let key: String
    let isBuiltIn: Bool
    let appleControlled: Bool
    fileprivate(set) var channel: DDCChannel?

    var brightness: Double = 1
    var contrast: Double = 0.5
    var volume: Double = 0.5
    var muted = false
    var input: UInt16?
    /// What the monitor answered when asked; nil = it didn't.
    var ddcBrightnessMax: UInt16?
    var ddcContrastMax: UInt16?
    var ddcVolumeMax: UInt16?
    var probing = false

    var enabled: Bool {
        didSet { Pref.defaults.set(!enabled, forKey: "displays.\(key).disabled") }
    }
    var method: Method {
        didSet { Pref.defaults.set(method.rawValue, forKey: "displays.\(key).method"); DisplayManager.shared.methodChanged(self) }
    }

    var kind: Kind {
        if isBuiltIn { return .builtIn }
        if appleControlled { return .apple }
        switch method {
        case .ddc: return channel != nil ? .ddc : .software
        case .software: return .software
        case .auto: return channel != nil && ddcBrightnessMax != nil ? .ddc : .software
        }
    }

    var hasContrast: Bool { kind == .ddc && ddcContrastMax != nil }
    var hasVolume: Bool { kind == .ddc && ddcVolumeMax != nil }
    var hasInputs: Bool { kind == .ddc && input != nil }

    var symbol: String {
        switch kind {
        case .builtIn: "laptopcomputer"
        case .apple: "display"
        default: "display"
        }
    }

    init(id: CGDirectDisplayID, name: String) {
        self.id = id
        self.name = name
        isBuiltIn = CGDisplayIsBuiltin(id) != 0
        appleControlled = !isBuiltIn && DisplayPrivate.canSetBrightness(id)
        key = "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        let d = Pref.defaults
        enabled = !d.bool(forKey: "displays.\(key).disabled")
        method = Method(rawValue: d.string(forKey: "displays.\(key).method") ?? "") ?? .auto
        if let saved = d.object(forKey: "displays.\(key).brightness") as? Double { brightness = saved }
        if let saved = d.object(forKey: "displays.\(key).volume") as? Double { volume = saved }
    }
}

/// MonitorControl, in Orbit: brightness, contrast and volume for every screen — the built-in panel and
/// Apple displays through macOS, other monitors over DDC/CI, and software dimming for the rest.
@MainActor @Observable
final class DisplayManager {
    static let shared = DisplayManager()

    enum KeyTarget: String, CaseIterable { case pointer, main, all }

    struct Preset: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        /// Display key → brightness; displays not listed are left alone.
        var levels: [String: Double]
    }

    private(set) var displays: [ManagedDisplay] = []
    var externals: [ManagedDisplay] { displays.filter { !$0.isBuiltIn } }

    var enabled: Bool { didSet { Pref.defaults.set(enabled, forKey: "displays.enabled"); enabled ? start() : stop() } }
    var brightnessKeys: Bool { didSet { Pref.defaults.set(brightnessKeys, forKey: "displays.keys"); updateKeys() } }
    var volumeKeys: Bool { didSet { Pref.defaults.set(volumeKeys, forKey: "displays.volumeKeys"); updateKeys() } }
    var keyTarget: KeyTarget { didSet { Pref.defaults.set(keyTarget.rawValue, forKey: "displays.keyTarget") } }
    var syncWithBuiltIn: Bool { didSet { Pref.defaults.set(syncWithBuiltIn, forKey: "displays.sync"); updateSync() } }
    var showOSD: Bool { didSet { Pref.defaults.set(showOSD, forKey: "displays.osd"); updateKeys() } }
    /// Volume keys for any output (MacBook speakers, AirPods, USB) get Orbit's HUD instead of macOS's.
    var speakerHUD: Bool { didSet { Pref.defaults.set(speakerHUD, forKey: "displays.speakerHUD"); updateKeys() } }
    /// The keys are wanted but macOS hasn't allowed Orbit to see them yet.
    private(set) var keysNeedAccessibility = false
    var presets: [Preset] { didSet { savePresets() } }

    private var started = false
    private var screenObserver: NSObjectProtocol?
    private var syncTimer: Timer?
    private var lastBuiltIn: Double?
    private let ddcQueue = DispatchQueue(label: "orbit.displays.ddc", qos: .userInitiated)
    /// Latest wanted value per display and code; a slider drag sends only what's current when the line is free.
    private var pending: [String: (DDCChannel, DDCChannel.VCP, UInt16)] = [:]
    private var draining = false
    private var shades: [CGDirectDisplayID: NSWindow] = [:]
    private var accessibilityTimer: Timer?
    private var keyboardBeforeOff: Double?
    /// Brightness writes to macOS, at most one per frame — a slider drag sends dozens a second.
    private var builtInPending: [CGDirectDisplayID: Double] = [:]
    private var builtInScheduled = false
    /// When the user last changed a level; sync leaves the screens alone for a moment after.
    private var userChangedAt: TimeInterval = 0

    private init() {
        let d = Pref.defaults
        enabled = d.object(forKey: "displays.enabled") as? Bool ?? false
        brightnessKeys = d.object(forKey: "displays.keys") as? Bool ?? true
        volumeKeys = d.object(forKey: "displays.volumeKeys") as? Bool ?? true
        keyTarget = KeyTarget(rawValue: d.string(forKey: "displays.keyTarget") ?? "") ?? .pointer
        syncWithBuiltIn = d.bool(forKey: "displays.sync")
        showOSD = d.object(forKey: "displays.osd") as? Bool ?? true
        speakerHUD = d.object(forKey: "displays.speakerHUD") as? Bool ?? true
        presets = (d.data(forKey: "displays.presets")).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
    }

    // MARK: Lifecycle

    /// Brightness keys, matching the MacBook, and software dimming kept on — only when Displays is on.
    func start() {
        guard enabled, !started else { return }
        started = true
        DisplaysLog.write("start")
        refresh()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                // Monitors take a moment to answer after they appear.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { DisplayManager.shared.refresh() }
            }
        }
        updateKeys()
        updateSync()
    }

    func stop() {
        guard started else { return }
        started = false
        DisplaysLog.write("stop")
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        MediaKeyTap.shared.stop()
        syncTimer?.invalidate()
        syncTimer = nil
        // Software dimming lives in the gamma table and shades; give the screens their light back.
        CGDisplayRestoreColorSyncSettings()
        for (_, w) in shades { w.orderOut(nil) }
        shades.removeAll()
    }

    /// Finds the screens and asks each what it supports. Reading only — nothing changes on screen.
    func refresh() {
        let screens = NSScreen.screens.map { (id: $0.displayID, name: $0.localizedName) }
        let old = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        displays = screens.map { s in
            if let d = old[s.id], d.name == s.name { return d }
            return ManagedDisplay(id: s.id, name: s.name)
        }
        for d in displays where d.isBuiltIn || d.appleControlled {
            if let b = DisplayPrivate.brightness(d.id) { d.brightness = b }
        }
        let externals = displays.filter { !$0.isBuiltIn && !$0.appleControlled }
        guard !externals.isEmpty else { return }
        let wanted = externals.map { (id: $0.id, name: $0.name) }
        let ids = Set(externals.map(\.id))
        for d in externals { d.probing = true }
        Task.detached(priority: .userInitiated) {
            let channels = DDCDiscovery.match(DDCDiscovery.scan(), to: wanted)
            var answers: [CGDirectDisplayID: Probe] = [:]
            for (id, channel) in channels { answers[id] = Probe.run(channel) }
            await MainActor.run {
                let externals = DisplayManager.shared.displays.filter { ids.contains($0.id) }
                for d in externals {
                    d.channel = channels[d.id]
                    d.probing = false
                    guard let p = answers[d.id] else { continue }
                    d.ddcBrightnessMax = p.brightness?.max
                    d.ddcContrastMax = p.contrast?.max
                    d.ddcVolumeMax = p.volume?.max
                    d.input = p.input
                    if let b = p.brightness, b.max > 0 { d.brightness = Double(b.current) / Double(b.max) }
                    if let c = p.contrast, c.max > 0 { d.contrast = Double(c.current) / Double(c.max) }
                    if let v = p.volume, v.max > 0 { d.volume = Double(v.current) / Double(v.max) }
                    if let m = p.mute { d.muted = m == 1 }
                    DisplaysLog.write("\(d.name): ddc \(d.channel != nil) brightness \(String(describing: p.brightness)) contrast \(String(describing: p.contrast)) volume \(String(describing: p.volume)) input \(String(describing: p.input))")
                }
                // Software dimming doesn't outlive Orbit; put it back.
                if DisplayManager.shared.started {
                    for d in externals where d.kind == .software && d.enabled && d.brightness < 0.999 { DisplayManager.shared.applySoftware(d) }
                }
            }
        }
    }

    func display(_ id: CGDirectDisplayID) -> ManagedDisplay? { displays.first { $0.id == id } }

    // MARK: Setting values

    /// From Orbit's own sliders and presets: the change, and the HUD on that screen.
    func setBrightnessShowingHUD(_ d: ManagedDisplay, _ value: Double) {
        userChangedAt = ProcessInfo.processInfo.systemUptime
        setBrightness(d, value)
        if enabled, showOSD { DisplayOSD.shared.show(.brightness, value: d.brightness, on: d.id) }
    }

    func setBrightness(_ d: ManagedDisplay, _ value: Double) {
        let v = min(max(value, 0), 1)
        d.brightness = v
        Pref.defaults.set(v, forKey: "displays.\(d.key).brightness")
        switch d.kind {
        case .builtIn, .apple: writeBuiltIn(d.id, v)
        case .ddc: send(d, .brightness, v, max: d.ddcBrightnessMax ?? 100)
        case .software: applySoftware(d)
        }
    }

    private func writeBuiltIn(_ id: CGDirectDisplayID, _ value: Double) {
        builtInPending[id] = value
        guard !builtInScheduled else { return }
        builtInScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            MainActor.assumeIsolated {
                let m = DisplayManager.shared
                let jobs = m.builtInPending
                m.builtInPending = [:]
                m.builtInScheduled = false
                for (id, v) in jobs { DisplayPrivate.setBrightness(id, v) }
            }
        }
    }

    func setContrast(_ d: ManagedDisplay, _ value: Double) {
        d.contrast = min(max(value, 0), 1)
        send(d, .contrast, d.contrast, max: d.ddcContrastMax ?? 100)
    }

    func setVolume(_ d: ManagedDisplay, _ value: Double) {
        d.volume = min(max(value, 0), 1)
        Pref.defaults.set(d.volume, forKey: "displays.\(d.key).volume")
        if d.muted, d.volume > 0 { setMuted(d, false) }
        send(d, .volume, d.volume, max: d.ddcVolumeMax ?? 100)
    }

    func setMuted(_ d: ManagedDisplay, _ muted: Bool) {
        d.muted = muted
        guard let channel = d.channel else { return }
        // MCCS: 1 mutes, 2 unmutes.
        queue(channel, d, .mute, muted ? 1 : 2)
    }

    func setInput(_ d: ManagedDisplay, _ value: UInt16) {
        d.input = value
        guard let channel = d.channel else { return }
        queue(channel, d, .inputSource, value)
    }

    /// Standby (MCCS 0xD6 = 4). Most monitors wake from their own button or new input.
    func standby(_ d: ManagedDisplay) {
        guard let channel = d.channel else { return }
        queue(channel, d, .power, 4)
    }

    func methodChanged(_ d: ManagedDisplay) {
        // Leaving software dimming: hand the screen its full light back.
        if d.kind != .software { clearSoftware(d) } else if started { applySoftware(d) }
    }

    private func send(_ d: ManagedDisplay, _ vcp: DDCChannel.VCP, _ value: Double, max: UInt16) {
        guard let channel = d.channel else { return }
        queue(channel, d, vcp, UInt16((value * Double(max)).rounded()))
    }

    private func queue(_ channel: DDCChannel, _ d: ManagedDisplay, _ vcp: DDCChannel.VCP, _ value: UInt16) {
        pending["\(d.id)-\(vcp.rawValue)"] = (channel, vcp, value)
        drain()
    }

    private func drain() {
        guard !draining, let (key, job) = pending.first else { return }
        pending[key] = nil
        draining = true
        ddcQueue.async {
            let ok = job.0.write(job.1, job.2)
            if !ok { DisplaysLog.write("ddc write \(job.1) = \(job.2) failed") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DisplayManager.shared.draining = false
                    DisplayManager.shared.drain()
                }
            }
        }
    }

    // MARK: Software dimming

    /// Dims through the gamma table; a dark shade over the screen where the table can't be changed.
    fileprivate func applySoftware(_ d: ManagedDisplay) {
        // Never fully black — the pointer has to stay findable.
        let level = Float(0.08 + 0.92 * d.brightness)
        let r = CGSetDisplayTransferByFormula(d.id, 0, level, 1, 0, level, 1, 0, level, 1)
        if r == .success {
            shades[d.id]?.orderOut(nil)
            shades[d.id] = nil
        } else {
            shade(d).alphaValue = CGFloat(1 - level)
        }
    }

    private func clearSoftware(_ d: ManagedDisplay) {
        CGDisplayRestoreColorSyncSettings()
        shades[d.id]?.orderOut(nil)
        shades[d.id] = nil
        // Other displays dimmed in software keep their level.
        for other in displays where other.id != d.id && other.kind == .software && other.brightness < 0.999 { applySoftware(other) }
    }

    private func shade(_ d: ManagedDisplay) -> NSWindow {
        if let w = shades[d.id] { return w }
        let frame = NSScreen.screens.first { $0.displayID == d.id }?.frame ?? .zero
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.hasShadow = false
        w.orderFrontRegardless()
        shades[d.id] = w
        return w
    }

    // MARK: Keys

    /// Starts or stops the key tap right away; waits for Accessibility if it isn't granted yet.
    private func updateKeys() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        guard started, brightnessKeys || volumeKeys || showOSD || speakerHUD else {
            MediaKeyTap.shared.stop()
            keysNeedAccessibility = false
            return
        }
        MediaKeyTap.shared.start()
        keysNeedAccessibility = !MediaKeyTap.shared.running
        guard keysNeedAccessibility else { return }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let m = DisplayManager.shared
                MediaKeyTap.shared.start()
                if MediaKeyTap.shared.running {
                    m.keysNeedAccessibility = false
                    m.accessibilityTimer?.invalidate()
                    m.accessibilityTimer = nil
                }
            }
        }
    }

    enum KeyAction { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute, keyboardUp, keyboardDown, keyboardToggle }

    /// From the key tap. Returns true when Orbit handled it and macOS shouldn't.
    func handle(_ key: KeyAction, fine: Bool) -> Bool {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .brightnessUp, .brightnessDown:
            let targets = brightnessTargets()
            guard !targets.isEmpty else { return false }
            // Monitors need Orbit; the MacBook's own screen only when Orbit's HUD replaces macOS's.
            let external = brightnessKeys && targets.contains { !$0.isBuiltIn }
            guard external || showOSD else { return false }
            userChangedAt = ProcessInfo.processInfo.systemUptime
            let delta = key == .brightnessUp ? step : -step
            for d in targets {
                // A write may still be waiting for the next frame; that one is the truth.
                if d.isBuiltIn || d.appleControlled, builtInPending[d.id] == nil, let now = DisplayPrivate.brightness(d.id) { d.brightness = now }
                setBrightness(d, (d.brightness / step).rounded() * step + delta)
            }
            if showOSD, let first = targets.first(where: { !$0.isBuiltIn }) ?? targets.first {
                DisplayOSD.shared.show(.brightness, value: first.brightness, on: first.id)
            }
            return true
        case .keyboardUp, .keyboardDown, .keyboardToggle:
            guard showOSD, KeyboardBacklight.available, let now = KeyboardBacklight.level() else { return false }
            let next: Double
            switch key {
            case .keyboardToggle:
                if now > 0.01 { keyboardBeforeOff = now; next = 0 } else { next = keyboardBeforeOff ?? 0.5 }
            default: next = (now / step).rounded() * step + (key == .keyboardUp ? step : -step)
            }
            KeyboardBacklight.set(next)
            DisplayOSD.shared.show(.keyboard, value: min(max(next, 0), 1), on: NSScreen.active.displayID)
            return true
        case .volumeUp, .volumeDown, .mute:
            // A monitor's own speakers over HDMI/DisplayPort: DDC, as before.
            if volumeKeys, let d = speakerDisplay() {
                switch key {
                case .mute: setMuted(d, !d.muted)
                default: setVolume(d, (d.volume / step).rounded() * step + (key == .volumeUp ? step : -step))
                }
                if showOSD { DisplayOSD.shared.show(d.muted ? .muted : .volume, value: d.muted ? 0 : d.volume, caption: d.name, on: d.id) }
                return true
            }
            // Anything else macOS can set the volume of, with Orbit's HUD instead of macOS's.
            guard speakerHUD, let out = SystemVolume.current() else { return false }
            var muted = SystemVolume.isMuted(out)
            var level = SystemVolume.volume(out)
            if key == .mute {
                muted.toggle()
                if !SystemVolume.setMuted(out, muted) { return false }
            } else {
                level = min(max((level / step).rounded() * step + (key == .volumeUp ? step : -step), 0), 1)
                SystemVolume.setVolume(out, level)
                // Like macOS: changing the volume unmutes.
                if muted { SystemVolume.setMuted(out, false); muted = false }
                SystemVolume.playFeedbackIfWanted()
            }
            let silent = muted || level < 0.001
            DisplayOSD.shared.show(silent ? .muted : .volume, value: muted ? 0 : level, caption: out.name, on: NSScreen.active.displayID)
            return true
        }
    }

    private func brightnessTargets() -> [ManagedDisplay] {
        let usable = displays.filter { $0.enabled }
        switch keyTarget {
        case .all: return usable
        case .main: return usable.filter { $0.id == CGMainDisplayID() }
        case .pointer:
            let id = NSScreen.active.displayID
            return usable.filter { $0.id == id }
        }
    }

    /// A monitor whose own speakers are the sound output — macOS can't change their volume itself.
    private func speakerDisplay() -> ManagedDisplay? {
        guard let output = AudioOutput.current(), output.isDisplayAudio else { return nil }
        return displays.first { $0.enabled && $0.hasVolume && (output.name == $0.name || output.name.contains($0.name) || $0.name.contains(output.name)) }
            ?? displays.first { $0.enabled && $0.hasVolume && displays.filter(\.hasVolume).count == 1 }
    }

    // MARK: Sync

    private func updateSync() {
        syncTimer?.invalidate()
        syncTimer = nil
        guard started, syncWithBuiltIn else { return }
        lastBuiltIn = nil
        // Cheap: one read of the built-in panel's brightness, twice a second.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { DisplayManager.shared.syncTick() }
        }
        syncTimer?.tolerance = 0.15
    }

    private func syncTick() {
        // Not while the user is dragging a slider or pressing keys — reading back mid-change fights them.
        guard ProcessInfo.processInfo.systemUptime - userChangedAt > 1, builtInPending.isEmpty,
              let built = displays.first(where: \.isBuiltIn), let b = DisplayPrivate.brightness(built.id) else { return }
        built.brightness = b
        defer { lastBuiltIn = b }
        guard let last = lastBuiltIn, abs(last - b) > 0.004 else { return }
        for d in displays where !d.isBuiltIn && d.enabled { setBrightness(d, b) }
    }

    // MARK: Presets

    func applyPreset(_ p: Preset) {
        for d in displays where d.enabled {
            if let level = p.levels[d.key] { setBrightnessShowingHUD(d, level) }
        }
        Toast.show("Brightness set", symbol: "sun.max.fill", detail: p.name)
    }

    func saveCurrentAsPreset(named name: String) {
        var levels: [String: Double] = [:]
        for d in displays { levels[d.key] = d.brightness }
        presets.append(Preset(name: name, levels: levels))
    }

    func removePreset(_ p: Preset) { presets.removeAll { $0.id == p.id } }

    /// The same level on every screen — the presets everyone has.
    func setAll(_ level: Double) {
        for d in displays where d.enabled { setBrightnessShowingHUD(d, level) }
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) { Pref.defaults.set(data, forKey: "displays.presets") }
    }
}

/// What a monitor answers when asked, read once in the background.
private struct Probe: Sendable {
    var brightness: (current: UInt16, max: UInt16)?
    var contrast: (current: UInt16, max: UInt16)?
    var volume: (current: UInt16, max: UInt16)?
    var mute: UInt16?
    var input: UInt16?

    static func run(_ channel: DDCChannel) -> Probe {
        var p = Probe()
        p.brightness = channel.read(.brightness)
        // A monitor that won't even say its brightness won't say anything else.
        guard p.brightness != nil else { return p }
        p.contrast = channel.read(.contrast)
        p.volume = channel.read(.volume)
        p.mute = channel.read(.mute)?.current
        p.input = channel.read(.inputSource).map { $0.current & 0xFF }
        return p
    }
}

/// The current sound output, to tell whether it's a monitor's own speakers.
enum AudioOutput {
    struct Device { let name: String; let isDisplayAudio: Bool }

    static func current() -> Device? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        let display = transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
        return Device(name: (name?.takeRetainedValue() as String?) ?? "", isDisplayAudio: display)
    }
}

/// ~/Library/Logs/Orbit/displays.log
enum DisplaysLog {
    nonisolated static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("displays.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Common MCCS input codes; monitors vary, so the current one is always listed too.
enum DisplayInputs {
    static let common: [(UInt16, String)] = [
        (0x0F, "DisplayPort 1"), (0x10, "DisplayPort 2"),
        (0x11, "HDMI 1"), (0x12, "HDMI 2"), (0x13, "HDMI 3"),
        (0x1B, "USB-C"), (0x19, "USB-C 2"),
        (0x03, "DVI 1"), (0x01, "VGA"),
    ]

    static func name(_ code: UInt16) -> String {
        common.first { $0.0 == code }?.1 ?? String(format: "Input 0x%02X", code)
    }
}
