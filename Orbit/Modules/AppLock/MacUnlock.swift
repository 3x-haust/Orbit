import AppKit
import LocalAuthentication
import OpenDirectory
import Security
import SwiftUI

extension Pref {
    /// Unlock the Mac's lock screen with your face (Glance-style: Orbit types your login password).
    static let macUnlockEnabled = "macunlock.enabled"
}

/// Face unlock for the lock screen. macOS only takes a password, Touch ID, an Apple Watch or a smart
/// card there, so — like Glance — Orbit keeps your login password in this Mac's Keychain and types
/// it for you once your face matches.
///
/// It only looks when you reach for the Mac at the lock screen (a key, the trackpad, the display
/// waking) — never the moment you lock it, so locking on purpose sticks.
@MainActor @Observable
final class MacUnlock {
    static let shared = MacUnlock()

    private(set) var enabled = Pref.defaults.bool(forKey: Pref.macUnlockEnabled)
    private(set) var hasPassword = PasswordVault.exists

    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var matcher: FaceMatcher?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var lockedAt = Date.distantPast
    @ObservationIgnored private var lastScanEnded = Date.distantPast
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var unlockedByFace = false
    @ObservationIgnored private var lastIdle: Double = .infinity

    /// Everything it needs: switched on, a password saved, a face enrolled, and Accessibility to type.
    var ready: Bool { enabled && hasPassword && FaceStore.isEnrolled && AXIsProcessTrusted() }

