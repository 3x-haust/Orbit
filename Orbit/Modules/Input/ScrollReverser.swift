import AppKit
import CoreGraphics
import IOKit
import IOKit.hidsystem
import os

/// Separate scroll directions for the mouse and the trackpad — macOS ties them to one "natural
/// scrolling" switch — plus speed and smooth scrolling for wheel mice.
///
/// Works on the scroll events themselves through an event tap (needs Accessibility); see ``ScrollTap``
/// for how each event's device is told.
@MainActor @Observable
final class ScrollReverser {
    static let shared = ScrollReverser()

    enum Device: String, Sendable { case mouse, trackpad }

    private enum Key {
        static let enabled = "scroll.enabled"
        static let mouseNatural = "scroll.mouseNatural"
        static let trackpadNatural = "scroll.trackpadNatural"
        static let horizontal = "scroll.horizontal"
        static let smooth = "scroll.smooth"
        static let speed = "scroll.speed"
        static let step = "scroll.step"
    }

    var enabled: Bool { didSet { save(enabled, Key.enabled); apply() } }
    /// Content follows the fingers ("natural"), per device.
    var mouseNatural: Bool { didSet { save(mouseNatural, Key.mouseNatural); apply() } }
    var trackpadNatural: Bool { didSet { save(trackpadNatural, Key.trackpadNatural); apply() } }
    /// Apply the same direction to sideways scrolling.
    var horizontal: Bool { didSet { save(horizontal, Key.horizontal); apply() } }
    /// Glide between wheel notches instead of jumping a line at a time.
    var smooth: Bool { didSet { save(smooth, Key.smooth); apply() } }
    /// Wheel speed multiplier (mice only; trackpads keep their own feel).
    var speed: Double { didSet { save(speed, Key.speed); apply() } }
    /// Lines per wheel notch, or 0 to leave notches as macOS accelerates them (wheel mice only).
    var step: Int { didSet { save(step, Key.step); apply() } }

    /// The device of the latest scroll, for the live diagram.
    private(set) var lastDevice: Device?
    private(set) var lastScroll: Date?
    /// The system-wide setting, which macOS applies to every device.
    private(set) var systemNatural = ScrollReverser.readSystemNatural() { didSet { apply() } }

    /// On its own thread: every scroll on the Mac goes through the tap, and on the main run loop each
    /// one waited for whatever the main thread was busy with.
    nonisolated(unsafe) private static var live: EventTapThread?
    /// What the tap thread works from; refreshed on the main thread whenever a setting changes.
    fileprivate struct Config: Sendable {
        var mouseNatural = true, trackpadNatural = true, systemNatural = true
        var horizontal = true, smooth = false, speed = 1.0, step = 0
    }
    fileprivate static let config = OSAllocatedUnfairLock(initialState: Config())
    private var smoother: SmoothScroller?

    /// Tag on the events Orbit posts itself for smooth scrolling, so the tap lets them through.
    fileprivate nonisolated static let ownTag: Int64 = 0x4F52_4249 // "ORBI"

    private init() {
        let d = Pref.defaults
        let natural = Self.readSystemNatural()
        enabled = d.object(forKey: Key.enabled) as? Bool ?? false
        mouseNatural = d.object(forKey: Key.mouseNatural) as? Bool ?? natural
        trackpadNatural = d.object(forKey: Key.trackpadNatural) as? Bool ?? natural
        horizontal = d.object(forKey: Key.horizontal) as? Bool ?? true
        smooth = d.object(forKey: Key.smooth) as? Bool ?? false
        speed = d.object(forKey: Key.speed) as? Double ?? 1
        step = d.object(forKey: Key.step) as? Int ?? 0
        DistributedNotificationCenter.default().addObserver(forName: .init("SwipeScrollDirectionDidChangeNotification"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScrollReverser.shared.systemNatural = ScrollReverser.readSystemNatural() }
        }
    }

    private func save(_ value: Any, _ key: String) { Pref.defaults.set(value, forKey: key) }

    func start() { apply() }

