import AppKit
import IOKit

/// Raw touches from every trackpad — the built-in one and Magic Trackpads — through macOS's private
/// MultitouchSupport framework, the same one BetterTouchTool and MiddleClick read. It only reads:
/// the pad keeps pointing, clicking and its own gestures exactly as before.
///
/// Loaded at run time, so a macOS without it just means no trackpad gestures. Devices are picked up
/// again when one is plugged in or removed, and after sleep.
final class MultitouchSource: @unchecked Sendable {
    static let shared = MultitouchSource()

    /// MTTouch, as the framework lays it out (96 bytes).
    private struct MTPoint { var x: Float; var y: Float }
    private struct MTVector { var position: MTPoint; var velocity: MTPoint }
    private struct MTTouch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        var normalized: MTVector
        var size: Float
        var zero1: Int32
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var millimeters: MTVector
        var zero2: (Int32, Int32)
        var density: Float
    }

    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Dimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

    private struct API {
        let createList: CreateList
        let register: Register
        let unregister: Register
        let start: Start
        let stop: Stop
        let dimensions: Dimensions?
    }

    private let api: API?
    private let lock = NSLock()
    /// Per device: its size in mm and its own recognizer.
    private var devices: [UnsafeMutableRawPointer: (size: CGSize, recognizer: TouchRecognizer)] = [:]
    private var list: CFMutableArray?
    private var running = false
    private var observers: [Any] = []
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var restartWork: DispatchWorkItem?

    /// Called on the framework's own thread; keep it quick.
    var onGesture: (@Sendable (TrackpadGesture) -> Void)?
    /// Every frame, fingers in 0...1 of the pad (y up), for the live view; only while it's set.
    var onFrame: (@Sendable ([CGPoint]) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }
    private var frameHandler: (@Sendable ([CGPoint]) -> Void)?

    var isAvailable: Bool { api != nil }

    private init() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let create = dlsym(h, "MTDeviceCreateList"),
              let register = dlsym(h, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(h, "MTUnregisterContactFrameCallback"),
              let start = dlsym(h, "MTDeviceStart"),
              let stop = dlsym(h, "MTDeviceStop") else { api = nil; return }
        api = API(createList: unsafeBitCast(create, to: CreateList.self),
                  register: unsafeBitCast(register, to: Register.self),
                  unregister: unsafeBitCast(unregister, to: Register.self),
                  start: unsafeBitCast(start, to: Start.self),
                  stop: unsafeBitCast(stop, to: Stop.self),
                  dimensions: dlsym(h, "MTDeviceGetSensorSurfaceDimensions").map { unsafeBitCast($0, to: Dimensions.self) })
    }

    // MARK: Running

    @MainActor func start() {
        guard api != nil, !running else { return }
        running = true
        attach()
        watchDevices()
        let ws = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification].map {
            ws.addObserver(forName: $0, object: nil, queue: .main) { _ in MainActor.assumeIsolated { MultitouchSource.shared.restartSoon() } }
        }
        GestureLog.write("trackpad: listening to \(lock.withLock { devices.count }) device(s)")
    }

    @MainActor func stop() {
        guard running else { return }
        running = false
        detach()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
            IONotificationPortDestroy(notifyPort)
        }
        notifyPort = nil
        restartWork?.cancel()
        GestureLog.write("trackpad: stopped")
    }

    /// A pad came or went, or the Mac woke: the framework's device list is stale, so take a new one.
    @MainActor func restartSoon() {
        guard running else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let s = MultitouchSource.shared
                guard s.running else { return }
                s.detach()
                s.attach()
                GestureLog.write("trackpad: devices changed, now \(s.lock.withLock { s.devices.count })")
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func attach() {
        guard let api, let list = api.createList()?.takeRetainedValue() else { return }
        self.list = list
        var found: [UnsafeMutableRawPointer: (size: CGSize, recognizer: TouchRecognizer)] = [:]
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var w: Int32 = 0, h: Int32 = 0
            // Hundredths of a millimetre; a built-in pad is about 160 × 100 mm.
            if let dims = api.dimensions, dims(device, &w, &h) == 0, w > 0, h > 0 {
                found[device] = (CGSize(width: Double(w) / 100, height: Double(h) / 100), TouchRecognizer())
            } else {
                found[device] = (CGSize(width: 160, height: 100), TouchRecognizer())
            }
        }
        lock.withLock { devices = found }
        for device in found.keys {
            api.register(device, Self.callback)
            api.start(device, 0)
        }
    }

    private func detach() {
        guard let api else { return }
        let all = lock.withLock { () -> [UnsafeMutableRawPointer] in
            let keys = Array(devices.keys)
            devices = [:]
            return keys
        }
        for device in all {
            api.unregister(device, Self.callback)
            api.stop(device)
        }
        list = nil
    }

    /// IOKit tells us when a multitouch device is added or removed (a Magic Trackpad connecting).
    @MainActor private func watchDevices() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let callback: IOServiceMatchingCallback = { _, iterator in
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            DispatchQueue.main.async { MainActor.assumeIsolated { MultitouchSource.shared.restartSoon() } }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching("AppleMultitouchDevice"), callback, nil, &iterator) == KERN_SUCCESS else { continue }
            // Drain once to arm it; what's there now is already attached.
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            iterators.append(iterator)
        }
    }

    // MARK: Frames

    private static let callback: Callback = { device, data, count, timestamp, _ in
        guard let device else { return 0 }
        MultitouchSource.shared.handle(device: device, data: data, count: Int(count), time: timestamp)
        return 0
    }

    private func handle(device: UnsafeMutableRawPointer, data: UnsafeMutableRawPointer?, count: Int, time: Double) {
        var points: [TouchPoint] = []
        var unit: [CGPoint] = []
        lock.lock()
        guard let entry = devices[device] else { lock.unlock(); return }
        if let data, count > 0 {
            let touches = data.bindMemory(to: MTTouch.self, capacity: count)
            for i in 0..<count {
                let t = touches[i]
                // 3 hovering, 4 landing, 5 touching, 6 lifting: only fingers on the glass count.
                guard t.state == 4 || t.state == 5 else { continue }
                let x = Double(t.normalized.position.x), y = Double(t.normalized.position.y)
                points.append(TouchPoint(id: Int(t.identifier), x: x * entry.size.width, y: y * entry.size.height))
                unit.append(CGPoint(x: x, y: y))
            }
        }
        // A pad clicked down is a click, not a tap — only worth asking while three fingers are on it.
        let pressed = points.count >= 2 && CGEventSource.buttonState(.combinedSessionState, button: .left)
        var recognizer = entry.recognizer
        let gesture = recognizer.feed(TouchFrame(time: time, touches: points, pressed: pressed))
        devices[device]?.recognizer = recognizer
        let frames = frameHandler
        lock.unlock()
        frames?(unit)
        if let gesture { onGesture?(gesture) }
    }
}
