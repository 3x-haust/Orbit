import AppKit
import CoreAudio

/// Thin, typed wrappers over the Core Audio HAL property API.
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        return AudioObjectHasProperty(object, &a)
    }

    static func read<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T {
        var a = addr
        var out = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &out) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? out : value
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = addr
        var v = value
        return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func settable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var a = addr
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &ok) == noErr && ok.boolValue
    }

    static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of _: T.Type) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var a = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Devices

    static var defaultOutput: AudioObjectID {
        read(system, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(kAudioObjectUnknown))
    }

    static func uid(_ device: AudioObjectID) -> String? { string(device, address(kAudioDevicePropertyDeviceUID)) }
    static func name(_ device: AudioObjectID) -> String? { string(device, address(kAudioObjectPropertyName)) }

    static func device(uid: String) -> AudioObjectID? {
        allDevices().first { HAL.uid($0) == uid }
    }

    static func allDevices() -> [AudioObjectID] { array(system, address(kAudioHardwarePropertyDevices), of: AudioObjectID.self) }

    static func outputChannels(_ device: AudioObjectID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRate(_ device: AudioObjectID) -> Double {
        read(device, address(kAudioDevicePropertyNominalSampleRate), default: 48_000.0)
    }

    // MARK: Volume (default output)

    /// Main element if the device has one, otherwise the first two channels.
    static func volumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        let main = address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        if has(device, main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { has(device, address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0)) }
    }

    static func volume(_ device: AudioObjectID) -> Float? {
        let elements = volumeElements(device)
        guard !elements.isEmpty else { return nil }
        let values = elements.map { read(device, address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0), default: Float32(0)) }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(_ device: AudioObjectID, _ value: Float) {
        for e in volumeElements(device) {
            set(device, address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: e), Float32(max(0, min(1, value))))
        }
    }

    static func muted(_ device: AudioObjectID) -> Bool {
        read(device, address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput), default: UInt32(0)) != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        set(device, address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput), UInt32(muted ? 1 : 0))
    }

    // MARK: Processes

    struct Process {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isPlaying: Bool
    }

    /// Orbit's own audio process object — what a global tap must leave out, or it would capture the
    /// sound it plays itself and feed back.
    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        if status == noErr, object != kAudioObjectUnknown { return object }
        return processes().first { $0.pid == pid }?.object
    }

    /// PIDs of the processes playing sound right now: one read per process, plus the PID of the few
    /// that play — cheaper than ``processes()`` for something that asks every second.
    static func playingPIDs() -> [pid_t] {
        array(system, address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self).compactMap { obj in
            guard read(obj, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0 else { return nil }
            let pid = read(obj, address(kAudioProcessPropertyPID), default: pid_t(-1))
            return pid > 0 ? pid : nil
        }
    }

    static func processes() -> [Process] {
        array(system, address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self).map { obj in
            Process(object: obj,
                    pid: read(obj, address(kAudioProcessPropertyPID), default: pid_t(-1)),
                    bundleID: string(obj, address(kAudioProcessPropertyBundleID)),
                    isPlaying: read(obj, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0)
        }
    }
}

/// Which app a process's audio belongs to. Browsers and Safari play from helper processes
/// (Chrome Helper, WebKit GPU), so audio is attributed to the app responsible for them.
enum AudioOwner {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    @MainActor static func app(for pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        if let responsible, case let owner = responsible(pid), owner > 0, owner != pid,
           let app = NSRunningApplication(processIdentifier: owner), app.activationPolicy == .regular {
            return app
        }
        // Fall back to the outermost .app that contains the helper's bundle.
        guard let path = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path,
              let range = path.range(of: ".app/") else { return nil }
        let outer = String(path[..<range.upperBound].dropLast())
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == outer && $0.activationPolicy == .regular }
    }
}

/// System Audio Recording permission (needed to tap another app's audio). There's no public
/// API to check it, so this uses TCC the way Apple's own sample code does.
enum AudioCapturePermission {
    enum State { case granted, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @convention(block) @escaping (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var state: State {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't decided yet.
    static func request() async -> Bool {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return false }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        return await withCheckedContinuation { continuation in
            fn(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}
