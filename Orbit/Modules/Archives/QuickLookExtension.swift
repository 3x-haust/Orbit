import AppKit

/// Orbit Preview, the Quick Look extension inside Orbit.app that lists archive and folder contents.
enum QuickLookExtension {
    static let identifier = "com.lyu.orbit.quicklook"

    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        ]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    /// pluginkit marks an extension the user turned off with "-".
    static func isEnabled() async -> Bool? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            p.arguments = ["-m", "-i", identifier]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard text.contains(identifier) else { return nil }
            return !text.trimmingCharacters(in: .whitespaces).hasPrefix("-")
        }.value
    }
}
