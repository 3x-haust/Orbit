import AppKit
import ApplicationServices
import Security

extension Pref {
    /// Approve macOS's own password / Touch ID prompts with your face.
    static let authPromptFace = "macunlock.authPrompts"
}

/// When macOS asks for your password or Touch ID — an admin dialog from SecurityAgent, or the
/// "Touch ID or enter your password" sheet drawn by LocalAuthentication's UI agent — Orbit checks
/// your face in the notch and, on a match, fills the password in that dialog and confirms it.
///
/// It only ever touches those two Apple processes, verified by their code signature right before
/// anything is filled in; one face check per prompt, and a miss or cancel leaves the prompt as it
/// was for Touch ID or typing. Uses the login password Mac unlock keeps in the Keychain.
@MainActor @Observable
final class AuthPromptUnlock {
    static let shared = AuthPromptUnlock()

    private(set) var enabled = Pref.defaults.bool(forKey: Pref.authPromptFace)

    /// Process names in the window list, and the code identities they must have.
    nonisolated private static let owners: Set<String> = ["SecurityAgent", "coreautha"]
    private static let requirement = "anchor apple and (identifier \"com.apple.SecurityAgent\" or identifier \"com.apple.LocalAuthentication.UIAgent\")"

    private struct Prompt: Sendable {
        let pid: pid_t
        let window: CGWindowID
        let bounds: CGRect
    }

    @ObservationIgnored private var timer: Timer?
    /// Prompt windows already handled (or skipped) while they're on screen: one try per appearance.
    @ObservationIgnored private var tried: Set<CGWindowID> = []
    @ObservationIgnored private var matcher: FaceMatcher?
    @ObservationIgnored private var current: Prompt?

    var ready: Bool { enabled && MacUnlock.shared.hasPassword && FaceStore.isEnrolled && AXIsProcessTrusted() }

    func setEnabled(_ on: Bool) {
        enabled = on
        Pref.defaults.set(on, forKey: Pref.authPromptFace)
        start()
    }

