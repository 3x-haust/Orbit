import AppKit
import Carbon.HIToolbox

/// Keyboard navigation for search-first panels. Intercepts navigation keys while the panel is key,
/// leaving ordinary typing to the focused search field.
@MainActor
final class KeyRouter {
    enum Key {
        case up, down, left, right, enter(shift: Bool, command: Bool), escape, tab(shift: Bool)
        case command(String), commandDelete, commandDigit(Int)
    }

    private var monitor: Any?

    func install(on window: NSWindow, handler: @escaping (Key) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard event.window === window, let key = Self.translate(event) else { return event }
            return handler(key) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func translate(_ e: NSEvent) -> Key? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_LeftArrow: return cmd ? nil : .left
        case kVK_RightArrow: return cmd ? nil : .right
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter(shift: flags.contains(.shift), command: cmd)
        case kVK_Escape: return .escape
        case kVK_Tab: return .tab(shift: flags.contains(.shift))
        case kVK_Delete where cmd: return .commandDelete
        default: break
        }
        guard cmd, let chars = e.charactersIgnoringModifiers?.lowercased() else { return nil }
        if let d = Int(chars), (1...9).contains(d) { return .commandDigit(d) }
        return .command(chars)
    }
}
