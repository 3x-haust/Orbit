import AppKit
import CoreGraphics

/// Key combos and double-tapped modifiers (⌘⌘, ⌥⌥, ⌃⌃, ⇧⇧). The tap is only installed while a
/// keyboard rule is on or one is being recorded. A key press is taken from the app only when it's a
/// rule's combo; everything else passes as typed, and nothing typed is kept or logged.
@MainActor
final class GestureKeys {
    static let shared = GestureKeys()

    nonisolated(unsafe) private static var live: EventTapThread?

    // Tap-thread state only.
    nonisolated(unsafe) private static var swallowed: Set<Int64> = []
    nonisolated(unsafe) private static var tapMod: GestureTrigger.Modifier?
    nonisolated(unsafe) private static var tapDown = 0.0
    nonisolated(unsafe) private static var tapUps = 0
    nonisolated(unsafe) private static var lastUp = 0.0

    private nonisolated static let tapMaxHold = 0.35
    private nonisolated static let tapMaxGap = 0.4

    /// F1–F20 work alone; any other key needs ⌃, ⌥ or ⌘ to be a combo.
    private nonisolated static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    func update(wanted: Bool) {
        if wanted, Self.live == nil, AXIsProcessTrusted() {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
                GestureKeys.callback(type, event)
            }, userInfo: nil) else { return }
            Self.live = EventTapThread(port: tap, name: "Orbit gesture keys")
            GestureLog.write("keyboard: listening")
        } else if !wanted, let live = Self.live {
            live.stop()
            Self.live = nil
            GestureLog.write("keyboard: stopped")
        }
    }

    private nonisolated static func callback(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            live?.reenable()
            return pass
        case .flagsChanged:
            modifierChanged(event)
            return pass
        case .keyDown, .keyUp:
            break
        default:
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != GestureAction.sentMarker else { return pass }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowed.remove(code) != nil ? nil : pass }

        tapUps = 0 // typing between two taps of a modifier isn't a double tap
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return swallowed.contains(code) ? nil : pass }
        let mods = KeyMods(event.flags)
        if Gestures.table.isRecording == .keyboard, mods.isEmpty, code == 53 { // esc stops recording
            swallowed.insert(code)
            DispatchQueue.main.async { MainActor.assumeIsolated { Gestures.shared.record(nil) } }
            return nil
        }
        guard !mods.subtracting(.shift).isEmpty || functionKeys.contains(code) else { return pass }
        let trigger = GestureTrigger.keys(KeyCombo(keyCode: UInt16(code), mods: mods))
        guard let match = Gestures.table.match(trigger) else { return pass }
        swallowed.insert(code)
        DispatchQueue.main.async { MainActor.assumeIsolated { Gestures.shared.handle(trigger, match) } }
        return nil
    }

    /// A modifier pressed and let go quickly, alone, twice in a row.
    private nonisolated static func modifierChanged(_ event: CGEvent) {
        guard Gestures.table.wantsDoubleTap() else { return }
        let mod: GestureTrigger.Modifier
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 55, 54: mod = .command
        case 58, 61: mod = .option
        case 59, 62: mod = .control
        case 56, 60: mod = .shift
        default: tapUps = 0; return
        }
        let held = KeyMods(event.flags)
        let flag: KeyMods = switch mod {
        case .command: .command
        case .option: .option
        case .control: .control
        case .shift: .shift
        }
        let now = ProcessInfo.processInfo.systemUptime
        if held.contains(flag) {
            // Pressed: alone, or it's a chord and not a tap.
            guard held == flag else { tapUps = 0; tapMod = nil; return }
            if tapMod != mod || now - lastUp > tapMaxGap { tapUps = 0 }
            tapMod = mod
            tapDown = now
            return
        }
        // Let go.
        guard tapMod == mod, held.isEmpty, now - tapDown <= tapMaxHold else { tapUps = 0; tapMod = nil; return }
        tapUps += 1
        lastUp = now
        guard tapUps >= 2 else { return }
        tapUps = 0
        tapMod = nil
        let trigger = GestureTrigger.doubleTap(mod)
        guard let match = Gestures.table.match(trigger) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { Gestures.shared.handle(trigger, match) } }
    }
}
