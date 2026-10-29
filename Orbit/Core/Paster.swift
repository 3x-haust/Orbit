import AppKit
import Carbon.HIToolbox

/// Sends ⌘V to the app the user was in. Requires Accessibility; falls back to copy-only and says so.
@MainActor
enum Paster {
    /// The last app other than Orbit to be frontmost: where a paste from Orbit's panels belongs.
    private(set) static var lastExternal: NSRunningApplication?
    private static var observer: Any?

    /// Starts following the frontmost app. Called at launch; harmless to call again.
    static func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication, !isOrbit(front) { lastExternal = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { if !isOrbit(app) { lastExternal = app } }
        }
    }

    /// Pastes into `target` (default: the app the user was last in).
    ///
    /// Orbit's panels don't activate Orbit, but a key panel still receives the keyboard — a ⌘V sent
    /// while the panel is fading out lands in the panel, not the app. So: wait until the target app
    /// is frontmost and no Orbit window holds the keyboard, then send it.
    @discardableResult
    static func paste(into target: NSRunningApplication? = nil) -> Bool {
        start()
        guard AXIsProcessTrusted() else {
            Toast.show("Copied", symbol: "doc.on.doc.fill", detail: "Allow Accessibility to paste directly")
            return false
        }
        let app = target ?? lastExternal
        // Give the keyboard back: close any key Orbit panel now rather than after its fade.
        if let key = NSApp.keyWindow, key is NSPanel { key.orderOut(nil) }
        if let app, !app.isTerminated, NSWorkspace.shared.frontmostApplication != app {
            if NSApp.isActive { NSApp.yieldActivation(to: app) }
            app.activate()
        }
        Task { @MainActor in
            for _ in 0..<30 {
                let front = NSWorkspace.shared.frontmostApplication
                if (app == nil || front == app || front.map(isOrbit) == false), NSApp.keyWindow == nil { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            // A beat for the field to become first responder again.
            try? await Task.sleep(for: .milliseconds(40))
            send()
        }
        return true
    }

    /// ⌘V now, to whatever has the keyboard (the caller has made sure it's the right app).
    static func sendPaste() { send() }

    private static func send() {
        let src = CGEventSource(stateID: .hidSystemState)
        let v = CGKeyCode(kVK_ANSI_V), cmd = CGKeyCode(kVK_Command)
        let events: [(CGKeyCode, Bool)] = [(cmd, true), (v, true), (v, false), (cmd, false)]
        for (key, down) in events {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = (key == cmd && !down) ? [] : .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func isOrbit(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
