import AppKit
import ApplicationServices

/// The frontmost app's menu bar, flattened into searchable commands (File › Export › PDF…).
/// Read when the launcher opens; the launcher panel doesn't activate Orbit, so the user's app stays in front.
@MainActor
final class MenuCommands {
    static let shared = MenuCommands()

    struct Command: @unchecked Sendable {
        let element: AXUIElement
        let title: String
        let path: [String]
        let shortcut: String?
    }

    private(set) var commands: [Command] = []
    private(set) var appName = ""
    private(set) var appPath: String?
    private var generation = 0

    func reload(for app: NSRunningApplication?) {
        commands = []
        generation += 1
        guard AXIsProcessTrusted(), let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        appName = app.localizedName ?? ""
        appPath = app.bundleURL?.path
        let gen = generation, pid = app.processIdentifier
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(pid)
            await MainActor.run {
                guard gen == MenuCommands.shared.generation else { return }
                MenuCommands.shared.commands = found
                SmartAnswers.notify()
            }
        }
    }

    func run(_ command: Command) {
        nonisolated(unsafe) let element = command.element
        // Pressing can block until the app returns from the action (a modal sheet, say); keep it off main.
        DispatchQueue.global(qos: .userInteractive).async { AXUIElementPerformAction(element, kAXPressAction as CFString) }
    }

    nonisolated private static func scan(_ pid: pid_t) -> [Command] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute),
              let tops: [AXUIElement] = attribute(bar, kAXChildrenAttribute) else { return [] }
        var out: [Command] = []
        // The Apple menu is the same in every app; the launcher already covers what's in it.
        for top in tops.dropFirst() {
            guard let title: String = attribute(top, kAXTitleAttribute), !title.isEmpty else { continue }
            walk(top, path: [title], depth: 0, into: &out)
        }
        return out
    }

    /// `element` is a menu bar item or a submenu item; its one child is the menu holding the items.
    nonisolated private static func walk(_ element: AXUIElement, path: [String], depth: Int, into out: inout [Command]) {
        guard depth < 4, out.count < 2000,
              let menu = (attribute(element, kAXChildrenAttribute) as [AXUIElement]?)?.first,
              let items: [AXUIElement] = attribute(menu, kAXChildrenAttribute) else { return }
        let names = [kAXTitleAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
                     kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute] as CFArray
        for item in items {
            // One round trip per item instead of five: big apps (Xcode, Office) have well over a thousand.
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [Any], v.count == 5,
                  let title = v[0] as? String, !title.isEmpty else { continue } // separators have no title
            if (v[1] as? Bool) == false { continue }
            if let children = v[2] as? [AXUIElement], !children.isEmpty {
                walk(item, path: path + [title], depth: depth + 1, into: &out)
                continue
            }
            out.append(Command(element: item, title: title, path: path, shortcut: shortcut(v[3] as? String, v[4] as? Int)))
        }
    }

    /// kAXMenuItemCmdModifiers: 1 = ⇧, 2 = ⌥, 4 = ⌃, 8 = no ⌘.
    nonisolated private static func shortcut(_ char: String?, _ modifiers: Int?) -> String? {
        // Arrows, Delete and friends come through as control or private-use characters; better none than a box.
        guard let char, !char.isEmpty, char.unicodeScalars.allSatisfy({
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .privateUse
        }) else { return nil }
        let m = modifiers ?? 0
        var label = ""
        if m & 4 != 0 { label += "⌃" }
        if m & 2 != 0 { label += "⌥" }
        if m & 1 != 0 { label += "⇧" }
        if m & 8 == 0 { label += "⌘" }
        return label + char
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
