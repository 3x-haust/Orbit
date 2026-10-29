import AppKit

/// Explains a permission in terms of the feature the user just tried, then hands off to macOS.
@MainActor
enum PermissionPrompt {
    enum Kind { case screenCapture, accessibility }

    private static var showing = false

    static func show(_ kind: Kind) {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        let alert = NSAlert()
        alert.icon = Brand.logo
        switch kind {
        case .screenCapture:
            alert.messageText = "Orbit needs screen access to capture".loc
            alert.informativeText = "macOS calls this “Screen & System Audio Recording”. Orbit only reads the screen when you take a screenshot or grab text — nothing is recorded or uploaded.\n\nAfter allowing, macOS may ask you to reopen Orbit.".loc
        case .accessibility:
            alert.messageText = "Orbit needs Accessibility for this".loc
            alert.informativeText = "Accessibility lets Orbit move and resize windows, paste into the app you were using, and open the Ring with your mouse. Orbit never reads what you type.".loc
        }
        alert.addButton(withTitle: "Continue".loc)
        alert.addButton(withTitle: "Not Now".loc)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch kind {
        case .screenCapture: Permissions.shared.requestScreenCapture()
        case .accessibility: Permissions.shared.requestAccessibility()
        }
    }
}
