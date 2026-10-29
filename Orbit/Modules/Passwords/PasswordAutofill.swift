import AppKit
import ApplicationServices

/// Fills a login into whatever app was in front, the way 1Password's Universal Autofill does without a
/// browser extension: find the username and password fields through Accessibility, then type into them.
///
/// Safety: it only ever types into the app that was in front when Quick Access opened, checked again
/// right before each field; and in a browser it checks the page's address against the login's.
@MainActor
enum PasswordAutofill {
    struct Target {
        let app: NSRunningApplication
        /// The page in front, for browsers.
        let pageURL: String?
        var host: String? { pageURL.map(VaultItem.host).flatMap { $0.isEmpty ? nil : $0 } }
    }

    enum Outcome: Equatable {
        case filled
        case noFields
        case appChanged
        case noAccess
    }

    /// Snippets ignores events carrying this, so typed passwords never land in its buffer.
    private static let marker: Int64 = 0x0B17_5E1F

    static func target(for app: NSRunningApplication?) -> Target? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return Target(app: app, pageURL: AXIsProcessTrusted() ? pageURL(app) : nil)
    }

    // MARK: Reading the page

    /// The address of the web page in the front window: the web area's AXURL, which Safari, Chrome,
    /// Arc, Edge and Brave all expose.
    static func pageURL(_ app: NSRunningApplication) -> String? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        // Chromium only builds its web accessibility tree when asked.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = attribute(root, kAXFocusedWindowAttribute) else { return nil }
        var queue: [AXUIElement] = [window]
        var seen = 0
        while !queue.isEmpty, seen < 3000 {
            let e = queue.removeFirst()
            seen += 1
            if (attribute(e, kAXRoleAttribute) as String?) == "AXWebArea" {
                if let url: URL = attribute(e, "AXURL") { return url.absoluteString }
                if let url: String = attribute(e, "AXURL") { return url }
            }
            queue.append(contentsOf: (attribute(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
        }
        return nil
    }

    // MARK: Filling

    static func fill(_ item: VaultItem, into target: Target, submit: Bool) async -> Outcome {
        guard AXIsProcessTrusted() else { return .noAccess }
        let pid = target.app.processIdentifier
        target.app.activate()
        try? await Task.sleep(for: .milliseconds(180))
        guard frontmost(pid) else { return .appChanged }

        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        let focused: AXUIElement? = attribute(root, kAXFocusedUIElementAttribute)
        guard let window: AXUIElement = attribute(root, kAXFocusedWindowAttribute) else { return .noFields }
        let fields = textFields(in: window)
        let (user, pass) = pick(fields, focused: focused)
        guard user != nil || pass != nil else { return .noFields }

        if let user, !item.username.isEmpty {
            guard frontmost(pid) else { return .appChanged }
            await type(item.username, into: user)
        }
        if let pass, !item.password.isEmpty {
            guard frontmost(pid) else { return .appChanged }
            await type(item.password, into: pass)
            if submit, frontmost(pid) { key(36) }
        }
        return .filled
    }

    /// The password field, and the text field just before it (the username, nearly always).
    private static func pick(_ fields: [(AXUIElement, Bool)], focused: AXUIElement?) -> (AXUIElement?, AXUIElement?) {
        let focusIndex = focused.flatMap { f in fields.firstIndex { CFEqual($0.0, f) } }
        if let i = focusIndex {
            if fields[i].1 {
                return (fields[..<i].last { !$0.1 }?.0, fields[i].0)
            }
            return (fields[i].0, fields[(i + 1)...].first { $0.1 }?.0)
        }
        guard let p = fields.firstIndex(where: { $0.1 }) else {
            // No password field on screen (a username-first page): the first text field.
            return (fields.first?.0, nil)
        }
        return (fields[..<p].last { !$0.1 }?.0, fields[p].0)
    }

    /// Text and password fields in document order; `true` marks a password field.
    private static func textFields(in window: AXUIElement) -> [(AXUIElement, Bool)] {
        var out: [(AXUIElement, Bool)] = []
        var seen = 0
        func walk(_ e: AXUIElement, depth: Int) {
            guard seen < 4000, depth < 40 else { return }
            seen += 1
            let role: String? = attribute(e, kAXRoleAttribute)
            let subrole: String? = attribute(e, kAXSubroleAttribute)
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
                out.append((e, true))
            } else if role == kAXTextFieldRole as String, subrole != "AXSearchField", (attribute(e, kAXEnabledAttribute) as Bool?) != false {
                out.append((e, false))
            }
            for c in (attribute(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return out
    }

    private static func type(_ text: String, into field: AXUIElement) async {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(80))
        // Replace whatever is there.
        key(0, flags: .maskCommand) // ⌘A
        try? await Task.sleep(for: .milliseconds(30))
        let source = CGEventSource(stateID: .hidSystemState)
        var units = Array(text.utf16)
        defer { units.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        var i = 0
        while i < units.count {
            let n = min(16, units.count - i)
            var chunk = Array(units[i..<i + n])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: n, unicodeString: &chunk)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cghidEventTap)
            }
            chunk.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
            i += n
            try? await Task.sleep(for: .milliseconds(8))
        }
        try? await Task.sleep(for: .milliseconds(40))
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.setIntegerValueField(.eventSourceUserData, value: marker)
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func frontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func attribute<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}
