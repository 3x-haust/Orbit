import AppKit
import CryptoKit
import Observation

/// Orbit Passwords: the vault, its lock, and the settings around it.
///
/// Unlocked, the vault key and decrypted items live only in this object's memory. Locking drops
/// both; the file on disk is never anything but ciphertext.
@MainActor @Observable
final class Vault {
    static let shared = Vault()

    enum State { case none, locked, unlocked }

    private(set) var state: State = .none
    private(set) var items: [VaultItem] = []
    /// Logins Have I Been Pwned knew, from the last check this session.
    private(set) var breached: Set<UUID> = []
    private(set) var checkingBreaches = false
    private(set) var lastBreachCheck: Date?

    @ObservationIgnored private var file: VaultFile?
    @ObservationIgnored private var key: SymmetricKey?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var clipboardClear: DispatchWorkItem?
    @ObservationIgnored private var faceMatcher: FaceMatcher?

    let url: URL

    // MARK: Settings

    enum Key {
        static let autoLock = "passwords.autoLockMinutes"
        static let lockOnSleep = "passwords.lockOnSleep"
        static let lockOnScreenLock = "passwords.lockOnScreenLock"
        static let clearClipboard = "passwords.clearClipboardSeconds"
        static let breachCheck = "passwords.breachCheck"
        static let submitAfterFill = "passwords.submitAfterFill"
        static let rePrompt = "passwords.rePromptMaster"
        static let lastMaster = "passwords.lastMasterUnlock"
        static let generator = "passwords.generator"
    }

    private var defaults: UserDefaults { Pref.defaults }