    func start() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacUnlock.shared.didLock() }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacUnlock.shared.didUnlock() }
        })
        // The screen coming back on — from sleep, display sleep or the screen saver — is someone
        // reaching for the Mac; keys and the trackpad are caught by checkInput.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MacUnlock.shared.woke() }
            })
        }
        observers.append(center.addObserver(forName: .init("com.apple.screensaver.didstop"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacUnlock.shared.woke() }
        })
        // Read the face now, while the Mac is unlocked: its file may not open once it's locked.
        if enabled {
            let faces = FaceStore.load().count
            AppLockLog.write("lock screen unlock: \(notReadyReason ?? "ready"), \(faces) face samples read")
        }
        AuthPromptUnlock.shared.start()
    }

    /// The saved login password as bytes, for a prompt Orbit fills in; the caller zeroes them.
    func passwordBytes() -> [UInt8]? {
        PasswordVault.readData().map { [UInt8]($0) }
    }

    // MARK: Setup

    /// The lock screen and macOS's password prompts each use the face only if switched on; they
    /// share the saved login password, which stays only while one of them is on.
    enum Use { case lockScreen, prompts }

    /// Checks the password against your account and saves it, then switches `use` on (none: just a
    /// new password). Returns an error to show, or nil.
    func save(password: String, turningOn use: Use?) async -> String? {
        guard await Self.confirmOwner("Use your face in place of your password".loc) else { return "Cancelled".loc }
        guard Self.isLoginPassword(password) else { return "That isn’t your login password.".loc }
        guard PasswordVault.save(password) else { return "Couldn’t save it to the Keychain.".loc }
        hasPassword = true
        if let use { setUse(use, on: true) }
        return nil
    }

    /// Switches one use on or off. On needs the saved password; off forgets the password once
    /// neither uses it.
    func setUse(_ use: Use, on: Bool) {
        switch use {
        case .lockScreen:
            enabled = on && hasPassword
            Pref.defaults.set(enabled, forKey: Pref.macUnlockEnabled)
            if enabled { _ = FaceStore.load() } else { stopWatching() }
        case .prompts:
            AuthPromptUnlock.shared.setEnabled(on && hasPassword)
        }
        if !enabled, !AuthPromptUnlock.shared.enabled { forgetPassword() }
    }

    private func forgetPassword() {
        PasswordVault.delete()
        hasPassword = false
    }

    // MARK: At the lock screen

    private static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    /// Why it isn't ready, for the log.
    private var notReadyReason: String? {
        if !enabled { return "switched off" }
        if !hasPassword { return "no saved password" }
        if !FaceStore.isEnrolled { return "no face set up" }
        if !AXIsProcessTrusted() { return "no Accessibility permission" }
        return nil
    }

    private func didLock(at time: Date = Date()) {
        guard ready else { AppLockLog.write("lock screen: locked, not watching (\(notReadyReason ?? "?"))"); return }
        AppLockLog.write("lock screen: locked, watching for you")
        lockedAt = time
        misses = 0
        unlockedByFace = false
        lastIdle = .infinity
        // Watch for someone reaching for the Mac: input makes the idle time drop back to ~0.
        poll?.invalidate()
        let t = Timer(timeInterval: 0.4, repeats: true) { _ in MainActor.assumeIsolated { MacUnlock.shared.checkInput() } }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func checkInput() {
        guard Self.screenLocked else { stopWatching(); return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        defer { lastIdle = idle }
        if idle < 0.5, lastIdle > idle { reached() }
    }

    /// Right after a wake the session can still report "unlocked" for a moment (and a lock done
    /// while asleep is only noticed now), so look again shortly after.
    private func woke() {
        AppLockLog.write("lock screen: woke (locked: \(Self.screenLocked))")
        reached()
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let unlock = MacUnlock.shared
                guard !unlock.unlockedByFace else { return }
                if unlock.poll == nil, Self.screenLocked, unlock.ready { unlock.didLock(at: unlock.lockedAt) }
                unlock.reached()
            }
        }
    }

    /// Someone pressed a key, touched the trackpad or woke the display at the lock screen.
    private func reached() {
        // Once the face matched, the lock screen takes a moment to go: that's not a new try.
        guard Self.screenLocked, matcher == nil, !unlockedByFace else { return }
        guard ready else { AppLockLog.write("lock screen: woken, not looking (\(notReadyReason ?? "?"))"); return }
        // Locking on purpose sticks: ignore the first few seconds, and the input that did the locking.
        guard Date().timeIntervalSince(lockedAt) > 4 else { return }
        // After two misses in a row, wait a bit before the camera comes on again.
        guard misses < 2 || Date().timeIntervalSince(lastScanEnded) > 10 else { return }
        if misses >= 2 { misses = 0 }
        let m = FaceMatcher { event in MainActor.assumeIsolated { MacUnlock.shared.handle(event) } }
        guard m.start(timeout: 6) else { AppLockLog.write("lock screen: the face check didn't start"); return }
        matcher = m
        // The scan shows in the notch over the lock screen, the way Face ID shows it on an iPhone.
        let hud = NotchHUD.shared
        hud.show(on: Self.notchScreen, label: "Look at the camera".loc, compact: true)
        hud.liftOverLockScreen()
        AppLockLog.write("lock screen: looking for your face")
    }

    private static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main }

    private func handle(_ event: FaceMatcher.Event) {
        let hud = NotchHUD.shared
        switch event {
        case .progress(let p): hud.setProgress(p)
        case .noFace: hud.setProgress(0)
        case .blink: hud.setLabel("Blink once".loc)
        case .tooFar: break
        case .matched:
            end()
            guard Self.screenLocked, let password = PasswordVault.read() else {
                hud.failed(label: "Use your password".loc, buttons: false)
                hud.collapse(after: 1.4)
                AppLockLog.write("lock screen: face matched, but the saved password couldn't be read")
                return
            }
            hud.matched(label: "Unlocking…".loc, collapseAfter: 1.5)
            unlockedByFace = true
            let delay = KeyTyper.type(password, thenReturn: true)
            AppLockLog.write("lock screen: face matched, typed the password and pressed Return")
            // Still locked a moment later (the field ate the first Return while waking): once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.2) {
                guard Self.screenLocked, MacUnlock.shared.unlockedByFace else { return }
                AppLockLog.write("lock screen: still locked after typing; pressing Return again")
                KeyTyper.pressReturn()
            }
        case .failed:
            end()
            misses += 1
            hud.failed(label: "Face not recognized".loc, buttons: false)
            hud.collapse(after: 1.2)
            let retry = Pref.defaults.object(forKey: Pref.appLockAutoRetry) as? Bool ?? true
            if retry, misses == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let unlock = MacUnlock.shared
                    unlock.lockedAt = .distantPast
                    unlock.reached()
                }
            }
        }
    }

    private func end() {
        matcher?.stop()
        matcher = nil
        lastScanEnded = Date()
    }

    private func didUnlock() {
        let byFace = unlockedByFace
        let scanning = matcher != nil
        AppLockLog.write("lock screen: unlocked (\(byFace ? "by face" : "another way"))")
        stopWatching()
        NotchHUD.shared.lowerFromLockScreen()
        // Unlocked some other way mid-scan: fold the scan away.
        if scanning || NotchHUD.shared.isShowing, !byFace { NotchHUD.shared.collapse() }
        if byFace {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotchHUD.shared.message("Unlocked with your face".loc, on: NSScreen.main)
            }
        }
    }

    private func stopWatching() {
        poll?.invalidate()
        poll = nil
        end()
        unlockedByFace = false
        misses = 0
    }

    // MARK: Checks

    private static func confirmOwner(_ reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// Asks Directory Services whether this is the current user's login password.
    private static func isLoginPassword(_ password: String) -> Bool {
        guard !password.isEmpty,
              let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil) else { return false }
        return (try? record.verifyPassword(password)) != nil
    }
}

