import AppKit

/// One-shot Mac utilities: lock, display sleep, appearance, Finder toggles, trash, eject, color picker, timed capture.
@MainActor
enum SystemActions {
    static func lockScreen() {
        typealias Lock = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(symbol, to: Lock.self)()
            return
        }
        // Fallback: the system ⌃⌘Q shortcut (needs Accessibility).
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 12, keyDown: down)
            e?.flags = [.maskCommand, .maskControl]
            e?.post(tap: .cghidEventTap)
        }
    }

    static func sleepDisplay() {
        Task { await Shell.runAsync("/usr/bin/pmset", ["displaysleepnow"]) }
    }

    static func toggleDarkMode() {
        Task {
            let ok = await Shell.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            if !ok { Toast.show("Allow Orbit to control System Events", symbol: "hand.raised.fill", detail: "System Settings › Privacy › Automation") }
        }
    }

    static func toggleDesktopIcons() {
        Task {
            let current = await Shell.runAsync("/usr/bin/defaults", ["read", "com.apple.finder", "CreateDesktop"]).output
            let hidden = current.trimmingCharacters(in: .whitespacesAndNewlines) == "0" || current.contains("false")
            await Shell.runAsync("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "true" : "false"])
            await Shell.runAsync("/usr/bin/killall", ["Finder"])
            Toast.show(hidden ? "Desktop icons shown" : "Desktop icons hidden", symbol: hidden ? "eye" : "eye.slash")
        }
    }

    static func toggleHiddenFiles() {
        Task {
            let current = await Shell.runAsync("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"]).output
            let showing = current.trimmingCharacters(in: .whitespacesAndNewlines) == "1" || current.contains("true")
            await Shell.runAsync("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", showing ? "false" : "true"])
            await Shell.runAsync("/usr/bin/killall", ["Finder"])
            Toast.show(showing ? "Hidden files hidden" : "Hidden files shown", symbol: showing ? "eye.slash" : "eye")
        }
    }

    static func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?".loc
        alert.informativeText = "Items in the Trash will be deleted permanently. This can’t be undone.".loc
        alert.addButton(withTitle: "Empty Trash".loc)
        alert.addButton(withTitle: "Cancel".loc)
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let ok = await Shell.appleScript("tell application \"Finder\" to empty trash")
            Toast.show(ok ? "Trash emptied" : "Allow Orbit to control Finder", symbol: ok ? "trash.fill" : "hand.raised.fill",
                       detail: ok ? nil : "System Settings › Privacy › Automation")
        }
    }

    static func ejectAll() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (v?.volumeIsEjectable ?? false || v?.volumeIsRemovable ?? false) && !(v?.volumeIsInternal ?? false) && url.path != "/"
            }
        guard !volumes.isEmpty else { Toast.show("Nothing to eject", symbol: "eject"); return }
        var failed = 0
        for url in volumes {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { failed += 1 }
        }
        let done = volumes.count - failed
        Toast.show(failed == 0 ? (done == 1 ? "Ejected 1 disk".loc : "Ejected %ld disks".loc(done)) : (failed == 1 ? "1 disk is in use".loc : "%ld disks are in use".loc(failed)),
                   symbol: failed == 0 ? "eject.fill" : "exclamationmark.triangle.fill")
    }

    private static var sampler: NSColorSampler?

    /// System color sampler with a magnifier; copies the hex value (recorded as a color in clipboard history).
    static func pickColor() {
        // Held until it answers: a sampler freed mid-pick leaves its full-screen magnifier behind,
        // eating every click, and a second one opened over the first can do the same.
        guard sampler == nil else { return }
        let picker = NSColorSampler()
        sampler = picker
        picker.show { color in
            DispatchQueue.main.async { sampler = nil }
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                Toast.show("%@ copied".loc(hex), symbol: "eyedropper.full",
                           detail: "rgb(\(Int(round(c.redComponent * 255))), \(Int(round(c.greenComponent * 255))), \(Int(round(c.blueComponent * 255))))")
            }
        }
    }

    /// Counts down so menus and hover states can be opened, then starts an area capture.
    static func timedCapture() {
        let seconds = max(1, Pref.defaults.integer(forKey: Pref.timedCaptureSeconds))
        for i in 0..<seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(i)) {
                Toast.show("Capturing in %ld…".loc(seconds - i), symbol: "timer", detail: i == 0 ? "Open the menu or hover you want to capture" : nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            Toast.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { CaptureService.shared.start(.area) }
        }
    }
}
