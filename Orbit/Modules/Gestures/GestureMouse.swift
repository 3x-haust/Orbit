import AppKit
import CoreGraphics

/// The extra mouse buttons (the fourth and up), alone or with modifiers. A press is only taken away
/// from the app under the pointer when a rule wants it; every other click passes untouched. The
/// middle button stays the Ring's (see ``MouseTrigger``).
@MainActor
final class GestureMouse {
    static let shared = GestureMouse()

    nonisolated(unsafe) private static var live: EventTapThread?
    /// The Ring's button, if it's a side button: those presses are the Ring's, not a rule's.
    nonisolated(unsafe) private static var ringButton: Int64 = -1
    /// Buttons whose press was Orbit's, so their release is swallowed too. Only touched on the tap thread.
    nonisolated(unsafe) private static var held: Set<Int64> = []

    func update(wanted: Bool) {
        Self.ringButton = MouseTrigger.enabled ? MouseTrigger.button : -1
        if wanted, Self.live == nil, AXIsProcessTrusted() {
            let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
                GestureMouse.callback(type, event)
            }, userInfo: nil) else { return }
            Self.live = EventTapThread(port: tap, name: "Orbit gesture mouse")
            GestureLog.write("mouse: listening")
        } else if !wanted, let live = Self.live {
            live.stop()
            Self.live = nil
            GestureLog.write("mouse: stopped")
        }
    }

    private nonisolated static func callback(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            live?.reenable()
            return pass
        }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard type == .otherMouseDown || type == .otherMouseUp,
              marker != MouseTrigger.replayMarker, marker != GestureAction.sentMarker,
              button >= 3, button != ringButton else { return pass }
        if type == .otherMouseUp {
            return held.remove(button) != nil ? nil : pass
        }
        let trigger = GestureTrigger.mouse(button: Int(button), mods: KeyMods(event.flags))
        guard let match = Gestures.table.match(trigger) else { return pass }
        held.insert(button)
        DispatchQueue.main.async { MainActor.assumeIsolated { Gestures.shared.handle(trigger, match) } }
        return nil
    }
}