    func start() {
        timer?.invalidate()
        timer = nil
        guard enabled else { end(); return }
        // Prompts take focus when they appear, so an app switch looks right away; the slow poll
        // only catches sheets that don't.
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard AuthPromptUnlock.shared.timer != nil else { return }
                    AuthPromptUnlock.shared.look()
                }
            }
        }
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { AuthPromptUnlock.shared.look() } }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    // MARK: Finding prompts

    @ObservationIgnored private var looking = false
    private static let lookQueue = DispatchQueue(label: "com.lyu.orbit.auth-prompts", qos: .utility)

    /// The window list and session lookups run off the main thread: with LocalAuthentication's
    /// agent kept running they ran every second, and each was a hitch in whatever Orbit animated.
    private func look() {
        guard !looking, ready else { return }
        looking = true
        let watching = current != nil
        Self.lookQueue.async {
            let windows = Self.promptWindows(watching: watching)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = AuthPromptUnlock.shared
                    me.looking = false
                    if let windows, me.ready { me.consider(windows) }
                }
            }
        }
    }

    /// Prompt windows on screen now; nil when there's nothing to look at.
    nonisolated private static func promptWindows(watching: Bool) -> [Prompt]? {
        // Nothing to look at unless one of the prompt processes is running (they start on demand);
        // checking names is a fraction of what the window list and session lookups cost.
        guard watching || promptProcessRunning() else { return nil }
        guard !screenLocked,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String, owners.contains(owner),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.width > 160, bounds.height > 80 else { return nil }
            return Prompt(pid: pid, window: id, bounds: bounds)
        }
    }

    private func consider(_ windows: [Prompt]) {
        let live = Set(windows.map(\.window))
        let next = windows.first { !tried.contains($0.window) }
        tried.formIntersection(live)
        // The prompt went away (Touch ID used, typed, cancelled): stop looking.
        if let c = current, !live.contains(c.window) {
            AppLockLog.write("auth prompt closed before a match")
            end()
            NotchHUD.shared.collapse()
        }
        guard current == nil, let prompt = next else { return }
        // The notch is busy with an app unlock; come back to this prompt next tick.
        guard !NotchHUD.shared.isShowing else { return }
        tried.insert(prompt.window)
        guard Self.isApple(prompt.pid) else {
            AppLockLog.write("auth prompt: pid \(prompt.pid) isn't Apple's SecurityAgent or LocalAuthentication UI; ignoring")
            return
        }
        guard let window = Self.axWindow(prompt), Self.secureField(in: window) != nil || Self.passwordButton(in: window) != nil else {
            AppLockLog.write("auth prompt: no password field in window \(prompt.window); ignoring")
            return
        }
        if let user = Self.userField(in: window), !Self.isCurrentUser(user) {
            AppLockLog.write("auth prompt asks for another account; leaving it alone")
            return
        }
        begin(prompt)
    }

    // MARK: Face check

    private func begin(_ prompt: Prompt) {
        current = prompt
        AppLockLog.write("auth prompt from pid \(prompt.pid): checking face")
        let hud = NotchHUD.shared
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        hud.show(on: screen, label: "Approve with your face".loc, compact: true)
        let m = FaceMatcher { event in AuthPromptUnlock.shared.handle(event) }
        guard m.start(timeout: 6) else {
            current = nil
            hud.failed(label: "Couldn’t start the camera".loc, buttons: false)
            hud.collapse(after: 1.2)
            return
        }
        matcher = m
        hud.model.session = m.session
    }

    private func handle(_ event: FaceMatcher.Event) {
        guard let prompt = current else { return }
        let hud = NotchHUD.shared
        switch event {
        case .progress(let p): hud.setProgress(p)
        case .noFace: hud.setProgress(0)
        case .blink: hud.setLabel("Blink once".loc)
        case .tooFar: break
        case .matched:
            matcher = nil
            current = nil
            if fill(prompt) {
                hud.matched(label: "Approved with your face".loc)
            } else {
                hud.failed(label: "Use Touch ID or your password".loc, buttons: false)
                hud.collapse(after: 1.4)
            }
        case .failed:
            matcher = nil
            current = nil
            hud.failed(label: "Face not recognized".loc, buttons: false)
            hud.collapse(after: 1.2)
        }
    }

    private func end() {
        matcher?.stop()
        matcher = nil
        current = nil
    }

    // MARK: Filling in

    /// Puts the password in the prompt's field and presses its default button. False if anything
    /// about the prompt doesn't check out; then nothing is typed.
    private func fill(_ prompt: Prompt) -> Bool {
        // Check the process again now: a pid can be reused in the seconds the face check took.
        guard Self.isApple(prompt.pid), let window = Self.axWindow(prompt) else { return false }
        var field = Self.secureField(in: window)
        if field == nil, let button = Self.passwordButton(in: window) {
            // The Touch ID sheet: switch it to its password field first.
            let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            AppLockLog.write("auth prompt: Touch ID sheet, pressed “Use Password…” (\(pressed ? "ok" : "failed"))")
            for _ in 0..<10 where field == nil {
                Thread.sleep(forTimeInterval: 0.08)
                field = Self.axWindow(prompt).flatMap(Self.secureField)
            }
        }
        guard let field, var bytes = MacUnlock.shared.passwordBytes() else {
            AppLockLog.write("auth prompt: no password field to fill")
            return false
        }
        defer { for i in bytes.indices { bytes[i] = 0 } }
        let count = String(decoding: bytes, as: UTF8.self).count
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var filled = false
        if let value = CFStringCreateWithBytes(nil, bytes, bytes.count, CFStringBuiltInEncodings.UTF8.rawValue, false) {
            filled = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value) == .success
                && (Self.attribute(field, kAXNumberOfCharactersAttribute) as Int?).map { $0 == count } ?? true
        }
        if !filled {
            // Accessibility wouldn't set it; type it, but only into this very field while it has focus.
            guard Self.focused(field) else {
                AppLockLog.write("auth prompt: password field isn't focused; not typing")
                return false
            }
            Self.type(bytes)
        }
        AppLockLog.write("auth prompt: filled (\(filled ? "accessibility" : "keys")), submitting")
        DispatchQueue.main.asyncAfter(deadline: .now() + (filled ? 0.1 : 0.15 + Double(count) * 0.012)) {
            Self.submit(prompt, window: window, field: field)
        }
        return true
    }

    /// Typing isn't enough — the prompt has to go through too: its default button, a known
    /// OK/Unlock/Allow button, or Return in the password field. If the prompt is still up with the
    /// password in it a moment later, Return once more.
    private static func submit(_ prompt: Prompt, window: AXUIElement, field: AXUIElement, retry: Bool = true) {
        guard isApple(prompt.pid) else { AppLockLog.write("auth prompt: process changed before submitting; stopped"); return }
        if let button = attribute(window, kAXDefaultButtonAttribute) as AXUIElement?,
           AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            AppLockLog.write("auth prompt: submitted with the default button")
        } else if let button = find(in: window, where: { e in
            (attribute(e, kAXRoleAttribute) as String?) == kAXButtonRole && submitTitles.contains((attribute(e, kAXTitleAttribute) as String?) ?? "")
        }), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
            AppLockLog.write("auth prompt: submitted with “\((attribute(button, kAXTitleAttribute) as String?) ?? "")”")
        } else {
            pressReturn(prompt, field: field)
        }
        guard retry else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window = axWindow(prompt), let field = secureField(in: window),
                  ((attribute(field, kAXNumberOfCharactersAttribute) as Int?) ?? 0) > 0 else { return }
            AppLockLog.write("auth prompt: still open with the password in; pressing Return")
            pressReturn(prompt, field: field)
        }
    }

    private static let submitTitles = ["OK", "Unlock", "Allow", "Modify Settings", "Install Software", "Update Settings", "Install Helper",
                                       "확인", "잠금 해제", "허용", "설정 수정", "소프트웨어 설치", "설정 업데이트", "도우미 설치"]

    /// Return, only into the verified prompt's own password field while it has focus.
    private static func pressReturn(_ prompt: Prompt, field: AXUIElement) {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard isApple(prompt.pid), focused(field) else {
            AppLockLog.write("auth prompt: password field isn't focused; not pressing Return")
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap)
        }
        AppLockLog.write("auth prompt: submitted with Return")
    }

    /// Unicode key events straight from the password bytes — no String of the password is kept.
    private static func type(_ bytes: [UInt8]) {
        let source = CGEventSource(stateID: .hidSystemState)
        var delay: TimeInterval = 0
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            var units = Array(String(scalar).utf16)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e?.post(tap: .cghidEventTap)
                }
                for i in units.indices { units[i] = 0 }
            }
            delay += 0.012
        }
    }

    // MARK: Checks

    nonisolated private static func promptProcessRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            guard proc_name(pid, &name, 64) > 0 else { continue }
            if owners.contains(String(cString: name)) { return true }
        }
        return false
    }

    nonisolated private static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Is `pid` Apple's SecurityAgent or LocalAuthentication UI agent, by code signature?
    static func isApple(_ pid: pid_t) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    private static func isCurrentUser(_ field: AXUIElement) -> Bool {
        let value = (attribute(field, kAXValueAttribute) as String?)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value == NSUserName() || value == NSFullUserName()
    }

    // MARK: Accessibility

    /// The prompt's AX window, matched to the window-server window by its frame.
    private static func axWindow(_ prompt: Prompt) -> AXUIElement? {
        let app = AXUIElementCreateApplication(prompt.pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let windows = (attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []
        return windows.first { w in
            guard let f = frame(w) else { return false }
            return abs(f.minX - prompt.bounds.minX) < 3 && abs(f.minY - prompt.bounds.minY) < 3 && abs(f.width - prompt.bounds.width) < 3
        } ?? (windows.count == 1 ? windows.first : nil)
    }

    private static func secureField(in window: AXUIElement) -> AXUIElement? {
        find(in: window) { (attribute($0, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole }
    }

    /// A plain text field in a password prompt is the account name.
    private static func userField(in window: AXUIElement) -> AXUIElement? {
        find(in: window) {
            (attribute($0, kAXRoleAttribute) as String?) == kAXTextFieldRole && (attribute($0, kAXSubroleAttribute) as String?) != kAXSecureTextFieldSubrole
        }
    }

    /// The Touch ID sheet's "Use Password…" button.
    private static func passwordButton(in window: AXUIElement) -> AXUIElement? {
        find(in: window) { e in
            guard (attribute(e, kAXRoleAttribute) as String?) == kAXButtonRole else { return false }
            let title = ((attribute(e, kAXTitleAttribute) as String?) ?? (attribute(e, kAXDescriptionAttribute) as String?) ?? "").lowercased()
            // "Use Password…" / "암호 사용…" — not a button that merely mentions a password.
            return title.contains("use password") || title.contains("enter password") || title.contains("암호 사용")
                || title.contains("암호 입력") || title.contains("비밀번호 사용") || title.contains("비밀번호 입력")
        }
    }

    private static func focused(_ element: AXUIElement) -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let now = attribute(system, kAXFocusedUIElementAttribute) as AXUIElement? else { return false }
        return CFEqual(now, element)
    }

    private static func find(in root: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 12 else { return nil }
        for child in (attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if match(child) { return child }
            if let found = find(in: child, depth: depth + 1, where: match) { return found }
        }
        return nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var p = CGPoint.zero, s = CGSize.zero
        guard let pos = attribute(element, kAXPositionAttribute) as AXValue?, let size = attribute(element, kAXSizeAttribute) as AXValue?,
              AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(size, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