/// The login password, in this Mac's Keychain only: never synced, never in a backup another Mac can open.
private enum PasswordVault {
    private static let service = "com.lyu.orbit.macunlock"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: NSUserName()]
    }

    static var exists: Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ password: String) -> Bool {
        delete()
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        // Readable while the screen is locked (that's when it's needed), but only on this Mac.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "Orbit — Mac unlock"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func readData() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return data
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Types text into whatever has keyboard focus — here, the lock screen's password field.
private enum KeyTyper {
    /// Returns how long the typing takes.
    @discardableResult
    static func type(_ text: String, thenReturn: Bool) -> TimeInterval {
        let source = CGEventSource(stateID: .hidSystemState)
        // A tap of Shift first wakes the password field without typing anything into it.
        post(source, key: 56, down: true)
        post(source, key: 56, down: false)
        var delay: TimeInterval = 0.12
        for ch in text {
            let units = Array(String(ch).utf16)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e?.post(tap: .cghidEventTap)
                }
            }
            delay += 0.012
        }
        if thenReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { pressReturn() }
        }
        return delay + 0.05
    }

    static func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        post(source, key: 36, down: true)
        post(source, key: 36, down: false)
    }

    private static func post(_ source: CGEventSource?, key: CGKeyCode, down: Bool) {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
    }
}

/// The "Unlock your Mac" group on the Face Unlock page.
struct MacUnlockSection: View {
    private var unlock: MacUnlock { .shared }
    /// Which switch the password field is for (nil: changing the password).
    @State private var asking: MacUnlock.Use??
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        SettingsGroup(title: "Unlock your Mac", footer: "When your face matches at the lock screen, Orbit types your login password for you. It only looks when you press a key, touch the trackpad or wake the screen — never right as you lock it.") {
            SettingsRow(title: "Face unlock for the lock screen", subtitle: status, symbol: "lock.open.display") {
                Toggle("", isOn: Binding(get: { unlock.enabled }, set: { switchUse(.lockScreen, on: $0) }))
                .toggleStyle(.switch).labelsHidden()
            }
            if asking != nil {
                RowDivider()
                HStack(spacing: 10) {
                    SecureField("Mac login password".loc, text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(password.isEmpty || working)
                    Button("Cancel") { asking = nil; password = ""; error = nil }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                if let error {
                    Text(error).font(.orbitCaption).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            if unlock.hasPassword, asking == nil {
                RowDivider()
                SettingsRow(title: "Login password", subtitle: "Saved in this Mac’s Keychain only.", symbol: "key") {
                    Button("Change…") { withAnimation(.spring(duration: 0.3)) { asking = .some(nil) } }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: asking != nil)
        .animation(.spring(duration: 0.3), value: unlock.enabled)

        SettingsGroup(footer: "When macOS asks for Touch ID or your password — System Settings, installers, apps — Orbit checks your face in the notch and fills the password in for you. Only Apple’s own password prompts, one try each; Touch ID and typing still work.") {
            SettingsRow(title: "Face for password prompts", subtitle: promptStatus, symbol: "touchid") {
                Toggle("", isOn: Binding(get: { prompts.enabled }, set: { switchUse(.prompts, on: $0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        }

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            Text("Your login password stays in this Mac’s Keychain and is only ever typed into the lock screen or Apple’s own password prompts. A good photo could fool face matching, so keep “Require a blink” on, and use this only on a Mac that’s yours alone.")
                .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.tight)
    }

    private var prompts: AuthPromptUnlock { .shared }

    private var promptStatus: String {
        if !prompts.enabled { return "Off".loc }
        if !FaceStore.isEnrolled { return "Set up your face above first.".loc }
        if !AXIsProcessTrusted() { return "Needs Accessibility to type the password.".loc }
        return "On — look at the camera when macOS asks for your password.".loc
    }

    private var status: String {
        if !unlock.enabled { return "Off".loc }
        if !FaceStore.isEnrolled { return "Set up your face above first.".loc }
        if !AXIsProcessTrusted() { return "Needs Accessibility to type the password.".loc }
        return "On — look at the camera at the lock screen.".loc
    }

    /// Off is immediate; on asks for the login password first if none is saved.
    private func switchUse(_ use: MacUnlock.Use, on: Bool) {
        error = nil
        if on, !unlock.hasPassword {
            withAnimation(.spring(duration: 0.3)) { asking = .some(use) }
        } else {
            unlock.setUse(use, on: on)
            if !on, asking == .some(use) { asking = nil }
        }
    }

    private func save() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let problem = await unlock.save(password: password, turningOn: asking ?? nil)
            working = false
            password = ""
            if let problem { error = problem } else { asking = nil }
        }
    }
}
