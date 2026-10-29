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
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacUnlock.shared.reached() }
        })
        AuthPromptUnlock.shared.start()
    }

    /// The saved login password as bytes, for a prompt Orbit fills in; the caller zeroes them.
    func passwordBytes() -> [UInt8]? {
        PasswordVault.readData().map { [UInt8]($0) }
    }

    // MARK: Setup

    /// Checks the password against your account, then saves it. Returns an error to show, or nil.
    func turnOn(password: String) async -> String? {
        guard await Self.confirmOwner("Turn on face unlock for your Mac".loc) else { return "Cancelled".loc }
        guard Self.isLoginPassword(password) else { return "That isn’t your login password.".loc }
        guard PasswordVault.save(password) else { return "Couldn’t save it to the Keychain.".loc }
        hasPassword = true
        enabled = true
        Pref.defaults.set(true, forKey: Pref.macUnlockEnabled)
        return nil
    }

    func turnOff() {
        PasswordVault.delete()
        if AuthPromptUnlock.shared.enabled { AuthPromptUnlock.shared.setEnabled(false) }
        hasPassword = false
        enabled = false
        Pref.defaults.set(false, forKey: Pref.macUnlockEnabled)
        stopWatching()
    }

    // MARK: At the lock screen

    private static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private func didLock() {
        guard ready else { return }
        lockedAt = Date()
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

    /// Someone pressed a key, touched the trackpad or woke the display at the lock screen.
    private func reached() {
        guard ready, Self.screenLocked, matcher == nil else { return }
        // Locking on purpose sticks: ignore the first few seconds, and the input that did the locking.
        guard Date().timeIntervalSince(lockedAt) > 4 else { return }
        // After two misses in a row, wait a bit before the camera comes on again.
        guard misses < 2 || Date().timeIntervalSince(lastScanEnded) > 10 else { return }
        if misses >= 2 { misses = 0 }
        let m = FaceMatcher { event in MainActor.assumeIsolated { MacUnlock.shared.handle(event) } }
        guard m.start(timeout: 6) else { return }
        matcher = m
    }

    private func handle(_ event: FaceMatcher.Event) {
        switch event {
        case .matched:
            end()
            guard Self.screenLocked, let password = PasswordVault.read() else { return }
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
            let retry = Pref.defaults.object(forKey: Pref.appLockAutoRetry) as? Bool ?? true
            if retry, misses == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let unlock = MacUnlock.shared
                    unlock.lockedAt = .distantPast
                    unlock.reached()
                }
            }
        default:
            break
        }
    }

    private func end() {
        matcher?.stop()
        matcher = nil
        lastScanEnded = Date()
    }

    private func didUnlock() {
        let byFace = unlockedByFace
        stopWatching()
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
    @State private var asking = false
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        SettingsGroup(title: "Unlock your Mac", footer: "When your face matches at the lock screen, Orbit types your login password for you. It only looks when you press a key, touch the trackpad or wake the screen — never right as you lock it.") {
            SettingsRow(title: "Face unlock for the lock screen", subtitle: status, symbol: "lock.open.display") {
                Toggle("", isOn: Binding(get: { unlock.enabled }, set: { on in
                    if on { withAnimation(.spring(duration: 0.3)) { asking = true } } else { unlock.turnOff(); asking = false }
                }))
                .toggleStyle(.switch).labelsHidden()
            }
            if asking && !unlock.enabled {
                RowDivider()
                HStack(spacing: 10) {
                    SecureField("Mac login password".loc, text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(password.isEmpty || working)
                    Button("Cancel") { asking = false; password = ""; error = nil }
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
            if unlock.enabled {
                RowDivider()
                SettingsRow(title: "Login password", subtitle: "Saved in this Mac’s Keychain only.", symbol: "key") {
                    Button("Change…") { unlock.turnOff(); asking = true }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: asking)
        .animation(.spring(duration: 0.3), value: unlock.enabled)

        SettingsGroup(footer: "When macOS asks for Touch ID or your password — System Settings, installers, apps — Orbit checks your face in the notch and fills the password in for you. Only Apple’s own password prompts, one try each; Touch ID and typing still work.") {
            SettingsRow(title: "Face for password prompts", subtitle: promptStatus, symbol: "touchid") {
                if !unlock.hasPassword {
                    Button("Set Up") { withAnimation(.spring(duration: 0.3)) { asking = true } }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
                Toggle("", isOn: Binding(get: { prompts.enabled }, set: { prompts.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(!unlock.hasPassword)
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
        if !unlock.hasPassword { return "Needs your login password — turn on face unlock for the lock screen first.".loc }
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

    private func save() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let problem = await unlock.turnOn(password: password)
            working = false
            password = ""
            if let problem { error = problem } else { asking = false }
        }
    }
}
