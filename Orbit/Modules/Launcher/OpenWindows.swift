import AppKit
import ApplicationServices

/// Windows open right now, read through Accessibility each time the launcher opens.
/// AX only reports the current Space's windows (plus minimized ones), like an app's Window menu.
@MainActor
final class OpenWindows {
    static let shared = OpenWindows()

    struct Window: @unchecked Sendable {
        let element: AXUIElement
        let title: String
        let appName: String
        let appPath: String?
        let pid: pid_t
        let minimized: Bool
    }

    private struct Source: Sendable {
        let pid: pid_t
        let name: String
        let path: String?
    }

    private(set) var windows: [Window] = []
    private var generation = 0

    func reload() {
        windows = []
        generation += 1
        guard AXIsProcessTrusted() else { return }
        let gen = generation
        let own = ProcessInfo.processInfo.processIdentifier
        let sources = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .map { Source(pid: $0.processIdentifier, name: $0.localizedName ?? "", path: $0.bundleURL?.path) }
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(sources)
            await MainActor.run {
                guard gen == OpenWindows.shared.generation else { return }
                OpenWindows.shared.windows = found
                SmartAnswers.notify()
            }
        }
    }

    func focus(_ w: Window) {
        if w.minimized { AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate()
    }

    func close(_ w: Window) {
        guard let button: AXUIElement = Self.attribute(w.element, kAXCloseButtonAttribute) else { NSSound.beep(); return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    // One app at a time would let a single hung app hold up the rest; each gets its own short timeout.
    nonisolated private static func scan(_ sources: [Source]) -> [Window] {
        var perApp = [[Window]](repeating: [], count: sources.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            let found = windows(of: sources[i])
            lock.lock(); perApp[i] = found; lock.unlock()
        }
        return perApp.flatMap { $0 }
    }

    nonisolated private static func windows(of source: Source) -> [Window] {
        let app = AXUIElementCreateApplication(source.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let list: [AXUIElement] = attribute(app, kAXWindowsAttribute) ?? []
        return list.compactMap { element in
            // Standard windows only: no palettes, sheets or the invisible helpers some apps keep around.
            guard (attribute(element, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole else { return nil }
            let title = (attribute(element, kAXTitleAttribute) as String?) ?? ""
            return Window(element: element, title: title.isEmpty ? source.name : title, appName: source.name,
                          appPath: source.path, pid: source.pid, minimized: (attribute(element, kAXMinimizedAttribute) as Bool?) ?? false)
        }
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
