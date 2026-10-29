import Foundation
import CoreGraphics
import IOKit

/// The private calls that set a screen's brightness. Looked up at run time, so a macOS that drops one
/// only loses that control instead of keeping Orbit from launching.
enum DisplayPrivate {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    typealias AVCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias AVWriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let services = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static let getBrightness: GetBrightness? = sym(services, "DisplayServicesGetBrightness")
    private static let setBrightness: SetBrightness? = sym(services, "DisplayServicesSetBrightness")
    private static let canChange: CanChange? = sym(services, "DisplayServicesCanChangeBrightness")
    static let avCreate: AVCreate? = sym(iokit, "IOAVServiceCreateWithService")
    static let avRead: AVReadI2C? = sym(iokit, "IOAVServiceReadI2C")
    static let avWrite: AVWriteI2C? = sym(iokit, "IOAVServiceWriteI2C")

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    /// Built-in panels and Apple's own displays (Studio Display, Pro Display XDR).
    static func canSetBrightness(_ id: CGDirectDisplayID) -> Bool { canChange?(id) ?? false }

    static func brightness(_ id: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Double) -> Bool {
        setBrightness?(id, Float(min(max(value, 0), 1))) == 0
    }
}

/// DDC/CI over Apple silicon's display AV service — how external monitors are told their brightness,
/// contrast and volume. The same packets MonitorControl sends (its Arm64DDC), at the monitor's I²C
/// address 0x37.
final class DDCChannel: @unchecked Sendable {
    enum VCP: UInt8 {
        case brightness = 0x10
        case contrast = 0x12
        case inputSource = 0x60
        case volume = 0x62
        case mute = 0x8D
        case power = 0xD6
    }

    private let service: CFTypeRef
    /// One conversation at a time: monitors drop interleaved packets.
    private let lock = NSLock()

    init(service: CFTypeRef) { self.service = service }

    func write(_ vcp: VCP, _ value: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var packet = Self.packet([vcp.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
        var ok = false
        // Monitors miss a write now and then; MonitorControl sends each one twice.
        for _ in 0..<2 {
            usleep(10_000)
            if send(&packet) { ok = true }
        }
        return ok
    }

    /// (current, max), or nil when the monitor doesn't answer.
    func read(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        lock.lock(); defer { lock.unlock() }
        var packet = Self.packet([vcp.rawValue])
        for _ in 0..<4 {
            usleep(10_000)
            guard send(&packet) else { continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            guard let read = DisplayPrivate.avRead,
                  read(service, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }
            // [source, length, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, checksum]
            guard Self.checksum(0x50, reply.dropLast()) == reply[10], reply[3] == 0, reply[4] == vcp.rawValue else { continue }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, max)
        }
        return nil
    }

    private func send(_ packet: inout [UInt8]) -> Bool {
        guard let write = DisplayPrivate.avWrite else { return false }
        return write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess
    }

    /// Length byte, opcode (0x01 get / 0x03 set — the same as the payload's length), payload, checksum.
    private static func packet(_ payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x80 | UInt8(payload.count + 1), UInt8(payload.count)] + payload
        p.append(checksum(payload.count == 1 ? 0x6E : 0x6E ^ 0x51, p[...]))
        return p
    }

    private static func checksum<C: Collection>(_ seed: UInt8, _ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(seed, ^)
    }
}

/// Finds each external monitor's AV service and pairs it with its CGDirectDisplayID.
enum DDCDiscovery {
    struct Found {
        let channel: DDCChannel
        let name: String?
        let vendor: UInt32?
        let product: UInt32?
        let serial: UInt32?
    }

    /// Walks the registry: a framebuffer node describes the display, and the external
    /// `DCPAVServiceProxy` that follows it is the way to talk to that display.
    static func scan() -> [Found] {
        guard let create = DisplayPrivate.avCreate else { return [] }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Found] = []
        var attributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                attributes = property(entry, "DisplayAttributes") as? [String: Any]
            } else if name == "DCPAVServiceProxy" {
                guard (property(entry, "Location") as? String) == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                let product = attributes?["ProductAttributes"] as? [String: Any]
                found.append(Found(
                    channel: DDCChannel(service: service),
                    name: product?["ProductName"] as? String,
                    vendor: (product?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                    product: (product?["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (product?["SerialNumber"] as? NSNumber)?.uint32Value))
                attributes = nil
            }
        }
        return found
    }

    /// Best pairing of services to displays: vendor, model, serial and name each count.
    static func match(_ found: [Found], to displays: [(id: CGDirectDisplayID, name: String)]) -> [CGDirectDisplayID: DDCChannel] {
        var pairs: [(score: Int, display: CGDirectDisplayID, index: Int)] = []
        for (i, f) in found.enumerated() {
            for d in displays {
                var score = 0
                if let v = f.vendor, v == CGDisplayVendorNumber(d.id) { score += 1 }
                if let p = f.product, p == CGDisplayModelNumber(d.id) { score += 2 }
                if let s = f.serial, s != 0, s == CGDisplaySerialNumber(d.id) { score += 4 }
                if let n = f.name, n == d.name { score += 2 }
                pairs.append((score, d.id, i))
            }
        }
        var result: [CGDirectDisplayID: DDCChannel] = [:]
        var used = Set<Int>()
        for p in pairs.sorted(by: { $0.score > $1.score }) where result[p.display] == nil && !used.contains(p.index) {
            // With one monitor and one service, even a zero score is the right pair.
            guard p.score > 0 || (found.count == 1 && displays.count == 1) else { continue }
            result[p.display] = found[p.index].channel
            used.insert(p.index)
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// The keyboard's backlight, through CoreBrightness's KeyboardBrightnessClient (what Control Center uses).
enum KeyboardBacklight {
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let client: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()

    private static let keyboard: UInt64? = {
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard let client, client.responds(to: sel),
              let ids = client.perform(sel)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return ids.first?.uint64Value
    }()

    static var available: Bool { keyboard != nil }

    static func level() -> Double? {
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let client, let keyboard, client.responds(to: sel), let imp = client.method(for: sel) else { return nil }
        return Double(unsafeBitCast(imp, to: Get.self)(client, sel, keyboard))
    }

    @discardableResult
    static func set(_ value: Double) -> Bool {
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard let client, let keyboard, client.responds(to: sel), let imp = client.method(for: sel) else { return false }
        return unsafeBitCast(imp, to: Set.self)(client, sel, Float(min(max(value, 0), 1)), keyboard)
    }
}