    /// Whether anything needs changing at all; with nothing to do, no tap is installed.
    private var needed: Bool {
        enabled && (mouseNatural != systemNatural || trackpadNatural != systemNatural || smooth || abs(speed - 1) > 0.01 || step > 0)
    }

    func refreshSystemSetting() { systemNatural = Self.readSystemNatural() }

    private static func readSystemNatural() -> Bool {
        UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
    }

    private func apply() {
        let c = Config(mouseNatural: mouseNatural, trackpadNatural: trackpadNatural, systemNatural: systemNatural,
                       horizontal: horizontal, smooth: smooth, speed: speed, step: step)
        Self.config.withLock { $0 = c }
        if needed { install() } else { uninstall() }
        if !(enabled && smooth) { smoother = nil }
    }

    // MARK: Tap

    private func install() {
        guard Self.live == nil else { return }
        guard AXIsProcessTrusted() else {
            ScrollLog.write("tap skipped: no Accessibility")
            return
        }
        // At the tail, after macOS has applied its own direction, so each event says whether it's natural.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                          eventsOfInterest: 1 << CGEventType.scrollWheel.rawValue,
                                          callback: scrollCallback, userInfo: nil) else {
            ScrollLog.write("tap create failed")
            return
        }
        Self.live = EventTapThread(port: tap, name: "Orbit scrolling")
        ScrollLog.write("tap on (mouse natural \(mouseNatural), trackpad natural \(trackpadNatural), system \(systemNatural), sideways \(horizontal), step \(step), smooth \(smooth), speed \(speed))")
    }

    private func uninstall() {
        guard let live = Self.live else { return }
        live.stop()
        Self.live = nil
        ScrollLog.write("tap off")
    }

    fileprivate nonisolated static func reenable() { live?.reenable() }

    fileprivate func glide(vertical: Double, horizontal: Double) {
        guard enabled, smooth else { return }
        if smoother == nil { smoother = SmoothScroller() }
        smoother?.add(vertical: vertical, horizontal: horizontal)
    }

    fileprivate func note(_ device: Device) {
        lastDevice = device
        lastScroll = Date()
    }
}

private func scrollCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        ScrollReverser.reenable()
        return Unmanaged.passUnretained(event)
    case .scrollWheel:
        return ScrollTap.handle(event).map { Unmanaged.passUnretained($0) }
    default:
        return Unmanaged.passUnretained(event)
    }
}

/// The scroll work itself, on the tap's thread. Only the smooth glide and the live diagram reach
/// the main thread, and neither holds up the event.
///
/// Which device scrolled comes from the HID event behind the scroll event: its sender is the
/// IORegistry entry of the device's event service, and trackpads are the ones driven by the
/// multitouch trackpad driver (or using trackpad scroll acceleration). So a Magic Mouse counts as a
/// mouse, a momentum glide belongs to the trackpad that started it, and scrolls posted by apps
/// (no HID event) are left alone. Whether macOS already applied natural scrolling is read off each
/// event, not from the setting.
private enum ScrollTap {
    /// nil: not a device of its own (left as it is). Looked up once per sender; senders don't get reused within a boot.
    nonisolated(unsafe) static var senders: [UInt64: ScrollReverser.Device?] = [:]
    /// Senders not in the IORegistry yet (virtual services, like Universal Control's), and when to look again.
    nonisolated(unsafe) static var retryAt: [UInt64: CFAbsoluteTime] = [:]
    nonisolated(unsafe) static var noted: (ScrollReverser.Device, CFAbsoluteTime)?

    /// Returns nil to swallow the event (smooth scrolling re-posts it in pieces).
    static func handle(_ event: CGEvent) -> CGEvent? {
        if event.getIntegerValueField(.eventSourceUserData) == ScrollReverser.ownTag { return event }
        let config = ScrollReverser.config.withLock { $0 }
        let hid = HIDEvent(event)
        // Posted by an app (or Sidecar): that app chose the direction itself.
        guard let hid, let device = device(sender: hid.sender) else { return event }
        note(device)

        let natural = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? config.systemNatural
        let reverseVertical = (device == .mouse ? config.mouseNatural : config.trackpadNatural) != natural
        let reverseHorizontal = config.horizontal && reverseVertical
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        let axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let axis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)

