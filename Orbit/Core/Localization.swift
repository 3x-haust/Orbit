import Foundation

extension String {
    /// Looks a value up in Localizable.xcstrings at render time — for strings that reach the UI as values
    /// (model titles, toasts, component labels) rather than as SwiftUI literals. Unknown keys fall back to themselves.
    var loc: String { Bundle.main.localizedString(forKey: self, value: self, table: nil) }

    /// Localized format string, e.g. `"%ld items".loc(count)`.
    func loc(_ args: CVarArg...) -> String { String(format: loc, locale: .current, arguments: args) }
}

import AppKit

/// Per-app language override (System Settings › General › Language & Region › Applications does the same).
@MainActor
enum AppLanguage {
    /// "system", "en" or "ko" — what Orbit was launched with.
    static let current: String = {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return "system" }
        return first.hasPrefix("ko") ? "ko" : "en"
    }()

    static func set(_ code: String) {
        if code == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }

    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
