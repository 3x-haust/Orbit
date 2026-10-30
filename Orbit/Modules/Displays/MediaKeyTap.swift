import AppKit
import CoreGraphics

/// The brightness and volume keys, for screens macOS can't brighten or turn up itself. Everything
/// Orbit doesn't take goes on to macOS untouched.
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()

    /// The tap lives on its own thread: on the main run loop every key press on the Mac waited for
    /// whatever the main thread was busy with.
    nonisolated(unsafe) private static var live: EventTapThread?
    /// Some keyboards send a brightness key both ways (a system event and a key code); count it once.
    private var lastKey: (DisplayManager.KeyAction, TimeInterval)?

    private init() {}

    var running: Bool { Self.live.map { CGEvent.tapIsEnabled(tap: $0.port) } ?? false }

    func start() {
        guard Self.live == nil, AXIsProcessTrusted() else { return }
        // NX_SYSDEFINED (14) carries the media keys; key codes 144/145 are brightness on newer keyboards.
        let mask = (CGEventMask(1) << 14) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            MediaKeyTap.callback(type: type, event: event)
        }, userInfo: nil) else {
            DisplaysLog.write("key tap: couldn't create (Accessibility?)")
            return
        }
        Self.live = EventTapThread(port: tap, name: "Orbit media keys")
        DisplaysLog.write("key tap: on")
    }

    func stop() {
        guard let live = Self.live else { return }
        live.stop()
        Self.live = nil
        DisplaysLog.write("key tap: off")
    }

    /// Runs on the tap's own thread. Everything that isn't a brightness, volume or keyboard-light key
    /// is passed on right here, without waiting for the main thread; only those keys hop over to it.
    private nonisolated static func callback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            live?.reenable()
            return pass
        }
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == 144 || code == 145 else { return pass }
        } else if type.rawValue == 14 {
            guard let code = mediaKey(event)?.code, [0, 1, 2, 3, 7, 21, 22, 23].contains(code) else { return pass }
        } else {
            return pass
        }
        nonisolated(unsafe) let e = event
        return DispatchQueue.main.sync { MainActor.assumeIsolated { shared.process(type: type, event: e) } }
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let flags = event.flags
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        var action: DisplayManager.KeyAction?
        var isDown = true

        if type == .keyDown {
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: action = .brightnessUp
            case 145: action = .brightnessDown
            default: return pass
            }
        } else if type.rawValue == 14 {
            guard let key = Self.mediaKey(event) else { return pass }
            isDown = key.down
            switch key.code {
            case 2: action = .brightnessUp
            case 3: action = .brightnessDown
            case 0: action = .volumeUp
            case 1: action = .volumeDown
            case 7: action = .mute
            case 21: action = .keyboardUp
            case 22: action = .keyboardDown
            case 23: action = .keyboardToggle
            default: return pass
            }
        } else {
            return pass
        }
        guard let action else { return pass }
        // Key-up of a key Orbit handled is Orbit's too, or macOS sees half a press.
        guard isDown else { return handledRecently(action) ? nil : pass }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastKey, last.0 == action, now - last.1 < 0.03 { return nil }
        guard DisplayManager.shared.handle(action, fine: fine) else { return pass }
        lastKey = (action, now)
        return nil
    }

    /// The media key in an NX_SYSDEFINED event, read off the CGEvent itself. `NSEvent(cgEvent:)` would
    /// do, but off the main thread it crashes Orbit: for Caps Lock (the 한/영 key) it asks the input
    /// sources, which only the main thread may. Fields 99 and 149 are the event's subtype and data1.
    private nonisolated static func mediaKey(_ event: CGEvent) -> (code: Int, down: Bool)? {
        guard let subtype = CGEventField(rawValue: 99), let data1Field = CGEventField(rawValue: 149),
              event.getIntegerValueField(subtype) == 8 else { return nil } // NX_SUBTYPE_AUX_CONTROL_BUTTONS
        let data1 = Int(event.getIntegerValueField(data1Field))
        return ((data1 & 0xFFFF_0000) >> 16, (data1 & 0xFF00) >> 8 == 0x0A)
    }

    private func handledRecently(_ action: DisplayManager.KeyAction) -> Bool {
        guard let last = lastKey, last.0 == action else { return false }
        return ProcessInfo.processInfo.systemUptime - last.1 < 2
    }
}