        // Wheel notches: a fixed number of lines each, instead of macOS's accelerated amount.
        let step = continuous || config.smooth ? 0 : config.step
        let vDiscrete = step > 0 && abs(axis1) == 1
        let hDiscrete = step > 0 && abs(axis2) == 1
        let vmul = Int64(vDiscrete ? step : 1) * (reverseVertical ? -1 : 1)
        let hmul = Int64(hDiscrete ? step : 1) * (reverseHorizontal ? -1 : 1)

        // The line delta first: setting it makes macOS recompute the point and fixed-point deltas from
        // it. Then the precise ones (and the HID event's, which some apps read instead), or trackpad
        // scrolling would lose its smoothness.
        if vDiscrete || vmul != 1 { event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: axis1 * vmul) }
        if !vDiscrete && vmul != 1 {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed1 * Double(vmul))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: point1 * vmul)
            hid.negate(HIDEvent.scrollY)
        }
        if hDiscrete || hmul != 1 { event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: axis2 * hmul) }
        if !hDiscrete && hmul != 1 {
            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed2 * Double(hmul))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point2 * hmul)
            hid.negate(HIDEvent.scrollX)
        }

        // Orbit's extras, for wheel mice only.
        guard device == .mouse, !continuous else { return event }
        if config.smooth {
            let lines = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * config.speed
            let sideways = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * config.speed
            DispatchQueue.main.async { MainActor.assumeIsolated { ScrollReverser.shared.glide(vertical: lines, horizontal: sideways) } }
            return nil
        }
        if step == 0, abs(config.speed - 1) > 0.01 { ScrollReverser.scale(event, by: config.speed) }
        return event
    }

    private static func device(sender: UInt64) -> ScrollReverser.Device? {
        // A HID event with no sender: some device, but not one that can be told apart; treat it as a mouse.
        guard sender != 0 else { return .mouse }
        let now = CFAbsoluteTimeGetCurrent()
        if let known = senders[sender], retryAt[sender].map({ now < $0 }) ?? true { return known }
        if let found = lookUp(sender) {
            senders[sender] = found
            retryAt[sender] = nil
            ScrollLog.write("scroll sender 0x\(String(sender, radix: 16)) is a \(found.rawValue)")
            return found
        }
        senders[sender] = .mouse
        retryAt[sender] = now + 0.25
        return .mouse
    }

    private static func lookUp(_ sender: UInt64) -> ScrollReverser.Device? {
        if let matching = IORegistryEntryIDMatching(sender) {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if service != 0 {
                defer { IOObjectRelease(service) }
                return isTrackpad(service) ? .trackpad : .mouse
            }
        }
        // Virtual services (Universal Control) copy the real device's properties.
        guard let client = remoteClient,
              let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return nil }
        for service in services {
            guard (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value == sender else { continue }
            let accel = IOHIDServiceClientCopyProperty(service, "HIDScrollAccelerationType" as CFString) as? String
            return accel == "HIDTrackpadScrollAcceleration" ? .trackpad : .mouse
        }
        return nil
    }

    nonisolated(unsafe) private static let remoteClient: IOHIDEventSystemClient? = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    private static func isTrackpad(_ service: io_service_t) -> Bool {
        let accel = IORegistryEntryCreateCFProperty(service, "HIDScrollAccelerationType" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        if accel == "HIDTrackpadScrollAcceleration" { return true }
        // The multitouch driver publishes a child service that sends the events; check its parent too.
        let driver = "AppleMultitouchTrackpadHIDEventDriver"
        if IOObjectConformsTo(service, driver) != 0 { return true }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, driver) != 0
    }

    /// Only tells the main thread when the device changes, or once a second, to keep SwiftUI quiet.
    private static func note(_ device: ScrollReverser.Device) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = noted, last.0 == device, now - last.1 <= 1 { return }
        noted = (device, now)
        DispatchQueue.main.async { MainActor.assumeIsolated { ScrollReverser.shared.note(device) } }
    }
}

