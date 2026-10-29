import AppKit
import ApplicationServices
import Observation

/// Live permission state. Rechecked whenever Orbit becomes active, since prompts resolve asynchronously.
@MainActor @Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var screenCapture = false
    private(set) var accessibility = false
    private(set) var pasteboard: NSPasteboard.AccessBehavior = .default

    private var timer: Timer?

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
    }

    func refresh() {
        screenCapture = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
        pasteboard = NSPasteboard.general.accessBehavior
    }

    /// Polls briefly while a settings pane is open so the UI flips to "Granted" without relaunching.
    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
        timer?.tolerance = 0.3
    }

    func requestScreenCapture() {
        if !CGRequestScreenCaptureAccess() { open(.screenCapture) }
        refresh()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) { open(.accessibility) }
        refresh()
    }

    enum Pane: String {
        case screenCapture = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case pasteboard = "Privacy_Pasteboard"
    }

    func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
