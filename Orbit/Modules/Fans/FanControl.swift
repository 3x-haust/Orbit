import AppKit
import ServiceManagement

/// Manual fan control. Orbit decides the speed; OrbitFanHelper (root) writes it to the SMC.
/// The helper only holds a speed for `FanHelper.leaseSeconds`, so Orbit renews it every couple of
/// seconds — if Orbit quits, crashes or the Mac sleeps, the fans go back to macOS on their own.
@MainActor @Observable
final class FanControl {
    static let shared = FanControl()

    enum Mode: String, CaseIterable, Identifiable {
        case auto, curve, fixed, max
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Automatic"
            case .curve: "By temperature"
            case .fixed: "Fixed"
            case .max: "Full speed"
            }
        }
    }

    enum HelperState: Equatable { case off, needsApproval, ready }

    private(set) var helper: HelperState = .off
    /// What Orbit is asking the first fan for right now; nil while macOS is in charge.
    private(set) var target: Double?
    private(set) var lastError: String?

    var mode: Mode = .auto {
        didSet { Pref.defaults.set(mode.rawValue, forKey: Pref.fanMode); apply() }
    }
    /// Fixed mode, 0…1 between each fan's minimum and maximum.
    var fixedLevel: Double = 0.5 {
        didSet { Pref.defaults.set(fixedLevel, forKey: Pref.fanFixedLevel); if mode == .fixed { tick() } }
    }
    /// By-temperature mode: macOS stays in charge below `curveLow`; full speed from `curveHigh`.
    var curveLow: Double = 55 {
        didSet { Pref.defaults.set(curveLow, forKey: Pref.fanCurveLow); if mode == .curve { tick() } }
    }
    var curveHigh: Double = 85 {
        didSet { Pref.defaults.set(curveHigh, forKey: Pref.fanCurveHigh); if mode == .curve { tick() } }
    }

    @ObservationIgnored private let service = SMAppService.daemon(plistName: FanHelper.plist)
    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var manual: Set<Int> = []
    @ObservationIgnored private var upgrade: Task<Bool, Never>?

    private init() {
        let d = Pref.defaults
        mode = Mode(rawValue: d.string(forKey: Pref.fanMode) ?? "") ?? .auto
        fixedLevel = d.double(forKey: Pref.fanFixedLevel)
        curveLow = d.double(forKey: Pref.fanCurveLow)
        curveHigh = d.double(forKey: Pref.fanCurveHigh)
    }

    var hasFans: Bool { !SMC.shared.fans().isEmpty }

    func start() {
        refresh()
        apply()
        upgrade = Task { await upgradeHelperIfNeeded() }
    }

    /// A bounded version probe on the same signed connection used by fans and battery control.
    private func versionReply(using connection: NSXPCConnection) async -> Result<Int, Error>? {
        await withCheckedContinuation { done in
            let once = Once<Result<Int, Error>?>(done)
            let proxy = connection.remoteObjectProxyWithErrorHandler { once.resume(.failure($0)) } as? FanHelperProtocol
            proxy?.version { once.resume(.success($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once.resume(nil) }
        }
    }

    /// Replace a stale helper once at launch, verifying the new peer before reporting success.
    private func upgradeHelperIfNeeded() async -> Bool {
        guard helper == .ready, proxy() != nil, let connection else { return false }
        var reply = await versionReply(using: connection)
        guard !Task.isCancelled else { return false }
        // An interruption can also be a healthy helper relaunching. Give that same signed
        // connection one more handshake before replacing an approved service.
        if case .failure(let error as NSError) = reply,
           error.domain == NSCocoaErrorDomain, error.code == NSXPCConnectionInterrupted {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return false }
            reply = await versionReply(using: connection)
        }
        guard !Task.isCancelled else { return false }
        guard Self.helperNeedsRestart(reply) else {
            if case .success = reply { return true }
            return false
        }
        connection.invalidate()
        self.connection = nil
        lastError = nil
        do { try await service.unregister() } catch { lastError = error.localizedDescription }
        // The unregistration can still be landing when the helper is registered again, which leaves it off.
        for delay in [0.5, 1, 2] {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return false }
            do { try service.register() } catch { if lastError == nil { lastError = error.localizedDescription } }
            if service.status == .requiresApproval {
                refresh()
                Toast.show("Orbit Helper was updated", symbol: "key.fill", detail: "Allow it again in Login Items")
                return false
            }
            if service.status == .enabled, proxy() != nil, let replacement = self.connection {
                let verified = await versionReply(using: replacement)
                guard !Task.isCancelled else { return false }
                if case .success(let version) = verified, version >= FanHelper.version {
                    lastError = nil
                    refresh()
                    return true
                }
                if lastError == nil, case .failure(let error) = verified { lastError = error.localizedDescription }
            }
        }
        if lastError == nil { lastError = "Orbit Helper did not answer with the updated version." }
        refresh()
        return false
    }

    /// The update moves the old app to the Trash, so the helper still running from it fails its
    /// signature check and every call to it fails. A legacy helper also rejects the new app ID,
    /// which reaches the client as an interrupted handshake. launchd cannot repair that by starting
    /// the same old binary again; re-register the helper bundled with this app. A slow one is left alone.
    nonisolated static func helperNeedsRestart(_ reply: Result<Int, Error>?) -> Bool {
        switch reply {
        case .success(let running): running < FanHelper.version
        case .failure(let error as NSError):
            error.domain == NSCocoaErrorDomain
                && [NSXPCConnectionCodeSigningRequirementFailure, NSXPCConnectionInterrupted].contains(error.code)
        case nil: false
        }
    }

    /// The helper's registration can change in System Settings at any time.
    func refresh() {
        let before = helper
        helper = switch service.status {
        case .enabled: .ready
        case .requiresApproval: .needsApproval
        default: .off
        }
        if before != helper, helper == .ready { apply() }
    }

    func installHelper() {
        lastError = nil
        do { try service.register() } catch { lastError = error.localizedDescription }
        refresh()
        if helper == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func removeHelper() {
        upgrade?.cancel()
        upgrade = nil
        mode = .auto
        Task {
            try? await Task.sleep(for: .milliseconds(400)) // let the fans go back to macOS first
            try? await service.unregister()
            connection?.invalidate()
            connection = nil
            refresh()
        }
    }

    /// Ring / launcher: full speed on, or back to whatever macOS wants.
    func toggleFullSpeed() {
        guard helper == .ready else {
            MainWindow.show(.system)
            Toast.show("Turn on fan control first", symbol: "fan")
            return
        }
        mode = mode == .max ? .auto : .max
        Toast.show(mode == .max ? "Fans at full speed" : "Fans back to automatic", symbol: "fan")
    }

    // MARK: Driving

    private func apply() {
        timer?.invalidate()
        timer = nil
        guard mode != .auto, helper == .ready else {
            releaseAll()
            return
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { FanControl.shared.tick() }
        }
    }

    private func tick() {
        guard mode != .auto, helper == .ready else { return }
        let mode = mode, level = fixedLevel, low = curveLow, high = curveHigh
        Task.detached {
            let fans = SMC.shared.fans()
            let chip = mode == .curve ? SMC.shared.temperatures().chip : nil
            let plan = fans.map { ($0.id, Self.speed(for: $0, mode: mode, level: level, chip: chip, low: low, high: high)) }
            await MainActor.run { FanControl.shared.send(plan) }
        }
    }

    /// nil means "let macOS decide".
    nonisolated static func speed(for fan: SMC.Fan, mode: Mode, level: Double, chip: Double?, low: Double, high: Double) -> Double? {
        let span = fan.max - fan.min
        switch mode {
        case .auto: return nil
        case .max: return fan.max
        case .fixed: return fan.min + span * min(1, max(0, level))
        case .curve:
            guard let chip, chip >= low else { return nil }
            return fan.min + span * min(1, (chip - low) / max(1, high - low))
        }
    }

    private func send(_ plan: [(Int, Double?)]) {
        guard self.mode != .auto, let helper = proxy() else { return }
        target = plan.first?.1
        for (fan, rpm) in plan {
            if let rpm {
                manual.insert(fan)
                helper.setFan(fan, rpm: rpm) { error in Task { @MainActor in FanControl.shared.lastError = error } }
            } else if manual.remove(fan) != nil {
                helper.setAutomatic(fan) { _ in }
            }
        }
    }

    private func releaseAll() {
        target = nil
        guard !manual.isEmpty, let helper = proxy() else { manual.removeAll(); return }
        for fan in manual { helper.setAutomatic(fan) { _ in } }
        manual.removeAll()
    }

    /// Closed-lid mode through the helper, so only the one-time approval is needed.
    /// nil when the helper isn't installed or is too old to know how (the caller then asks for a password).
    func setSleepDisabled(_ on: Bool) async -> Bool? {
        _ = await upgrade?.value // approval may have changed since recovery; still probe the live helper below
        refresh()
        guard helper == .ready, let helper = proxy() else { return nil }
        let version: Int? = await withCheckedContinuation { done in
            let once = Once(done)
            helper.version { v in once.resume(v) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once.resume(nil) }
        }
        guard let version, version >= 2 else { return nil }
        return await withCheckedContinuation { done in
            let once = Once<Bool?>(done)
            helper.setSleepDisabled(on) { error in once.resume(error == nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.resume(nil) }
        }
    }

    /// Quit-only connection and deadlines, independent of the main queue.
    nonisolated static func setSleepDisabled(_ on: Bool) async -> Bool? {
        let connection = NSXPCConnection(machServiceName: FanHelper.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.setCodeSigningRequirement(FanHelper.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }
        let version: Int? = await withCheckedContinuation { done in
            let once = Once(done)
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) }) as? FanHelperProtocol
            else { once.resume(nil); return }
            helper.version { v in once.resume(v) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.resume(nil) }
        }
        guard let version, version >= 2 else { return nil }
        return await withCheckedContinuation { done in
            let once = Once<Bool?>(done)
            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in once.resume(nil) }) as? FanHelperProtocol
            else { once.resume(nil); return }
            helper.setSleepDisabled(on) { error in once.resume(error == nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { once.resume(nil) }
        }
    }

    /// The running helper's protocol version, or nil when it isn't reachable.
    func helperVersion() async -> Int? {
        _ = await upgrade?.value
        refresh()
        guard helper == .ready, proxy() != nil, let connection else { return nil }
        if case .success(let version) = await versionReply(using: connection) { return version }
        return nil
    }

    /// The helper for other privileged features (battery); nil unless it's installed and approved.
    func helperProxy() -> FanHelperProtocol? {
        guard helper == .ready else { return nil }
        return proxy()
    }

    /// Blocks for at most `timeout` — for the last word while Orbit quits.
    nonisolated static func synchronously(timeout: TimeInterval, _ body: (FanHelperProtocol, @escaping () -> Void) -> Void) {
        let c = NSXPCConnection(machServiceName: FanHelper.label, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        c.setCodeSigningRequirement(FanHelper.helperRequirement)
        c.resume()
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        guard let p = c.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? FanHelperProtocol else { return }
        body(p) { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Resumes a continuation exactly once (a reply and a timeout race for it).
    final class Once<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<T, Never>) { continuation = c }
        func resume(_ value: T) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    private func proxy() -> FanHelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: FanHelper.label, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.setCodeSigningRequirement(FanHelper.helperRequirement)
            c.invalidationHandler = { [weak c] in
                Task { @MainActor in
                    if let c, FanControl.shared.connection === c { FanControl.shared.connection = nil }
                }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor in FanControl.shared.lastError = error.localizedDescription }
        } as? FanHelperProtocol
    }
}
