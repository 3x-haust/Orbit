import Foundation
import IOKit
import IOKit.hid

/// The motion sensor inside Apple silicon MacBooks, read directly. macOS has no public API for it,
/// but the sensor hub lists it as an HID device (Apple's vendor page, usage 3) that any app can open
/// once its driver is told to report — the same way the "knock" and "slap" apps reach it.
///
/// Samples come on a thread of the sensor's own, so a busy main thread never drops a knock; the hub
/// sends them in batches, which keeps reading them to a fraction of a percent of one core.
final class KnockSensor: @unchecked Sendable {
    /// One sample in g, with when it was taken (system uptime).
    typealias Handler = (_ x: Double, _ y: Double, _ z: Double, _ time: TimeInterval) -> Void

    /// 400 samples a second: a knock's jolt lasts a few milliseconds.
    static let interval: TimeInterval = 0.0025
    /// The hub holds samples back and sends them together, every 20ms: cheap, and close enough in time
    /// to tell a knock's beat.
    private static let batch: TimeInterval = 0.02
    private static let usagePage = 0xFF00, usage = 3

    /// The Mac has the sensor (MacBooks with M2 or later, and some M1 Pro).
    static var available: Bool {
        let device = service("AppleSPUHIDDevice")
        defer { if device != 0 { IOObjectRelease(device) } }
        return device != 0
    }

    private let handler: Handler
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false
    /// When the last sample came, for noticing the sensor going quiet (after sleep).
    private var lastReport: TimeInterval = 0
    private var clock: TimeInterval = 0

    init(handler: @escaping Handler) { self.handler = handler }

    /// Starts reading on a thread of its own. False when there's no sensor or it can't be opened.
    func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return true }
        Self.wake()
        let service = Self.service("AppleSPUHIDDevice")
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
              IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        running = true
        lastReport = ProcessInfo.processInfo.systemUptime
        let t = Thread { [weak self] in self?.loop(device) }
        t.name = "Orbit knock sensor"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        return true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
        thread = nil
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func loop(_ device: IOHIDDevice) {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
        defer { buffer.deallocate() }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            guard let context, length >= 18 else { return }
            Unmanaged<KnockSensor>.fromOpaque(context).takeUnretainedValue().report(report)
        }, context)
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        // Asked again once open: the driver only starts reporting with a reader attached.
        Self.wake()
        while isRunning {
            CFRunLoopRunInMode(.defaultMode, 0.5, true)
            // Quiet for a while (the Mac slept, or the hub reset): ask the driver again.
            if ProcessInfo.processInfo.systemUptime - lastReport > 2 {
                Self.wake()
                lastReport = ProcessInfo.processInfo.systemUptime
            }
        }
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// x, y and z as 32-bit little-endian Q16 numbers at bytes 6, 10 and 14.
    private func report(_ r: UnsafePointer<UInt8>) {
        func g(_ o: Int) -> Double {
            Double(Int32(bitPattern: UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24)) / 65536
        }
        // Samples of a batch all arrive at once: they're spread back over the time they were taken,
        // and the clock never runs ahead of now or falls far behind it.
        let now = ProcessInfo.processInfo.systemUptime
        clock = min(now, max(clock + Self.interval, now - Self.batch * 2))
        lastReport = now
        handler(g(6), g(10), g(14), clock)
    }

    /// Tells the accelerometer's driver to power up and report, and how often. Only its own driver:
    /// the hub's other sensors (the lid angle, the gyroscope…) are left as they are.
    private static func wake() {
        let driver = service("AppleSPUHIDDriver")
        guard driver != 0 else { return }
        defer { IOObjectRelease(driver) }
        let values: [(String, Int)] = [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1),
                                       ("ReportInterval", Int(interval * 1_000_000)), ("BatchInterval", Int(batch * 1_000_000))]
        for (key, value) in values {
            IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)
        }
    }

    /// The accelerometer's entry of this IOKit class (the caller releases it), or 0.
    private static func service(_ name: String) -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            func number(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            // The driver doesn't say its usage page; the device does.
            if number("PrimaryUsage") == usage, (number("PrimaryUsagePage") ?? usagePage) == usagePage { return entry }
            IOObjectRelease(entry)
        }
        return 0
    }
}
