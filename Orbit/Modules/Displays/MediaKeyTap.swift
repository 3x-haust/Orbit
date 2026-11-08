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
    /// Keys whose press Orbit kept from macOS. Only their release is Orbit's too: a release kept
    /// back after macOS saw the press leaves the key held down, and macOS repeats it forever.
    private var keptDown: Set<DisplayManager.KeyAction> = []
    /// How long a key waits for the main thread before going to macOS instead. Waiting longer lets
    /// macOS switch the tap off, and the press reaches macOS anyway.
    private nonisolated static let patience: TimeInterval = 0.25
    private var wakeObserver: NSObjectProtocol?

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
        // A key pressed as the screen sleeps or wakes may never reach the tap; forget what was held.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                                              object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MediaKeyTap.shared.keptDown.removeAll() }
            }
        }
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
            // Whatever was pressed meanwhile went to macOS, so its release must too.
            DispatchQueue.main.async { MainActor.assumeIsolated { shared.keptDown.removeAll() } }
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
        // Waking from sleep, the main thread can be busy for a second or more. Rather than hold
        // every key that long, a key the main thread doesn't take up in time goes on to macOS.
        let job = KeyJob()
        nonisolated(unsafe) let e = event
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard job.start() else { return }
                job.finish(kept: shared.process(type: type, event: e) == nil)
            }
        }
        guard let kept = job.wait(patience) else {
            // macOS gets this one, so a release Orbit was waiting for is macOS's now too.
            DispatchQueue.main.async { MainActor.assumeIsolated { shared.keptDown.removeAll() } }
            return pass
        }
        return kept ? nil : pass
    }

    /// One key handed to the main thread: either it runs there, or the tap gave up on it first.
    private final class KeyJob: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var started = false, abandoned = false, kept = false

        func start() -> Bool {
            lock.withLock {
                if abandoned { return false }
                started = true
                return true
            }
        }

        func finish(kept: Bool) {
            lock.withLock { self.kept = kept }
            done.signal()
        }

        /// The main thread's answer, or nil when it hadn't begun in time; then it never will.
        func wait(_ seconds: TimeInterval) -> Bool? {
            if done.wait(timeout: .now() + seconds) == .timedOut {
                let begun = lock.withLock {
                    if !started { abandoned = true }
                    return started
                }
                guard begun else { return nil }
                done.wait() // already running; it's quick
            }
            return lock.withLock { kept }
        }
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
        guard isDown else {
            let kept = keptDown.remove(action) != nil
            // A brightness key's release always reaches macOS: on its own it changes nothing, and it
            // ends a press macOS saw without Orbit, as when the key wakes the screen. Kept back, macOS
            // holds that key down for good, raising the brightness and showing its banner over and over.
            if action == .brightnessUp || action == .brightnessDown { return pass }
            // Any other key Orbit kept is Orbit's to release, or macOS sees half a press.
            return kept ? nil : pass
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastKey, last.0 == action, now - last.1 < 0.03 {
            keptDown.insert(action)
            return nil
        }
        guard DisplayManager.shared.handle(action, fine: fine) else {
            keptDown.remove(action)
            return pass
        }
        lastKey = (action, now)
        // The key code form (144/145) has no key-up here; only the system event's release is waited for.
        if type.rawValue == 14 { keptDown.insert(action) }
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
}
