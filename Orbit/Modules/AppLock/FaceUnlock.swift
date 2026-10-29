import AppKit

extension Pref {
    /// FaceStore.Strictness raw value.
    static let appLockStrictness = "applock.strictness"
    /// Also require a blink, so a photo can't unlock.
    static let appLockLiveness = "applock.liveness"
    /// Camera picture in the notch HUD; off shows the small face glyph instead.
    static let appLockPreview = "applock.preview"
    /// AVCaptureDevice uniqueID; empty for the built-in camera.
    static let appLockCamera = "applock.camera"
    /// Look once more after a miss.
    static let appLockAutoRetry = "applock.autoRetry"
}

/// Your face in place of your password: at the lock screen (MacUnlock) and in macOS's own
/// password and Touch ID prompts (AuthPromptUnlock). Per-app locking is gone; this tidies up after it.
@MainActor
enum FaceUnlock {
    static func start() {
        migrateFromAppLock()
    }

    static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Older builds locked apps (some even hid them). Bring those back and forget the settings,
    /// including hot corners and ring slots that pointed at "Lock Apps".
    private static func migrateFromAppLock() {
        let d = Pref.defaults
        let done = "faceunlock.migrated"
        guard !d.bool(forKey: done) else { return }
        d.set(true, forKey: done)

        let locked = Set(d.stringArray(forKey: "applock.apps") ?? [])
        var unhidden = 0
        for app in NSWorkspace.shared.runningApplications where app.isHidden && locked.contains(app.bundleIdentifier ?? "") {
            app.unhide()
            unhidden += 1
        }
        for key in ["applock.enabled", "applock.apps", "applock.duration", "applock.hideInExpose"] {
            d.removeObject(forKey: key)
        }
        for corner in ["tl", "tr", "bl", "br"] where d.string(forKey: "corners.\(corner)") == "cmd.lockApps" {
            d.removeObject(forKey: "corners.\(corner)")
        }
        for key in ["ring.slots", "ring.custom"] {
            if let slots = d.stringArray(forKey: key), slots.contains("lockApps") {
                d.set(slots.filter { $0 != "lockApps" }, forKey: key)
            }
        }
        // Saved ring presets decode as a whole; one unknown action would drop them all.
        if let data = d.data(forKey: "ring.userPresets"),
           var presets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for i in presets.indices {
                if let slots = presets[i]["slots"] as? [String] { presets[i]["slots"] = slots.filter { $0 != "lockApps" } }
            }
            if let fixed = try? JSONSerialization.data(withJSONObject: presets) { d.set(fixed, forKey: "ring.userPresets") }
        }
        AppLockLog.write("migrated from App Lock: \(locked.count) locked app(s) forgotten, \(unhidden) unhidden")
    }
}

/// ~/Library/Logs/Orbit/applock.log — face checks, the lock screen and password prompts.
enum AppLockLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("applock.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
