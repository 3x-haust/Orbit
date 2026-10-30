import AppKit
import CoreGraphics

/// Press-and-hold a mouse button (middle by default) to open the Orbit Ring.
/// A quick click is replayed untouched, so middle-click-to-open-tab keeps working.
@MainActor
final class MouseTrigger {
    static let shared = MouseTrigger()

    static var enabled: Bool { Pref.defaults.object(forKey: "ring.mouse") as? Bool ?? true }
    /// CGMouseButton number: 2 = middle, 3/4 = side buttons.
    static var button: Int64 { Pref.defaults.object(forKey: "ring.mouseButton") as? Int64 ?? 2 }

    private static let holdDelay: TimeInterval = 0.18
    /// Marks clicks Orbit sends itself (a replayed quick click, a gesture's middle click), so this tap lets them through.
    nonisolated static let replayMarker: Int64 = 0x0B17

    /// On its own thread: every middle and side click on the Mac goes through it, and the ones that
    /// aren't the Ring button pass right there without waiting on the main thread.
    nonisolated(unsafe) private static var live: EventTapThread?
    nonisolated(unsafe) private static var watched: Int64 = 2
    private var pressed = false
    private var opened = false
    private var pressLocation: CGPoint = .zero
    private var holdWork: DispatchWorkItem?

    func start() {
        stop()
        guard Self.enabled, AXIsProcessTrusted() else { return }
        Self.watched = Self.button
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
            MouseTrigger.callback(type, event)
        }, userInfo: nil) else { return }
        Self.live = EventTapThread(port: tap, name: "Orbit ring mouse")
    }

    func stop() {
        Self.live?.stop()
        Self.live = nil
    }

    /// The Ring button's presses are always Orbit's — a quick click gets replayed — so the tap thread
    /// can swallow them without asking the main thread, which then decides what they were.
    private nonisolated static func callback(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            live?.reenable()
            return pass
        }
        guard type == .otherMouseDown || type == .otherMouseUp,
              event.getIntegerValueField(.eventSourceUserData) != replayMarker,
              event.getIntegerValueField(.mouseEventButtonNumber) == watched
        else { return pass }
        let down = type == .otherMouseDown
        let location = event.location
        DispatchQueue.main.async { MainActor.assumeIsolated { shared.handle(down: down, at: location) } }
        return nil
    }

    private func handle(down: Bool, at location: CGPoint) {
        if down {
            pressed = true
            opened = false
            pressLocation = location
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.pressed else { return }
                self.opened = true
                OrbitRing.shared.open(hold: true)
            }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
        } else {
            pressed = false
            holdWork?.cancel()
            if opened {
                OrbitRing.shared.release()
            } else {
                replayClick()
            }
        }
    }

    private func replayClick() {
        let src = CGEventSource(stateID: .hidSystemState)
        let button = CGMouseButton(rawValue: UInt32(Self.button)) ?? .center
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pressLocation, mouseButton: button) else { continue }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Self.button)
            e.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            e.post(tap: .cgSessionEventTap)
        }
    }
}