/// The HID event a scroll event was made from (private API, as macOS keeps it): who sent it, and the
/// deltas some apps read in place of the scroll event's own.
private struct HIDEvent {
    static let scrollX: UInt32 = 6 << 16
    static let scrollY: UInt32 = 6 << 16 | 1

    private typealias Copy = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias Sender = @convention(c) (CFTypeRef) -> UInt64
    private typealias GetFloat = @convention(c) (CFTypeRef, UInt32) -> Double
    private typealias SetFloat = @convention(c) (CFTypeRef, UInt32, Double) -> Void

    nonisolated(unsafe) private static let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    nonisolated(unsafe) private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let copy: Copy? = sym(graphics, "CGEventCopyIOHIDEvent")
    private static let sender: Sender? = sym(iokit, "IOHIDEventGetSenderID")
    private static let getFloat: GetFloat? = sym(iokit, "IOHIDEventGetFloatValue")
    private static let setFloat: SetFloat? = sym(iokit, "IOHIDEventSetFloatValue")

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private let ref: CFTypeRef
    let sender: UInt64

    init?(_ event: CGEvent) {
        guard let copy = Self.copy, let ref = copy(event)?.takeRetainedValue() else { return nil }
        self.ref = ref
        sender = Self.sender?(ref) ?? 0
    }

    func negate(_ field: UInt32) {
        guard let getFloat = Self.getFloat, let setFloat = Self.setFloat else { return }
        setFloat(ref, field, -getFloat(ref, field))
    }
}

private extension ScrollReverser {
    fileprivate nonisolated static func scale(_ e: CGEvent, by k: Double) {
        for (fixed, point, int) in [(CGEventField.scrollWheelEventFixedPtDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis1),
                                    (.scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventDeltaAxis2)] {
            let v = e.getDoubleValueField(fixed)
            guard v != 0 else { continue }
            let pt = e.getIntegerValueField(point)
            // Lines first (never rounding a notch away to nothing): setting them makes macOS recompute
            // the other two, which are set after.
            e.setIntegerValueField(int, value: Int64((v * k).rounded(.awayFromZero)))
            e.setDoubleValueField(fixed, value: v * k)
            e.setIntegerValueField(point, value: Int64((Double(pt) * k).rounded()))
        }
    }
}

/// Turns wheel notches into a short glide of pixel scrolls, eased out, at display rate.
@MainActor
private final class SmoothScroller {
    private var remainingY = 0.0, remainingX = 0.0
    private var timer: Timer?
    /// Pixels per wheel line.
    private let lineHeight = 44.0
    private let source = CGEventSource(stateID: .hidSystemState)

    func add(vertical: Double, horizontal: Double) {
        // A new notch in the other direction cancels what's left of the glide.
        if vertical != 0, remainingY != 0, vertical.sign != remainingY.sign { remainingY = 0 }
        if horizontal != 0, remainingX != 0, horizontal.sign != remainingX.sign { remainingX = 0 }
        remainingY += vertical * lineHeight
        remainingX += horizontal * lineHeight
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { self.step() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func step() {
        // Each frame covers a share of what's left: fast at first, settling softly.
        let k = 0.2
        var dy = remainingY * k, dx = remainingX * k
        if abs(remainingY) < 1 { dy = remainingY }
        if abs(remainingX) < 1 { dx = remainingX }
        let iy = Int32(dy.rounded()), ix = Int32(dx.rounded())
        remainingY -= Double(iy)
        remainingX -= Double(ix)
        if abs(remainingY) < 0.5 { remainingY = 0 }
        if abs(remainingX) < 0.5 { remainingX = 0 }
        if iy != 0 || ix != 0,
           let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) {
            e.setIntegerValueField(.eventSourceUserData, value: ScrollReverser.ownTag)
            e.post(tap: .cgSessionEventTap)
        }
        if remainingY == 0 && remainingX == 0 {
            timer?.invalidate()
            timer = nil
        }
    }
}

enum ScrollLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("input.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
