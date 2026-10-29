import AppKit
import CoreAudio
import Observation

extension Pref {
    static let audioApps = "audio.apps"
    static let audioGlobal = "audio.global"
}

/// The "All Sound" EQ: one curve over everything the Mac plays.
struct GlobalEQSettings: Codable, Equatable {
    var enabled = false
    var bands = [Float](repeating: 0, count: GraphicEQ.bands)
    var preset: String? = EQPreset.flat.id

    var eqIsFlat: Bool { bands.allSatisfy { abs($0) < 0.05 } }
    /// Only an on switch with an actual curve touches the audio path; a flat EQ leaves macOS alone.
    var isActive: Bool { enabled && !eqIsFlat }
}

struct AudioAppSettings: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var bands = [Float](repeating: 0, count: GraphicEQ.bands)
    var preset: String? = EQPreset.flat.id
    /// nil follows the system output.
    var deviceUID: String?

    var eqIsFlat: Bool { bands.allSatisfy { abs($0) < 0.05 } }
    /// Untouched apps keep macOS's normal audio path — no tap at all.
    var isDefault: Bool { abs(volume - 1) < 0.005 && !muted && eqIsFlat && deviceUID == nil }
    var gain: Float { muted ? 0 : volume }
}

struct EQPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let bands: [Float]

    static let flat = EQPreset(id: "flat", title: "Flat", bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    static let all: [EQPreset] = [
        flat,
        EQPreset(id: "bass", title: "Bass Boost", bands: [6, 5.5, 4.5, 2.5, 0.5, 0, 0, 0, 0, 0]),
        EQPreset(id: "vocal", title: "Vocal", bands: [-2, -2, -1, 0.5, 2.5, 3.5, 3, 1.5, 0, -1]),
        EQPreset(id: "treble", title: "Treble", bands: [0, 0, 0, 0, 0, 0.5, 2, 3.5, 5, 6]),
        EQPreset(id: "podcast", title: "Podcast", bands: [-5, -3.5, -1, 1, 3, 4, 3, 1.5, 0, -1.5]),
        EQPreset(id: "loudness", title: "Loudness", bands: [5, 4, 2, 0, -1, -1, 0, 2, 3.5, 4.5]),
    ]
}

struct AudioApp: Identifiable, Equatable {
    let id: String // bundle ID
    let name: String
    let icon: NSImage?
    let isPlaying: Bool
}

struct OutputDevice: Identifiable, Hashable {
    let id: String // device UID
    let name: String
}

/// Per-app volume, mute, EQ and output routing (FineTune-style), built on Core Audio process taps.
/// Nothing is tapped — and no permission is asked — until an app's settings differ from the default.
@MainActor @Observable
final class AudioMixer {
    static let shared = AudioMixer()

    private(set) var apps: [AudioApp] = []
    private(set) var settings: [String: AudioAppSettings] = [:]
    private(set) var levels: [String: Float] = [:]
    private(set) var outputs: [OutputDevice] = []
    private(set) var systemOutputName = ""
    private(set) var systemVolume: Float = 0.5
    private(set) var systemMuted = false
    private(set) var hasSystemVolume = false
    private(set) var permission = AudioCapturePermission.state
    private(set) var failures: [String: String] = [:]
    /// Apps whose audio currently runs through Orbit.
    private(set) var routed: Set<String> = []
    /// When a routed app last made an audible sound. Core Audio's "running output" only means the
    /// app has an output stream open — a web app keeps one open for a muted or paused video — so
    /// "playing" is only claimed for sound Orbit has actually heard.
    private(set) var lastHeard: [String: Date] = [:]

    /// The app is making sound right now (only knowable for apps routed through Orbit).
    func isAudible(_ id: String) -> Bool { lastHeard[id].map { Date().timeIntervalSince($0) < 1.5 } ?? false }

    private(set) var global = GlobalEQSettings()
    /// Everything (but apps with their own tap) is running through the All Sound EQ right now.
    private(set) var globalRouted = false
    private(set) var globalLevel: Float = 0
    private(set) var globalFailure: String?
    @ObservationIgnored private var globalTap: AppTap?
    @ObservationIgnored private var rateListener: (AudioObjectID, AudioObjectPropertyListenerBlock)?

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var processMap: [String: Set<AudioObjectID>] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var requesting = false
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // MARK: Lifecycle