    /// Minutes of no input before locking; 0 = never (still locks on sleep and quit).
    var autoLockMinutes: Int {
        get { access(keyPath: \.autoLockMinutes); return defaults.object(forKey: Key.autoLock) as? Int ?? 10 }
        set { withMutation(keyPath: \.autoLockMinutes) { defaults.set(newValue, forKey: Key.autoLock) }; armIdleTimer() }
    }
    var lockOnSleep: Bool {
        get { access(keyPath: \.lockOnSleep); return defaults.object(forKey: Key.lockOnSleep) as? Bool ?? true }
        set { withMutation(keyPath: \.lockOnSleep) { defaults.set(newValue, forKey: Key.lockOnSleep) } }
    }
    var lockOnScreenLock: Bool {
        get { access(keyPath: \.lockOnScreenLock); return defaults.object(forKey: Key.lockOnScreenLock) as? Bool ?? true }
        set { withMutation(keyPath: \.lockOnScreenLock) { defaults.set(newValue, forKey: Key.lockOnScreenLock) } }
    }
    /// 0 = leave it.
    var clearClipboardSeconds: Int {
        get { access(keyPath: \.clearClipboardSeconds); return defaults.object(forKey: Key.clearClipboard) as? Int ?? 90 }
        set { withMutation(keyPath: \.clearClipboardSeconds) { defaults.set(newValue, forKey: Key.clearClipboard) } }
    }
    var breachCheck: Bool {
        get { access(keyPath: \.breachCheck); return defaults.bool(forKey: Key.breachCheck) }
        set { withMutation(keyPath: \.breachCheck) { defaults.set(newValue, forKey: Key.breachCheck) }; if newValue { checkBreaches() } }
    }
    var submitAfterFill: Bool {
        get { access(keyPath: \.submitAfterFill); return defaults.bool(forKey: Key.submitAfterFill) }
        set { withMutation(keyPath: \.submitAfterFill) { defaults.set(newValue, forKey: Key.submitAfterFill) } }
    }
    /// Ask for the Master Password every two weeks even when Touch ID is on, so it isn't forgotten.
    var rePromptMaster: Bool {
        get { access(keyPath: \.rePromptMaster); return defaults.object(forKey: Key.rePrompt) as? Bool ?? true }
        set { withMutation(keyPath: \.rePromptMaster) { defaults.set(newValue, forKey: Key.rePrompt) } }
    }
    var generatorOptions: PasswordGenerator.Options {
        get {
            access(keyPath: \.generatorOptions)
            return defaults.data(forKey: Key.generator).flatMap { try? JSONDecoder().decode(PasswordGenerator.Options.self, from: $0) } ?? .init()
        }
        set { withMutation(keyPath: \.generatorOptions) { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.generator) } }
    }

    // MARK: Life cycle

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit/Passwords", isDirectory: true)
        url = dir.appendingPathComponent("Vault.orbitvault")
        reload()
    }

    /// Re-reads the file (locked). Called at launch and after restoring.
    private func reload() {
        file = try? VaultFile.read(url)
        state = file == nil ? .none : .locked
    }

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Vault.shared.lockOnSleep { Vault.shared.lock() } }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Vault.shared.lockOnSleep { Vault.shared.lock() } }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if Vault.shared.lockOnScreenLock { Vault.shared.lock() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Vault.shared.lock() }
        })
    }

    var accountID: String? { file?.accountID }

    // MARK: Setup

    /// A Secret Key and account ID for a vault that doesn't exist yet, so the Emergency Kit can be saved
    /// before anything is created — setup never leaves a vault behind without its kit.
    struct PendingAccount {
        var secret: [UInt8]
        let accountID: String
        var text: String { VaultCrypto.formatSecretKey(secret) }
        static func make() throws -> PendingAccount { PendingAccount(secret: try VaultCrypto.random(16), accountID: UUID().uuidString) }
        mutating func wipe() { VaultCrypto.wipe(&secret) }
    }

    /// Makes the new vault from a pending account whose Emergency Kit the person has saved.
    func create(password: String, account: PendingAccount) async throws {
        let s = account.secret, id = account.accountID
        let (newFile, newKey) = try await Task.detached { try VaultFile.create(password: password, secretKey: s, accountID: id) }.value
        guard SecretKeyStore.save(s, account: newFile.accountID) else { throw VaultCrypto.Failure.damaged }
        try newFile.write(url)
        file = newFile
        key = newKey
        items = []
        state = .unlocked
        defaults.set(Date(), forKey: Key.lastMaster)
        armIdleTimer()
    }

    /// Sets up this Mac from a vault file and its Emergency Kit (a new Mac, or after a reinstall).
    func restore(from source: URL, secretKeyText: String, password: String) async throws {
        guard let secret = VaultCrypto.parseSecretKey(secretKeyText) else { throw VaultCrypto.Failure.wrongPassword }
        let restored = try VaultFile.read(source)
        let k = try await Task.detached { try restored.unlock(password: password, secretKey: secret) }.value
        guard SecretKeyStore.save(secret, account: restored.accountID) else { throw VaultCrypto.Failure.damaged }
        try restored.write(url)
        file = restored
        finishUnlock(k)
    }

    // MARK: Unlocking

    var secretKeyMissing: Bool {
        guard let file else { return false }
        return SecretKeyStore.read(account: file.accountID) == nil
    }

    func unlock(password: String) async throws {
        guard let file, let secret = SecretKeyStore.read(account: file.accountID) else { throw VaultCrypto.Failure.damaged }
        let k = try await Task.detached { try file.unlock(password: password, secretKey: secret) }.value
        defaults.set(Date(), forKey: Key.lastMaster)
        finishUnlock(k)
    }

    /// Touch ID is offered unless it's off, or the Master Password is due (every two weeks).
    var canUseTouchID: Bool {
        guard let id = accountID, BiometricUnlock.isAvailable, BiometricUnlock.isEnabled(account: id) else { return false }
        return !masterDue
    }

    var canUseFace: Bool {
        guard let id = accountID, FaceVaultKey.isEnabled(account: id), FaceMatcher.unavailable == nil else { return false }
        return !masterDue
    }

    var masterDue: Bool {
        guard rePromptMaster, let last = defaults.object(forKey: Key.lastMaster) as? Date else { return false }
        return Date().timeIntervalSince(last) > 14 * 86_400
    }

    @discardableResult
    func unlockWithTouchID() async -> Bool {
        guard canUseTouchID, let id = accountID,
              let k = await BiometricUnlock.unlock(account: id, reason: "unlock Orbit Passwords".loc) else { return false }
        finishUnlock(k)
        return true
    }

    /// The notch face check; on a match the key Orbit keeps for this is released.
    func unlockWithFace(completion: ((Bool) -> Void)? = nil) {
        guard canUseFace, faceMatcher == nil, let id = accountID else { completion?(false); return }
        let hud = NotchHUD.shared
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        hud.show(on: screen, label: "Unlock Passwords with your face".loc, compact: true)
        let m = FaceMatcher { [weak self] event in
            guard let self else { return }
            switch event {
            case .progress(let p): hud.setProgress(p)
            case .noFace: hud.setProgress(0)
            case .blink: hud.setLabel("Blink once".loc)
            case .tooFar: break
            case .matched:
                faceMatcher = nil
                if let k = FaceVaultKey.release(account: id) {
                    finishUnlock(k)
                    hud.matched(label: "Unlocked".loc)
                    completion?(true)
                } else {
                    hud.failed(label: "Use your Master Password".loc, buttons: false)
                    hud.collapse(after: 1.2)
                    completion?(false)
                }
            case .failed:
                faceMatcher = nil
                hud.failed(label: "Face not recognized".loc, buttons: false)
                hud.collapse(after: 1.2)
                completion?(false)
            }
        }
        guard m.start(timeout: 6) else {
            hud.failed(label: "Couldn’t start the camera".loc, buttons: false)
            hud.collapse(after: 1.2)
            completion?(false)
            return
        }
        faceMatcher = m
        hud.model.session = m.session
    }

    private func finishUnlock(_ k: SymmetricKey) {
        guard let file else { return }
        var opened: [VaultItem] = []
        for sealed in file.items {
            if let item = try? file.open(sealed, vaultKey: k) { opened.append(item) }
        }
        key = k
        items = opened.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        state = .unlocked
        armIdleTimer()
        if breachCheck, lastBreachCheck.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true { checkBreaches() }
    }

    func lock() {
        guard state == .unlocked else { return }
        key = nil
        items = []
        breached = []
        state = file == nil ? .none : .locked
        idleTimer?.invalidate()
        idleTimer = nil
        faceMatcher?.stop()
        faceMatcher = nil
        PasswordsPanel.shared.vaultLocked()
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard state == .unlocked, autoLockMinutes > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated {
                let v = Vault.shared
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                if idle > Double(v.autoLockMinutes * 60) { v.lock() }
            }
        }
    }

    // MARK: Unlock methods

    var touchIDEnabled: Bool { accountID.map(BiometricUnlock.isEnabled) ?? false }
    var faceEnabled: Bool { accountID.map(FaceVaultKey.isEnabled) ?? false }

    func setTouchID(_ on: Bool) {
        guard let id = accountID else { return }
        if on {
            guard let key else { return }
            do { try BiometricUnlock.enable(vaultKey: key, account: id) } catch { Toast.show("Couldn’t turn on Touch ID", symbol: "exclamationmark.triangle.fill") }
        } else {
            BiometricUnlock.disable(account: id)
        }
    }

    func setFace(_ on: Bool) {
        guard let id = accountID else { return }
        if on, let key { _ = FaceVaultKey.enable(vaultKey: key, account: id) } else { FaceVaultKey.disable(account: id) }
    }

    /// The Secret Key, for showing again or a new Emergency Kit. Needs the vault open.
    func secretKeyText() -> String? {
        guard state == .unlocked, let id = accountID, var secret = SecretKeyStore.read(account: id) else { return nil }
        defer { VaultCrypto.wipe(&secret) }
        return VaultCrypto.formatSecretKey(secret)
    }

    func changeMasterPassword(current: String, new: String) async throws {
        guard let f = file, let k = key, let secret = SecretKeyStore.read(account: f.accountID) else { throw VaultCrypto.Failure.damaged }
        let changed = try await Task.detached { () -> VaultFile in
            _ = try f.unlock(password: current, secretKey: secret)
            var g = f
            try g.changePassword(to: new, secretKey: secret, vaultKey: k)
            return g
        }.value
        try changed.write(url)
        file = changed
        defaults.set(Date(), forKey: Key.lastMaster)
    }

    /// Removes the vault, its Secret Key and unlock keys from this Mac. There is no undo.
    func eraseEverything() {
        if let id = accountID {
            SecretKeyStore.delete(account: id)
            BiometricUnlock.disable(account: id)
            FaceVaultKey.disable(account: id)
        }
        key = nil
        items = []
        try? FileManager.default.removeItem(at: url)
        file = nil
        state = .none
    }

    // MARK: Items

    func save(_ item: VaultItem) {
        var item = item
        item.updated = Date()
        if item.kind == .login, item.passwordChanged == nil, !item.password.isEmpty { item.passwordChanged = Date() }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persist()
    }

    func delete(_ item: VaultItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Imported items: a login for the same site and username as an existing one updates it (the old
    /// password goes into its history) instead of making a duplicate.
    @discardableResult
    func merge(_ incoming: [VaultItem]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        for new in incoming {
            if let i = items.firstIndex(where: { ImportMatch.sameLogin($0, new) }) {
                var old = items[i]
                guard old.password != new.password || old.totp.isEmpty && !new.totp.isEmpty else { continue }
                old.setPassword(new.password)
                if old.totp.isEmpty { old.totp = new.totp }
                old.updated = Date()
                items[i] = old
                updated += 1
            } else {
                items.append(new)
                added += 1
            }
        }
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persist()
        return (added, updated)
    }

    func add(_ new: [VaultItem]) {
        items.append(contentsOf: new)
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        persist()
    }

    private func persist() {
        guard var f = file, let k = key else { return }
        do {
            f.items = try items.map { try f.seal($0, vaultKey: k) }
            try f.write(url)
            file = f
        } catch {
            Toast.show("Couldn’t save the vault", symbol: "exclamationmark.triangle.fill")
        }
    }

    func export(password: String) throws -> Data {
        try VaultExport.make(items, password: password)
    }

    // MARK: Watchtower

    var issues: [Watchtower.Issue: [VaultItem]] { Watchtower.scan(items, breached: breached) }

    func checkBreaches() {
        guard breachCheck, state == .unlocked, !checkingBreaches else { return }
        checkingBreaches = true
        let snapshot = items
        Task {
            let found = await Watchtower.checkBreaches(snapshot)
            breached = found
            checkingBreaches = false
            lastBreachCheck = Date()
        }
    }

    // MARK: Clipboard

    /// Copies so other clipboard managers (and Orbit's own history) skip it, and clears it after a while.
    func copy(_ value: String, what: String) {
        guard !value.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: .init("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let count = pb.changeCount
        clipboardClear?.cancel()
        let seconds = clearClipboardSeconds
        if seconds > 0 {
            let work = DispatchWorkItem {
                if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
            clipboardClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
            Toast.show("%@ copied".loc(what.loc), symbol: "key.horizontal.fill", detail: "Clears in %lds".loc(seconds))
        } else {
            Toast.show("%@ copied".loc(what.loc), symbol: "key.horizontal.fill")
        }
    }
}