    /// Call once at launch. Re-applies saved settings only if the capture permission is already granted,
    /// so launching never shows a prompt.
    func start() {
        guard !started else { return }
        started = true
        load()
        listen(kAudioHardwarePropertyProcessObjectList) { $0.refresh(); $0.syncAll() }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { $0.refreshOutputs(); $0.watchSampleRate(); $0.syncAll() }
        listen(kAudioHardwarePropertyDevices) { $0.refreshOutputs(); $0.syncAll() }
        refresh()
        refreshOutputs()
        watchSampleRate()
        if permission == .granted { syncAll() }
    }

    /// Tears down every tap and aggregate device — call from applicationWillTerminate.
    func shutdown() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
        routed.removeAll()
        removeGlobalTap()
        if let (device, block) = rateListener {
            var a = HAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &a, DispatchQueue.main, block)
            rateListener = nil
        }
        for (addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(HAL.system, &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
        timer?.invalidate()
        timer = nil
        started = false
    }

    /// The Sound page polls levels and volumes only while it's on screen.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if watchers > 0, timer == nil {
            refresh()
            refreshOutputs()
            permission = AudioCapturePermission.state
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
                MainActor.assumeIsolated { AudioMixer.shared.poll() }
            }
        } else if watchers == 0 {
            timer?.invalidate()
            timer = nil
            levels = [:]
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping (AudioMixer) -> Void) {
        let addr = HAL.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler(AudioMixer.shared) }
        }
        var a = addr
        if AudioObjectAddPropertyListenerBlock(HAL.system, &a, DispatchQueue.main, block) == noErr {
            listeners.append((addr, block))
        }
    }

    private func poll() {
        var next: [String: Float] = [:]
        for (id, tap) in taps {
            let peak = min(1, tap.takePeak())
            if peak > 0.002 { lastHeard[id] = Date() }
            next[id] = max(peak, (levels[id] ?? 0) * 0.82) // quick attack, smooth fall
        }
        levels = next
        if let globalTap {
            globalLevel = max(min(1, globalTap.takePeak()), globalLevel * 0.82)
        } else if globalLevel != 0 {
            globalLevel = 0
        }
        tick += 1
        if tick % 15 == 0 { // once a second
            refresh()
            refreshSystemVolume()
        }
    }

    // MARK: Discovery

    func refresh() {
        let own = getpid()
        var map: [String: Set<AudioObjectID>] = [:]
        var playing: Set<String> = []
        var info: [String: NSRunningApplication] = [:]
        for p in HAL.processes() where p.pid > 0 && p.pid != own {
            guard let app = AudioOwner.app(for: p.pid), let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            map[id, default: []].insert(p.object)
            info[id] = app
            if p.isPlaying { playing.insert(id) }
        }
        processMap = map
        let list = info.compactMap { id, app -> AudioApp? in
            guard playing.contains(id) || !(settings[id]?.isDefault ?? true) else { return nil }
            return AudioApp(id: id, name: app.localizedName ?? id, icon: app.icon, isPlaying: playing.contains(id))
        }
        .sorted { ($0.isPlaying ? 0 : 1, $0.name.localizedLowercase) < ($1.isPlaying ? 0 : 1, $1.name.localizedLowercase) }
        if list != apps { apps = list }
    }

    func refreshOutputs() {
        let devices = HAL.allDevices().compactMap { d -> OutputDevice? in
            guard HAL.outputChannels(d) > 0, let uid = HAL.uid(d), !uid.hasPrefix("com.lyu.orbit.tap") else { return nil }
            return OutputDevice(id: uid, name: HAL.name(d) ?? uid)
        }
        if devices != outputs { outputs = devices }
        refreshSystemVolume()
    }

    private func refreshSystemVolume() {
        let d = HAL.defaultOutput
        systemOutputName = HAL.name(d) ?? ""
        let v = HAL.volume(d)
        hasSystemVolume = v != nil
        if let v, abs(v - systemVolume) > 0.001 { systemVolume = v }
        let m = HAL.muted(d)
        if m != systemMuted { systemMuted = m }
    }

    // MARK: System output

    func setSystemVolume(_ v: Float) {
        systemVolume = v
        HAL.setVolume(HAL.defaultOutput, v)
        if systemMuted, v > 0 { setSystemMuted(false) }
    }

    func setSystemMuted(_ muted: Bool) {
        systemMuted = muted
        HAL.setMuted(HAL.defaultOutput, muted)
    }

    // MARK: Per-app settings

    func settings(for id: String) -> AudioAppSettings { settings[id] ?? AudioAppSettings() }

    func setVolume(_ v: Float, for id: String) { update(id) { $0.volume = max(0, min(2, v)) } }
    func setMuted(_ m: Bool, for id: String) { update(id) { $0.muted = m } }
    func setBand(_ band: Int, _ db: Float, for id: String) {
        update(id) { $0.bands[band] = max(GraphicEQ.range.lowerBound, min(GraphicEQ.range.upperBound, db)); $0.preset = nil }
    }
    func applyPreset(_ preset: EQPreset, for id: String) { update(id) { $0.bands = preset.bands; $0.preset = preset.id } }
    func setDevice(_ uid: String?, for id: String) { update(id) { $0.deviceUID = uid } }
    func reset(_ id: String) { update(id) { $0 = AudioAppSettings() } }

    private func update(_ id: String, _ change: (inout AudioAppSettings) -> Void) {
        var s = settings(for: id)
        change(&s)
        if s.isDefault { settings[id] = nil } else { settings[id] = s }
        save()
        sync(id)
    }

    private func load() {
        if let data = Pref.defaults.data(forKey: Pref.audioGlobal),
           let saved = try? JSONDecoder().decode(GlobalEQSettings.self, from: data) {
            global = saved
        }
        guard let data = Pref.defaults.data(forKey: Pref.audioApps),
              let saved = try? JSONDecoder().decode([String: AudioAppSettings].self, from: data) else { return }
        settings = saved.filter { !$0.value.isDefault }
    }

    private func save() {
        Pref.defaults.set(try? JSONEncoder().encode(settings), forKey: Pref.audioApps)
    }

    // MARK: Taps

    private func syncAll() {
        for id in Set(taps.keys).union(settings.keys) { sync(id) }
        syncGlobal()
    }

    private func sync(_ id: String) {
        let s = settings(for: id)
        guard !s.isDefault, let processes = processMap[id], !processes.isEmpty else { removeTap(id); return }

        switch AudioCapturePermission.state {
        case .granted: permission = .granted
        case .denied:
            permission = .denied
            removeTap(id)
            return
        case .unknown:
            permission = .unknown
            guard !requesting else { return }
            requesting = true
            Task {
                let granted = await AudioCapturePermission.request()
                requesting = false
                permission = granted ? .granted : AudioCapturePermission.state
                if granted { syncAll() }
            }
            return
        }

        let followed = s.deviceUID.flatMap { uid in outputs.contains { $0.id == uid } ? uid : nil }
        guard let uid = followed ?? HAL.uid(HAL.defaultOutput) else { removeTap(id); return }

        let bands = effectiveBands(s)
        if let tap = taps[id], tap.processes == processes, tap.deviceUID == uid {
            tap.publish(gain: s.gain, bands: bands)
            return
        }
        removeTap(id)
        defer { syncGlobal() }
        do {
            taps[id] = try AppTap(bundleID: id, processes: processes, deviceUID: uid, gain: s.gain, bands: bands)
            routed.insert(id)
            failures[id] = nil
            AudioLog.write("tap \(id): \(processes.count) process(es) → \(uid), gain \(s.gain)")
        } catch {
            failures[id] = error.localizedDescription
            AudioLog.write("tap \(id) failed: \(error.localizedDescription)")
        }
    }

    private func removeTap(_ id: String) {
        guard let tap = taps.removeValue(forKey: id) else { return }
        tap.stop()
        routed.remove(id)
        levels[id] = nil
        lastHeard[id] = nil
        AudioLog.write("tap \(id) removed")
        syncGlobal()
    }

    /// An app with its own tap is left out of the global one (or its sound would play twice), so it
    /// gets the All Sound curve inside its own chain instead: the two curves add up, band by band.
    private func effectiveBands(_ s: AudioAppSettings) -> [Float] {
        guard global.isActive else { return s.bands }
        return (0..<GraphicEQ.bands).map { i in max(-24, min(24, s.bands[i] + global.bands[i])) }
    }

    // MARK: All Sound EQ

    func setGlobalEnabled(_ on: Bool) { updateGlobal { $0.enabled = on } }
    func setGlobalBand(_ band: Int, _ db: Float) {
        updateGlobal { $0.bands[band] = max(GraphicEQ.range.lowerBound, min(GraphicEQ.range.upperBound, db)); $0.preset = nil }
    }
    func applyGlobalPreset(_ preset: EQPreset) { updateGlobal { $0.bands = preset.bands; $0.preset = preset.id } }
    func resetGlobal() { updateGlobal { $0.bands = EQPreset.flat.bands; $0.preset = EQPreset.flat.id } }

    private func updateGlobal(_ change: (inout GlobalEQSettings) -> Void) {
        let wasActive = global.isActive
        change(&global)
        Pref.defaults.set(try? JSONEncoder().encode(global), forKey: Pref.audioGlobal)
        syncGlobal()
        // Apps with their own tap carry the global curve too.
        if wasActive || global.isActive {
            for (id, tap) in taps { let st = settings(for: id); tap.publish(gain: st.gain, bands: effectiveBands(st)) }
        }
    }

    /// Brings the global tap in line with the settings, the output device and the apps that have
    /// their own taps. Off means no tap at all — macOS's audio path is left exactly as it was.
    private func syncGlobal(rebuild: Bool = false) {
        guard global.isActive else { removeGlobalTap(); globalFailure = nil; return }
        switch AudioCapturePermission.state {
        case .granted: permission = .granted
        case .denied:
            permission = .denied
            removeGlobalTap()
            return
        case .unknown:
            permission = .unknown
            guard !requesting else { return }
            requesting = true
            Task {
                let granted = await AudioCapturePermission.request()
                requesting = false
                permission = granted ? .granted : AudioCapturePermission.state
                if granted { syncAll() }
            }
            return
        }
        guard let uid = HAL.uid(HAL.defaultOutput) else { removeGlobalTap(); return }
        // Without Orbit's own process in the exclusions the tap would hear what it plays: feedback.
        guard let own = HAL.ownProcessObject() else {
            globalFailure = "Couldn’t start the EQ".loc
            AudioLog.write("global: Orbit's own audio process isn't known yet; not tapping")
            removeGlobalTap()
            return
        }
        let excluded = Set(taps.values.flatMap(\.processes)).union([own])

        if !rebuild, let tap = globalTap, tap.deviceUID == uid {
            if tap.excluded != excluded {
                if tap.updateExclusions(excluded) {
                    AudioLog.write("global: now leaving out \(excluded.count) process(es)")
                } else {
                    return syncGlobal(rebuild: true)
                }
            }
            tap.publish(gain: 1, bands: global.bands)
            return
        }
        removeGlobalTap()
        do {
            globalTap = try AppTap(bundleID: "all-sound", processes: [], excluding: excluded, deviceUID: uid, gain: 1, bands: global.bands)
            globalRouted = true
            globalFailure = nil
            AudioLog.write("global: tapping everything but \(excluded.count) process(es) → \(uid) at \(Int(HAL.sampleRate(HAL.defaultOutput))) Hz")
        } catch {
            globalFailure = error.localizedDescription
            AudioLog.write("global failed: \(error.localizedDescription)")
        }
    }

    private func removeGlobalTap() {
        guard let tap = globalTap else { return }
        globalTap = nil
        tap.stop()
        globalRouted = false
        globalLevel = 0
        AudioLog.write("global: removed")
    }

    /// The filters are designed for one sample rate; when the output switches rates (a DAC, AirPods
    /// switching profiles) the taps are rebuilt at the new one.
    private func watchSampleRate() {
        let device = HAL.defaultOutput
        if let (old, block) = rateListener {
            guard old != device else { return }
            var a = HAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(old, &a, DispatchQueue.main, block)
            rateListener = nil
        }
        guard device != kAudioObjectUnknown else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { AudioMixer.shared.sampleRateChanged() }
        }
        var a = HAL.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(device, &a, DispatchQueue.main, block) == noErr {
            rateListener = (device, block)
        }
    }

    private func sampleRateChanged() {
        AudioLog.write("output sample rate is now \(Int(HAL.sampleRate(HAL.defaultOutput))) Hz; rebuilding taps")
        for id in Array(taps.keys) {
            taps.removeValue(forKey: id)?.stop()
            routed.remove(id)
        }
        syncAll()
        syncGlobal(rebuild: true)
    }
}

/// ~/Library/Logs/Orbit/audio.log — which apps Orbit routed, where, and what failed.
enum AudioLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("audio.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
