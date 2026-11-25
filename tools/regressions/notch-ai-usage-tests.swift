import Foundation

private func waitForClaudeSignal(_ signal: DispatchSemaphore, timeout: DispatchTime) -> DispatchTimeoutResult {
    signal.wait(timeout: timeout)
}

private final class ClaudeUsageHTTPFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var status = 200
    private static var body = "{}"
    private static var headers: [String: String] = [:]
    private static var request: URLRequest?
    static var lastRequest: URLRequest? { lock.withLock { request } }
    static func set(status: Int, body: String, headers: [String: String] = [:]) {
        lock.withLock { self.status = status; self.body = body; self.headers = headers }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body, headers) = Self.lock.withLock {
            Self.request = request
            return (Self.status, Self.body, Self.headers)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ClaudeUsageReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Date
    private var requests = 0
    private var result: NotchClaudeQuota.Reading
    init(now: Date, result: NotchClaudeQuota.Reading) { time = now; self.result = result }
    var now: Date { lock.withLock { time } }
    var count: Int { lock.withLock { requests } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
    func setReading(_ value: NotchClaudeQuota.Reading) { lock.withLock { result = value } }
    func read(_ folder: URL) async -> NotchClaudeQuota.Reading {
        lock.withLock { requests += 1 }
        try? await Task.sleep(for: .milliseconds(20))
        return lock.withLock { result }
    }
}

private final class GatedClaudePreferences: UserDefaults, @unchecked Sendable {
    let captured = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let gateLock = NSLock()
    private var gated = false

    override func stringArray(forKey key: String) -> [String]? {
        let value = super.stringArray(forKey: key)
        let shouldGate = gateLock.withLock {
            if gated { return false }
            gated = true
            return true
        }
        if shouldGate { captured.signal(); resume.wait() }
        return value
    }
}

@main struct NotchAIUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ai-quota-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if condition { passed += 1 } else { failed += 1 }
        }

        for (used, expected) in [(0.0, NotchAIQuotaLevel.plentiful), (25, .plentiful),
                                 (25.01, .comfortable), (50, .comfortable),
                                 (50.01, .low), (75, .low), (75.01, .critical), (100, .critical)] {
            check(NotchAIQuotaLevel(usedPercent: used) == expected,
                  "Quota color boundary at \(100 - used)% remaining")
        }

        for (seconds, value, unit) in [(540000.0, 6, NotchAIResetCountdown.Unit.days),
                                       (172800, 2, .days), (86400, 1, .days), (86399, 23, .hours),
                                       (2880, 48, .minutes), (3600, 1, .hours), (3599, 59, .minutes), (30, 1, .minutes)] {
            let countdown = NotchAIResetCountdown(resetAt: now.addingTimeInterval(seconds), now: now)
            check(countdown?.value == value && countdown?.unit == unit, "Reset countdown at \(seconds) seconds")
        }
        check(NotchAIResetCountdown(resetAt: nil, now: now) == nil, "Unknown reset times are not invented")
        check(NotchAIResetCountdown(resetAt: now, now: now) == nil, "Expired windows do not show a future countdown")

        check(NotchAIResetCountdown.Unit.days.rawValue == "d" && NotchAIResetCountdown.Unit.hours.rawValue == "h"
              && NotchAIResetCountdown.Unit.minutes.rawValue == "m", "Countdown labels use day, hour, and minute suffixes")
        for seconds in [-1.0, Double.infinity, -Double.infinity, Double.nan] {
            check(NotchAIResetCountdown(resetAt: now.addingTimeInterval(seconds), now: now) == nil,
                  "Past or nonfinite reset time is omitted (\(seconds))")
        }

        let pairWindows = [60, 300, 10080, 43200].map {
            NotchAIQuotaWindow(minutes: $0, usedPercent: 50, resetAt: nil, observedAt: now)
        }
        check(NotchAIQuotaWindow.pairs(pairWindows).map { $0.map(\.minutes) } == [[300, 10080], [60, 43200]],
              "The five-hour and weekly limits stay paired even with shorter and longer custom limits")
        check(NotchAIQuotaWindow.pairs(Array(pairWindows.prefix(1))).map { $0.count } == [1], "A single limit remains visible")
        check(NotchAIQuotaWindow.pairs([]).isEmpty, "An empty window list has no layout rows")

        var savedOptions = NotchAIUsageOptions()
        savedOptions.profiles = [NotchAIProfile(name: "Saved profile", provider: .custom, folder: "/fixture")]
        savedOptions.mode = .used
        savedOptions.period = .weekly
        savedOptions.colorByUsage = false
        let savedOptionsData = try JSONEncoder().encode(savedOptions)
        check(NotchAIUsageOptions.decode(savedOptionsData) == savedOptions, "The bar color preference persists with the selected profiles and display modes")
        var oldOptions = try JSONSerialization.jsonObject(with: savedOptionsData) as! [String: Any]
        oldOptions.removeValue(forKey: "colorByUsage")
        let migratedOptions = NotchAIUsageOptions.decode(try JSONSerialization.data(withJSONObject: oldOptions))
        savedOptions.colorByUsage = true
        check(migratedOptions == savedOptions, "Existing profile settings survive adding the quota color preference")

        let codex = profile(.codex, "codex", in: root)
        check(NotchAIUsageReader.read(codex, now: now) == .missing, "absent Codex folder reports missing")
        let sessions = "codex/sessions/2026/11/23"
        let previous = try event(secondsAgo: 600, limits: [
            "limit_id": "codex",
            "primary": ["used_percent": 12, "window_minutes": 300],
            "secondary": ["used_percent": 13, "window_minutes": 10_080]
        ])
        let latest = try event(secondsAgo: 60, limits: [
            "primary": ["used_percent": 0, "window_minutes": 10_079, "resets_in_seconds": 1_800]
        ])
        let spark = try event(secondsAgo: 5, limits: [
            "limit_id": "codex-spark", "primary": ["used_percent": 90, "window_minutes": 300]
        ])
        let noQuota = try event(secondsAgo: 1, limits: NSNull())
        let firstFile = try write(previous, to: "\(sessions)/rollout-previous.jsonl", in: root)
        _ = try write(String(repeating: "a", count: 530 * 1_024) + "\n" + latest + "\n" + spark + "\n" + noQuota
                      + "\n{\"type\":\"event_msg\"", to: "\(sessions)/rollout-latest.jsonl", in: root)
        // The latest observation is determined by the event, not by a later write to an older session.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(86_400)], ofItemAtPath: firstFile.path)
        let codexWindows = available(codex)
        check(codexWindows.map(\.minutes) == [10_080], "Codex selects newest account snapshot and normalizes legacy window")
        check(codexWindows.first?.usedPercent == 0, "zero usage is preserved")
        check(codexWindows.first?.resetAt == now.addingTimeInterval(1_740), "legacy reset delay uses observation timestamp")

        let otherCodex = profile(.codex, "codex-other", in: root)
        let expiredReset = now.addingTimeInterval(-30)
        let other = try event(secondsAgo: 120, limits: [
            "secondary": ["used_percent": 100, "window_minutes": 299, "resets_at": expiredReset.timeIntervalSince1970]
        ])
        _ = try write(other, to: "codex-other/rollout-other.jsonl", in: root)
        check(available(otherCodex).map(\.minutes) == [300], "direct rollout directory works for another Codex profile")
        check(available(otherCodex).first?.usedPercent == 100, "exhausted quota is preserved")
        check(available(otherCodex).first?.resetAt == expiredReset, "past reset time remains available for expiration handling")

        let claude = profile(.claude, "claude", in: root)
        _ = try write(#"{"rate_limits":{"five_hour":null,"seven_day":{"used_percentage":31}},"captured_at":"2026-08-17T00:00:00Z"}"#,
                      to: "claude/orbit-quota.json", in: root)
        check(available(claude).map(\.minutes) == [10_080] && available(claude).first?.usedPercent == 31,
              "Claude accepts an available weekly window without a five-hour allowance")
        let native = try write(#"{"rate_limits":{"five_hour":{"used_percentage":23.5},"seven_day":{"used_percentage":-1}}}"#,
                               to: "claude/orbit-quota.json", in: root)
        let observedAt = now.addingTimeInterval(-500)
        try FileManager.default.setAttributes([.modificationDate: observedAt], ofItemAtPath: native.path)
        let claudeWindows = available(claude)
        check(claudeWindows.map(\.usedPercent) == [23.5], "one malformed Claude window leaves the valid neighbor intact")
        check(claudeWindows.first?.observedAt == observedAt, "native Claude snapshot without capture time uses file modification time")
        _ = try write(#"{"context_window":{"used_percentage":85}}"#, to: "claude/orbit-quota.json", in: root)
        check(NotchAIUsageReader.read(claude, now: now) == .missing, "Claude context metrics are never reported as quota")

        let cache = profile(.claude, "claude-cache", in: root)
        func writeClaudeCache(age: TimeInterval, account: String, reset: TimeInterval = 600) throws {
            let document: [String: Any] = [
                "oauthAccount": ["accountUuid": "current-account"],
                "cachedUsageUtilization": [
                    "accountUuid": account,
                    "fetchedAtMs": now.addingTimeInterval(-age).timeIntervalSince1970 * 1_000,
                    "utilization": [
                        "five_hour": ["utilization": 17, "resets_at": now.addingTimeInterval(reset).timeIntervalSince1970],
                        "seven_day": ["utilization": 25],
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: document)
            _ = try write(String(decoding: data, as: UTF8.self), to: "claude-cache/.claude.json", in: root)
        }
        try writeClaudeCache(age: 30, account: "current-account")
        check(available(cache).map(\.usedPercent) == [17, 25], "Claude automatically imports the current local cache")
        try writeClaudeCache(age: 30, account: "previous-account")
        check(available(cache).isEmpty, "Claude ignores the previous account’s cache")
        try writeClaudeCache(age: 3_601, account: "current-account")
        check(available(cache).isEmpty, "Claude ignores an old cache")
        try writeClaudeCache(age: 30, account: "current-account", reset: -1)
        check(available(cache).map(\.minutes) == [10_080], "Claude drops a cache window after its reset")

        try writeClaudeCache(age: 20, account: "current-account")
        let oldCost = """
        {"api_key_session":true,"session_cost_usd":0.12,"captured_at":\(now.timeIntervalSince1970 - 60),
          "auth_checked_at":\(now.timeIntervalSince1970 - 60)}
        """
        _ = try write(oldCost, to: "claude-cache/orbit-claude-cost.json", in: root)
        check(available(cache).map(\.usedPercent) == [17, 25], "A new native subscription cache supersedes historical API cost")
        let unidentifiedCache = """
        {"cachedUsageUtilization":{"fetchedAtMs":\((now.timeIntervalSince1970 - 10) * 1000),
          "utilization":{"five_hour":{"utilization":19}}}}
        """
        _ = try write(unidentifiedCache, to: "claude-cache/.claude.json", in: root)
        check(available(cache).isEmpty, "A native cache without account identity cannot supersede an identified source")

        let oldUnverified = """
        {"api_key_session":true,"session_cost_usd":0.43,"captured_at":\(now.timeIntervalSince1970)}
        """
        _ = try write(oldUnverified, to: "claude-cache/orbit-claude-cost.json", in: root)
        check(NotchAIUsageReader.read(cache, now: now) == .missing,
              "A pre-verification cost snapshot cannot assert API-key authentication")

        let bridge = profile(.claude, "status-line's profile", in: root)
        let bridgeFolder = bridge.sourceFolder!
        let originalCommand = "printf 'existing: '; cat # original trailing comment"
        let original: [String: Any] = [
            "statusLine": ["type": "command", "command": originalCommand, "padding": 3],
            "permissions": ["defaultMode": "plan"],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: original)
        let settings = try write(String(decoding: originalData, as: UTF8.self),
                                 to: "status-line's profile/settings.json", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .available, "Claude detects an existing status line")
        try ClaudeStatusLineBridge.setConnected(true, in: bridgeFolder)
        check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .connected, "Claude detects its installed connection")
        let connected = try Data(contentsOf: settings)
        try ClaudeStatusLineBridge.setConnected(true, in: bridgeFolder)
        let repeated = try Data(contentsOf: settings)
        check(repeated == connected, "Connecting twice does not wrap the existing command twice")
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int
        check(mode == 0o600, "Connecting preserves existing settings file permissions")
        let connectedSettings = try JSONSerialization.jsonObject(with: connected) as? [String: Any]
        let connectedStatus = connectedSettings?["statusLine"] as? [String: Any]
        let wrappedCommand = connectedStatus?["command"] as? String ?? ""
        check(connectedStatus?["padding"] as? Int == 3, "Connecting preserves status line padding")
        let fixture = #"{"rate_limits":{"five_hour":{"used_percentage":28}},"unrelated":"Fixture 한글"}"#
        let result = try runShell(wrappedCommand, input: fixture)
        check(result == "existing: " + fixture, "The existing status line still receives the original input and produces the same output")
        let bridgeWindows: [NotchAIQuotaWindow]
        if case .available(let live) = NotchAIUsageReader.read(bridge) { bridgeWindows = live.windows }
        else { bridgeWindows = [] }
        check(bridgeWindows.first?.usedPercent == 28, "The installed status line publishes a readable quota snapshot")
        let apiInput = #"{"session_id":"fixture-api-session","cost":{"total_cost_usd":0.0234},"unrelated":"sensitive fixture"}"#
        let claudeCLI = try write(#"""
        #!/bin/sh
        if test "$*" = "auth status --text"; then
            case "${ORBIT_FIXTURE_AUTH_MODE:-}" in
                console_oauth|console_scopes|subscription_env|subscription_fd) printf '%s\n' 'Profile: Fixture · user_oauth · profile default' ;;
                subscription_token) printf '%s\n' 'OAuth token: CLAUDE_CODE_OAUTH_TOKEN' ;;
                ambiguous_oauth) printf '%s\n' 'Profile: Fixture · unexpected · user_oauth · profile default' ;;
            esac
            exit 0
        fi
        test "$*" = "auth status" || exit 1
        # The auth namespace must match the parent session, even for the default folder.
        test "${CLAUDE_CONFIG_DIR+x}" = "${ORBIT_EXPECT_CONFIG_SET:-}" || exit 1
        test "${CLAUDE_CONFIG_DIR:-}" = "${ORBIT_EXPECT_CONFIG_DIR:-}" || exit 1
        case "${ORBIT_FIXTURE_AUTH_MODE:-}" in
            blocked) exec /bin/sleep 10 ;;
            slow_api)
                /usr/bin/touch "$ORBIT_FIXTURE_AUTH_MARKER"
                /bin/sleep 0.6
                printf '%s\n' '{"loggedIn":true,"authMethod":"api_key"}'
                ;;
            console_oauth|console_scopes|subscription_token|subscription_env|subscription_fd|ambiguous_oauth)
                printf '%s\n' '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}'
                ;;
            other_oauth)
                printf '%s\n' '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"thirdParty"}'
                ;;
            keychain_api)
                test -z "${ANTHROPIC_API_KEY+x}" || exit 1
                printf '%s\n' '{"loggedIn":true,"authMethod":"api_key"}'
                ;;
            api_key|api_key_helper|claude.ai)
                printf '{"loggedIn":true,"authMethod":"%s"}\n' "$ORBIT_FIXTURE_AUTH_MODE"
                ;;
        esac
        """#, to: "claude-fixture-bin/claude", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claudeCLI.path)
        let fixturePath = claudeCLI.deletingLastPathComponent().path + ":/usr/bin:/bin"
        let apiOutput = try runShell(wrappedCommand, input: apiInput, path: fixturePath, authMode: "api_key")
        check(apiOutput == "existing: " + apiInput, "API cost capture preserves the previous status line output")
        let costFile = bridgeFolder.appendingPathComponent("orbit-claude-cost.json")
        let costDocument = try String(contentsOf: costFile, encoding: .utf8)
        check(!costDocument.contains("sensitive fixture") && !costDocument.contains("fake-key"),
              "The session cost snapshot omits prompts and credential values")
        if case .sessionCost(let cost) = NotchAIUsageReader.read(bridge) {
            check(cost.usd == 0.0234, "Verified API-key mode displays the latest Claude session cost")
        } else {
            check(false, "Verified API-key mode displays the latest Claude session cost")
        }
        for mode in ["keychain_api", "api_key_helper", "console_oauth", "console_scopes"] {
            for config in [nil, bridgeFolder.path, root.appendingPathComponent("separate-session-config").path] as [String?] {
                let sessionInput = apiInput.replacingOccurrences(of: "fixture-api-session", with: UUID().uuidString)
                let run = try startShell(wrappedCommand, input: sessionInput, path: fixturePath,
                                         authMode: mode, configDirectory: config)
                _ = run.stdout.fileHandleForReading.readDataToEndOfFile()
                run.process.waitUntilExit()
                let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: costFile)) as? [String: Any]
                check(snapshot?["api_key_session"] as? Bool == true,
                      "Auth inherits the session config namespace (unset, default, or custom)")
            }
        }
        for authMode in ["subscription_token", "subscription_env", "subscription_fd", "ambiguous_oauth"] {
            let input = apiInput.replacingOccurrences(of: "fixture-api-session", with: UUID().uuidString)
            _ = try runShell(wrappedCommand, input: input, path: fixturePath, authMode: authMode)
            let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: costFile)) as? [String: Any]
            check(snapshot?["api_key_session"] as? Bool == false, "Subscription or ambiguous OAuth never asserts API billing (\(authMode))")
        }
        let otherOAuthInput = apiInput.replacingOccurrences(of: "fixture-api-session", with: "other-oauth")
        _ = try runShell(wrappedCommand, input: otherOAuthInput, path: fixturePath, authMode: "other_oauth")
        let otherOAuth = try JSONSerialization.jsonObject(with: Data(contentsOf: costFile)) as? [String: Any]
        check(otherOAuth?["api_key_session"] as? Bool == false, "An unrelated OAuth provider cannot claim a Claude API cost session")
        let v4Command = wrappedCommand.replacingOccurrences(of: "status line v6", with: "status line v4")
        var v4Settings = original
        v4Settings["statusLine"] = ["type": "command", "command": v4Command, "padding": 3]
        try JSONSerialization.data(withJSONObject: v4Settings).write(to: settings, options: .atomic)
        check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .needsUpdate, "The Console OAuth fix upgrades v4 connections")
        try ClaudeStatusLineBridge.setConnected(true, in: bridgeFolder)
        check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .connected, "The v4 connection upgrades without nesting")
        let v3Command = wrappedCommand.replacingOccurrences(of: "status line v6", with: "status line v3")
        var v3Settings = original
        v3Settings["statusLine"] = ["type": "command", "command": v3Command, "padding": 3]
        try JSONSerialization.data(withJSONObject: v3Settings).write(to: settings, options: .atomic)
        check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .needsUpdate, "The auth environment fix upgrades v3 connections")
        try ClaudeStatusLineBridge.setConnected(true, in: bridgeFolder)
        check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .connected, "The v3 connection upgrades without nesting")
        _ = try runShell(wrappedCommand, input: fixture, path: fixturePath, authMode: "api_key")
        check(availableLiveQuota(bridge), "Real subscription quota wins even if an API key is exported")

        let declinedInput = apiInput.replacingOccurrences(of: "fixture-api-session", with: "declined-key")
        _ = try runShell(wrappedCommand, input: declinedInput, path: fixturePath, authMode: "claude.ai")
        check(availableLiveQuota(bridge), "An exported but declined API key does not replace subscription quota with cost")

        let blockedInput = apiInput.replacingOccurrences(of: "fixture-api-session", with: "blocked-auth")
        let started = Date()
        let blockedOutput = try runShell(wrappedCommand, input: blockedInput, path: fixturePath, authMode: "blocked")
        check(Date().timeIntervalSince(started) < 4 && blockedOutput == "existing: " + blockedInput && availableLiveQuota(bridge),
              "A blocked auth probe is bounded and leaves the original output and quota working")
        let marker = root.appendingPathComponent("slow-auth-started")
        let earlier = #"{"session_id":"earlier","cost":{"total_cost_usd":7}}"#
        let later = #"{"session_id":"later","cost":{"total_cost_usd":11}}"#
        let slow = try startShell(wrappedCommand, input: earlier, path: fixturePath, authMode: "slow_api",
                                  marker: marker.path)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(FileManager.default.fileExists(atPath: marker.path))
        _ = try runShell(wrappedCommand, input: later, path: fixturePath, authMode: "api_key")
        slow.process.waitUntilExit()
        let newestCost = NotchAIUsageReader.read(bridge)
        if case .sessionCost(let recent) = newestCost {
            check(recent.usd == 11, "The slow older API session cannot overwrite a newer published estimate")
        } else {
            check(false, "The slow older API session cannot overwrite a newer published estimate")
        }
        let quotaFile = bridgeFolder.appendingPathComponent("orbit-quota.json")
        let savedQuota = try String(contentsOf: quotaFile, encoding: .utf8)
        check(!savedQuota.contains("Fixture") && !savedQuota.contains("unrelated"), "The connection writes only quota data")
        try FileManager.default.removeItem(at: quotaFile)
        try FileManager.default.createDirectory(at: quotaFile, withIntermediateDirectories: false)
        let failedCapture = try runShell(wrappedCommand, input: fixture)
        check(failedCapture == "existing: " + fixture, "A failed quota write leaves the original status line working")
        try ClaudeStatusLineBridge.setConnected(false, in: bridgeFolder)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary
        check(restored == original as NSDictionary, "Disconnect restores the original command and other settings")
        for script in [legacyClaudeScript, intermediateClaudeScript] {
            let legacyScript = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let legacyCommand = "/usr/bin/perl -MJSON::PP -MFile::Temp=tempfile -MFile::Basename=dirname -e "
                + legacyScript + " -- '/older/location/orbit-quota.json' 1 | (\n" + originalCommand + "\n)"
            var legacySettings = original
            legacySettings["statusLine"] = ["type": "command", "command": legacyCommand, "padding": 3]
            try JSONSerialization.data(withJSONObject: legacySettings).write(to: settings, options: .atomic)
            check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .needsUpdate, "Claude detects an earlier bridge after a folder move")
            try ClaudeStatusLineBridge.setConnected(true, in: bridgeFolder)
            check(ClaudeStatusLineBridge.state(in: bridgeFolder) == .connected, "Claude upgrades an earlier bridge without nesting it")
            try ClaudeStatusLineBridge.setConnected(false, in: bridgeFolder)
            let legacyRestored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? NSDictionary
            check(legacyRestored == original as NSDictionary, "Disconnect after an upgrade restores the original status line")
        }
        let fresh = root.appendingPathComponent("new-status-line", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        try ClaudeStatusLineBridge.setConnected(true, in: fresh)
        check(ClaudeStatusLineBridge.state(in: fresh) == .connected, "Claude can connect when settings have no status line")
        try ClaudeStatusLineBridge.setConnected(false, in: fresh)
        let newSettings = try Data(contentsOf: fresh.appendingPathComponent("settings.json"))
        let disconnected = try JSONSerialization.jsonObject(with: newSettings) as? [String: Any]
        check(disconnected?.isEmpty == true, "Disconnect removes the generated status line when there was no previous one")

        let symlinkFolder = root.appendingPathComponent("settings-link", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkFolder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlinkFolder.appendingPathComponent("settings.json"), withDestinationURL: settings)
        check(ClaudeStatusLineBridge.state(in: symlinkFolder) == .unavailable, "Claude does not rewrite a linked settings file")

        let custom = profile(.custom, "custom", in: root)
        _ = try write(#"{"version":1,"observedAt":"2026-08-17T00:00:00Z","windows":[{"minutes":1440,"usedPercent":15.25},{"minutes":300,"usedPercent":true}]}"#,
                      to: "custom/orbit-quota.json", in: root)
        check(available(custom).map(\.minutes) == [1_440], "custom input supports real nonstandard durations and rejects JSON booleans")
        _ = try write(#"{"version":2,"observedAt":"2026-08-17T00:00:00Z","windows":[]}"#, to: "custom/orbit-quota.json", in: root)
        check(NotchAIUsageReader.read(custom, now: now) == .invalid, "unknown custom schema is invalid")
        _ = try write(String(repeating: " ", count: 257 * 1_024), to: "custom/orbit-quota.json", in: root)
        check(NotchAIUsageReader.read(custom, now: now) == .invalid, "oversized snapshot is rejected")
        _ = try write("{", to: "custom/orbit-quota.json", in: root)
        check(NotchAIUsageReader.read(custom, now: now) == .invalid, "incomplete JSON is invalid")

        let cliHome = root.appendingPathComponent("codex-account", isDirectory: true)
        try FileManager.default.createDirectory(at: cliHome, withIntermediateDirectories: false)
        let codexCLI = try write(#"""
        #!/bin/sh
        set -eu
        test "$1" = app-server
        test "${CODEX_HOME##*/}" = codex-account
        IFS= read -r command
        case "$command" in *initialize*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r command
        case "$command" in *initialized*) ;; *) exit 1 ;; esac
        IFS= read -r command
        case "$command" in *account/read*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        IFS= read -r command
        case "$command" in *account/rateLimits/read*) ;; *) exit 1 ;; esac
        printf '%s\n' '{"method":"account/rateLimits/updated","params":{}}'
        printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","secondary":{"usedPercent":43.5,"windowDurationMins":10080}}}}}'
        """#, to: "bin/codex", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexCLI.path)
        if case .available(let quota) = NotchCodexQuota.read(executable: codexCLI, profile: cliHome, now: now) {
            check(quota.windows.map(\.minutes) == [10_080] && quota.windows.first?.usedPercent == 43.5,
                  "The official RPC handshake returns Codex quota without a session log")
        } else {
            check(false, "The official RPC handshake returns Codex quota without a session log")
        }
        let apiCodex = try write(#"""
        #!/bin/sh
        IFS= read -r command
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r command
        IFS= read -r command
        printf '%s\n' '{"id":2,"result":{"account":{"type":"apiKey"}}}'
        """#, to: "bin/api-codex", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: apiCodex.path)
        check(NotchCodexQuota.read(executable: apiCodex, profile: cliHome, now: now) == .missing,
              "An API-key Codex account does not reuse historical subscription usage")
        check(NotchCodexQuota.read(executable: URL(fileURLWithPath: "/usr/bin/false"), profile: cliHome, now: now) == nil,
              "A closed Codex process falls back without killing Orbit")

        let rejected = try write(#"""
        #!/bin/sh
        IFS= read -r command
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r command
        IFS= read -r command
        printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"}}}'
        IFS= read -r command
        printf '%s\n' '{"id":3,"error":{"code":-32000,"message":"Unavailable"}}'
        """#, to: "bin/rejected-codex", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rejected.path)
        check(NotchCodexQuota.read(executable: rejected, profile: cliHome, now: now) == .missing,
              "An authenticated account RPC failure never falls back to an unidentified rollout")

        let grok = profile(.codexBar, "codexbar", in: root, key: "Grok")
        let antigravity = profile(.codexBar, "codexbar", in: root, key: "antigravity")
        let export = """
        [
          {"provider":"grok","usage":{"updatedAt":"2026-08-17T00:00:00Z","primary":
            {"usedPercent":42,"windowMinutes":10080},"providerCost":{"balance":1.3}}},
          {"provider":"antigravity","usage":{"updatedAt":"2026-08-17T00:00:00Z","primary":
            {"usedPercent":90,"windowMinutes":10080},"extraRateWindows":[
              {"id":"antigravity-quota-summary-gemini","window":{"usedPercent":18,"windowMinutes":300}},
              {"id":"antigravity-quota-summary-claude","window":{"usedPercent":24,"windowMinutes":300}},
              {"id":"antigravity-quota-summary-unknown","usageKnown":false,
                "window":{"usedPercent":100,"windowMinutes":300}}
            ]}}
        ]
        """
        _ = try write(export, to: "codexbar/codexbar-usage.json", in: root)
        check(available(grok).map(\.usedPercent) == [42], "CodexBar provider selection ignores other providers and money")
        check(available(antigravity).map(\.usedPercent) == [24], "Antigravity shows the most constrained known quota for a period")
        _ = try write(#"{"provider":"grok","usage":{"updatedAt":"2026-08-17T00:00:00Z","providerCost":{"balance":10}}}"#,
                      to: "codexbar/codexbar-usage.json", in: root)
        check(NotchAIUsageReader.read(grok, now: now) == .missing, "Grok money balance alone cannot produce a quota percentage")

        let symlink = profile(.custom, "symlink", in: root)
        let symlinkDirectory = root.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory.appendingPathComponent("orbit-quota.json"),
                                                withDestinationURL: native)
        check(NotchAIUsageReader.read(symlink, now: now) == .unreadable, "snapshot reader does not follow a symlink")

        let profileStore = try JSONEncoder().encode(NotchAIProfile.builtIns)
        let readBack = try JSONDecoder().decode([NotchAIProfile].self, from: profileStore)
        check(readBack == NotchAIProfile.builtIns && Set(readBack.map(\.id)).count == 2,
              "default profile identities persist independently")

        let suite = "dev.orbit.claude-tests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let automatic = profile(.claude, "automatic", in: root)
        let autoFolder = automatic.sourceFolder!
        let autoSettings = try write(String(decoding: originalData, as: UTF8.self), to: "automatic/settings.json", in: root)
        ClaudeStatusLineBridge.automaticallyConnect([automatic, automatic], preferences: preferences)
        check(ClaudeStatusLineBridge.state(in: autoFolder) == .connected, "Enabling AI usage connects an existing Claude status line automatically")
        let automaticData = try Data(contentsOf: autoSettings)
        ClaudeStatusLineBridge.automaticallyConnect([automatic], preferences: preferences)
        check(try Data(contentsOf: autoSettings) == automaticData, "Repeated preparation leaves an installed connection unchanged")
        let oldBridge = String(decoding: automaticData, as: UTF8.self).replacingOccurrences(of: "status line v6", with: "status line v5")
        try Data(oldBridge.utf8).write(to: autoSettings, options: .atomic)
        ClaudeStatusLineBridge.automaticallyConnect([automatic], preferences: preferences)
        check(try Data(contentsOf: autoSettings) == automaticData, "Automatic preparation upgrades older bridges without nesting the existing command")
        let automaticDocument = try JSONSerialization.jsonObject(with: automaticData) as! [String: Any]
        let automaticCommand = (automaticDocument["statusLine"] as! [String: Any])["command"] as! String
        check(try runShell(automaticCommand, input: fixture) == "existing: " + fixture,
              "Automatic connection preserves the original status line output and input")
        let noReader = profile(.claude, "status-without-stdin", in: root)
        let noReaderFile = try write(#"{"statusLine":{"type":"command","command":"printf 'fixed status'"}}"#,
                                     to: "status-without-stdin/settings.json", in: root)
        ClaudeStatusLineBridge.automaticallyConnect([noReader], preferences: preferences)
        let noReaderSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: noReaderFile)) as! [String: Any]
        let noReaderCommand = (noReaderSettings["statusLine"] as! [String: Any])["command"] as! String
        let largeInput = String(fixture.dropLast()) + ",\"unrelated\":\"" + String(repeating: "x", count: 128 * 1024) + "\"}"
        check(try runShell(noReaderCommand, input: String(largeInput)) == "fixed status" && availableLiveQuota(noReader),
              "A status line that exits without reading stdin cannot interrupt Orbit's quota capture")
        try ClaudeStatusLineBridge.setConnected(false, in: autoFolder, preferences: preferences)
        ClaudeStatusLineBridge.automaticallyConnect([automatic], preferences: preferences)
        check(ClaudeStatusLineBridge.state(in: autoFolder) == .available, "A manual disconnect survives preparation and relaunch")
        try ClaudeStatusLineBridge.setConnected(true, in: autoFolder, preferences: preferences)
        ClaudeStatusLineBridge.automaticallyConnect([automatic], preferences: preferences)
        check(ClaudeStatusLineBridge.state(in: autoFolder) == .connected, "Manual reconnect clears the automatic-connection opt-out")
        let absent = profile(.claude, "not-installed", in: root)
        var hidden = profile(.claude, "hidden", in: root)
        hidden.isVisible = false
        let hiddenFile = try write("{}", to: "hidden/settings.json", in: root)
        let invalidAuto = profile(.claude, "invalid-auto", in: root)
        let invalidFile = try write("{", to: "invalid-auto/settings.json", in: root)
        ClaudeStatusLineBridge.automaticallyConnect([absent, hidden, invalidAuto], preferences: preferences)
        check(!FileManager.default.fileExists(atPath: absent.sourceFolder!.path), "Automatic connection does not create a missing Claude folder")
        check(try String(contentsOf: hiddenFile, encoding: .utf8) == "{}" && String(contentsOf: invalidFile, encoding: .utf8) == "{",
              "Hidden profiles and malformed settings stay untouched")

        let credentialJSON = """
        {"claudeAiOauth":{"accessToken":"fixture-token","expiresAt":\((now.timeIntervalSince1970 + 3600) * 1000),
        "scopes":["user:profile","user:inference"],"subscriptionType":"max"}}
        """
        let credentials = NotchClaudeQuota.Credentials.decode(Data(credentialJSON.utf8), now: now)!
        check(credentials.subscriptionType == "max", "An existing unexpired subscription login can query shared quota")
        for invalid in [credentialJSON.replacingOccurrences(of: "max", with: "api"),
                        credentialJSON.replacingOccurrences(of: "user:profile", with: "other:scope"),
                        credentialJSON.replacingOccurrences(of: "fixture-token", with: ""),
                        credentialJSON.replacingOccurrences(of: "fixture-token", with: "bad token")] {
            check(NotchClaudeQuota.Credentials.decode(Data(invalid.utf8), now: now) == nil,
                  "Console, insufficient-scope, or malformed credentials cannot assert subscription quota")
        }
        check(NotchClaudeQuota.Credentials.decode(Data(credentialJSON.utf8), now: now.addingTimeInterval(3601)) == nil,
              "Expired credentials are left for Claude to refresh")
        let credentialFile = try write(credentialJSON, to: "credential-profile/.credentials.json", in: root)
        let credentialProfile = profile(.claude, "credential-profile", in: root)
        let credentialSource = NotchClaudeQuota.source(for: credentialProfile, environment: [:])!
        check(NotchClaudeQuota.credentials(from: credentialSource, now: now, keychain: { _ in .missing })?.accessToken == "fixture-token",
              "Custom profile credentials come from that profile")
        let currentAccount = Data(credentialJSON.replacingOccurrences(of: "fixture-token", with: "current-account-token").utf8)
        check(NotchClaudeQuota.credentials(from: credentialSource, now: now, keychain: { _ in .document(currentAccount) })?.accessToken == "current-account-token",
              "Current Keychain account wins over an older still-valid plaintext login")
        for document in ["{}", "{", credentialJSON.replacingOccurrences(of: "max", with: "api")] {
            check(NotchClaudeQuota.credentials(from: credentialSource, now: now, keychain: { _ in .document(Data(document.utf8)) }) == nil,
                  "A present unusable Keychain document cannot select the plaintext account")
        }
        check(NotchClaudeQuota.credentials(from: credentialSource, now: now.addingTimeInterval(3601), keychain: { _ in .document(currentAccount) }) == nil,
              "An expired Keychain account does not fall back to a different plaintext account")
        check(NotchClaudeQuota.credentials(from: credentialSource, now: now, keychain: { _ in .unavailable }) == nil,
              "An inaccessible Keychain item fails closed without switching accounts")
        let linkedCredentials = root.appendingPathComponent("linked-credentials")
        try FileManager.default.createDirectory(at: linkedCredentials, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedCredentials.appendingPathComponent(".credentials.json"), withDestinationURL: credentialFile)
        let linkedSource = NotchClaudeQuota.source(for: profile(.claude, "linked-credentials", in: root), environment: [:])!
        check(NotchClaudeQuota.credentials(from: linkedSource, now: now, keychain: { _ in .missing }) == nil,
              "A replaced credential symlink cannot select credentials from another profile")
        let home = root.appendingPathComponent("home")
        check(NotchClaudeQuota.keychainService(configDirectory: nil) == "Claude Code-credentials",
              "The default profile selects Claude Code's existing Keychain service")
        check(NotchClaudeQuota.keychainService(configDirectory: autoFolder.path) != "Claude Code-credentials"
              && NotchClaudeQuota.keychainService(configDirectory: autoFolder.path) != NotchClaudeQuota.keychainService(configDirectory: root.path),
              "Separate profile folders never read the global or another profile's Keychain item")
        let defaultProfile = NotchAIProfile(name: "Default Claude", provider: .claude)
        let defaultSource = NotchClaudeQuota.source(for: defaultProfile, environment: [:], home: home)!
        let explicitDefault = NotchClaudeQuota.source(for: defaultProfile,
            environment: ["CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path], home: home)!
        check(defaultSource.folder == explicitDefault.folder && defaultSource != explicitDefault
              && defaultSource.keychainService != explicitDefault.keychainService,
              "An explicitly configured default folder keeps its distinct Claude Keychain and cache namespace")
        check(NotchClaudeQuota.keychainService(configDirectory: root.path + "/") != NotchClaudeQuota.keychainService(configDirectory: root.path),
              "Credential namespace hashing preserves the configured trailing slash")
        check(NotchClaudeQuota.keychainService(configDirectory: "/fixture/caf\u{e9}") == NotchClaudeQuota.keychainService(configDirectory: "/fixture/cafe\u{301}"),
              "Credential namespace hashing uses Claude's NFC normalization")
        let securePath = root.appendingPathComponent("separate-credential-store").path
        let secureSource = NotchClaudeQuota.source(for: defaultProfile,
            environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": securePath], home: home)!
        check(secureSource.folder == defaultSource.folder && secureSource.credentialFolder.path == securePath
              && secureSource.keychainService == NotchClaudeQuota.keychainService(configDirectory: securePath),
              "Secure storage override selects both the credential file folder and Keychain namespace")
        let emptySecure = NotchClaudeQuota.source(for: defaultProfile,
            environment: ["CLAUDE_CONFIG_DIR": autoFolder.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""], home: home)!
        check(emptySecure.folder == autoFolder && emptySecure.credentialFolder == defaultSource.credentialFolder
              && emptySecure.keychainService == defaultSource.keychainService,
              "An explicitly empty secure override selects default credentials while keeping the profile data folder")
        let independent = NotchClaudeQuota.source(for: credentialProfile,
            environment: ["CLAUDE_CONFIG_DIR": autoFolder.path, "CLAUDE_SECURESTORAGE_CONFIG_DIR": securePath], home: home)!
        check(independent == credentialSource, "Custom profiles do not inherit another profile's ambient credential overrides")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeUsageHTTPFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ClaudeUsageHTTPFixture.set(status: 200, body: #"{"five_hour":{"utilization":41,"resets_at":1795003600},"seven_day":{"utilization":12}}"#)
        let live = await NotchClaudeQuota.fetch(credentials, session: session, now: now)
        if case .available(let quota) = live.result {
            check(quota.windows.map(\.usedPercent) == [41, 12] && quota.windows.allSatisfy { $0.observedAt == now },
                  "Desktop usage reads both account limits without a status line invocation")
        } else { check(false, "Desktop usage reads both account limits without a status line invocation") }
        let request = ClaudeUsageHTTPFixture.lastRequest
        check(request?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage"
              && request?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
              && request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20",
              "The usage request sends the subscription bearer only to the fixed Anthropic endpoint")
        check(request?.httpMethod == "GET" && request?.httpBody == nil,
              "Quota refresh only reads usage metadata without submitting a model prompt")
        for status in [401, 403, 500, 302] {
            ClaudeUsageHTTPFixture.set(status: status, body: "{}")
            let failure = await NotchClaudeQuota.fetch(credentials, session: session, now: now)
            check(failure.result == (status == 401 || status == 403 ? .missing : nil),
                  "HTTP \(status) leaves local sources available without asserting fresh quota")
        }
        ClaudeUsageHTTPFixture.set(status: 200, body: "{")
        check(await NotchClaudeQuota.fetch(credentials, session: session).result == nil, "Invalid usage responses fall back to local sources")
        ClaudeUsageHTTPFixture.set(status: 200, body: #"{"five_hour":{"utilization":true},"seven_day":{"utilization":37}}"#)
        let partial = await NotchClaudeQuota.fetch(credentials, session: session, now: now)
        if case .available(let quota) = partial.result {
            check(quota.windows.map(\.usedPercent) == [37], "A malformed live quota window leaves its valid neighbor readable")
        } else { check(false, "A malformed live quota window leaves its valid neighbor readable") }
        ClaudeUsageHTTPFixture.set(status: 429, body: "{}", headers: ["Retry-After": "600"])
        let limited = await NotchClaudeQuota.fetch(credentials, session: session)
        check(limited.result == nil && limited.retryAfter == 600, "Anthropic rate limits back off instead of polling every minute")

        let probe = ClaudeUsageReadProbe(now: now, result: live)
        let service = NotchAIUsageService(claudeRead: { await probe.read($0.folder) }, clock: { probe.now })
        async let first = service.read(automatic)
        async let second = service.read(automatic)
        _ = await (first, second)
        _ = await service.read(automatic)
        check(probe.count == 1, "Concurrent card reads and repeated refreshes share one subscription request")
        probe.advance(59)
        _ = await service.read(automatic)
        check(probe.count == 1, "Shared quota stays cached until one minute has elapsed")
        probe.advance(1)
        _ = await service.read(automatic)
        check(probe.count == 2, "Shared quota is queried again exactly one minute after the last read")
        _ = await service.read(hidden)
        check(probe.count == 3, "Separate source folders do not reuse another account's cached quota")
        let fallbackService = NotchAIUsageService(claudeRead: { _ in .init() })
        check(await fallbackService.read(automatic) == NotchAIUsageReader.read(automatic),
              "Unavailable subscription login keeps the existing status line source working")

        let desktopOnly = profile(.claude, "desktop-only", in: root)
        let backoffProbe = ClaudeUsageReadProbe(now: now, result: live)
        let backoffService = NotchAIUsageService(claudeRead: { await backoffProbe.read($0.folder) }, clock: { backoffProbe.now })
        let originalQuota = await backoffService.read(desktopOnly)
        backoffProbe.advance(60)
        backoffProbe.setReading(limited)
        check(await backoffService.read(desktopOnly) == originalQuota,
              "A desktop-only quota keeps its original observation during rate-limit backoff")
        backoffProbe.advance(599)
        check(await backoffService.read(desktopOnly) == originalQuota && backoffProbe.count == 2,
              "Backoff preserves a valid quota without issuing extra requests")
        var changedAccount = limited
        changedAccount.credentialID = "different-account"
        backoffProbe.setReading(changedAccount)
        backoffProbe.advance(1)
        check(await backoffService.read(desktopOnly) == .missing,
              "A credential change cannot reuse the previous account's quota during backoff")
        let authProbe = ClaudeUsageReadProbe(now: now, result: live)
        let authService = NotchAIUsageService(claudeRead: { await authProbe.read($0.folder) }, clock: { authProbe.now })
        _ = await authService.read(desktopOnly)
        ClaudeUsageHTTPFixture.set(status: 401, body: "{}")
        authProbe.setReading(await NotchClaudeQuota.fetch(credentials, session: session, now: now))
        authProbe.advance(60)
        check(await authService.read(desktopOnly) == .missing, "An authentication failure invalidates the retained subscription snapshot")
        let expiryProbe = ClaudeUsageReadProbe(now: now, result: live)
        let expiryService = NotchAIUsageService(claudeRead: { await expiryProbe.read($0.folder) }, clock: { expiryProbe.now })
        _ = await expiryService.read(desktopOnly)
        expiryProbe.setReading(limited)
        expiryProbe.advance(3600)
        if case .available(let quota) = await expiryService.read(desktopOnly) {
            check(quota.windows.map(\.minutes) == [10080], "Retained quota drops expired windows instead of inventing a fresh observation")
        } else { check(false, "Retained quota drops expired windows instead of inventing a fresh observation") }

        let apiProfile = profile(.claude, "active-api-session", in: root)
        let currentCost = """
        {"api_key_session":true,"session_cost_usd":0.42,"captured_at":\(now.timeIntervalSince1970),
        "auth_checked_at":\(now.timeIntervalSince1970)}
        """
        _ = try write(currentCost, to: "active-api-session/orbit-claude-cost.json", in: root)
        let costProbe = ClaudeUsageReadProbe(now: now, result: live)
        let costService = NotchAIUsageService(claudeRead: { await costProbe.read($0.folder) }, clock: { costProbe.now })
        check(await costService.read(apiProfile) == .sessionCost(.init(usd: 0.42, observedAt: now)) && costProbe.count == 0,
              "A recently verified active API session keeps its cost display despite a stored subscription login")
        costProbe.advance(121)
        check(await costService.read(apiProfile) == live.result && costProbe.count == 1,
              "Historical API session cost cannot hide current desktop subscription quota")

        let raceSuite = "dev.orbit.claude-race.\(UUID())"
        let racePreferences = GatedClaudePreferences(suiteName: raceSuite)!
        defer { racePreferences.removePersistentDomain(forName: raceSuite) }
        let racing = profile(.claude, "disconnect-race", in: root)
        _ = try write("{}", to: "disconnect-race/settings.json", in: root)
        try ClaudeStatusLineBridge.setConnected(true, in: racing.sourceFolder!)
        let automaticRace = Task.detached { ClaudeStatusLineBridge.automaticallyConnect([racing], preferences: racePreferences) }
        let capturedBeforeDisconnect = await Task.detached { waitForClaudeSignal(racePreferences.captured, timeout: .now() + 5) }.value
        precondition(capturedBeforeDisconnect == .success)
        let disconnectFinished = DispatchSemaphore(value: 0)
        let manualRace = Task.detached {
            defer { disconnectFinished.signal() }
            try! ClaudeStatusLineBridge.setConnected(false, in: racing.sourceFolder!, preferences: racePreferences)
        }
        _ = await Task.detached { waitForClaudeSignal(disconnectFinished, timeout: .now() + 1) }.value
        racePreferences.resume.signal()
        await automaticRace.value
        await manualRace.value
        check(ClaudeStatusLineBridge.state(in: racing.sourceFolder!) == .available,
              "A concurrent automatic preparation cannot undo a manual disconnect")
        ClaudeStatusLineBridge.automaticallyConnect([racing], preferences: racePreferences)
        check(ClaudeStatusLineBridge.state(in: racing.sourceFolder!) == .available,
              "The concurrent disconnect persists its automatic-connection opt-out")

        print("\(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }

    private static func available(_ profile: NotchAIProfile) -> [NotchAIQuotaWindow] {
        guard case let .available(snapshot) = NotchAIUsageReader.read(profile, now: now) else { return [] }
        return snapshot.windows
    }

    private static let legacyClaudeScript = #"""
        use strict;
        use warnings;
        binmode STDIN;
        binmode STDOUT;
        local $/;
        my $input = <STDIN> // '';
        my ($target, $forward) = @ARGV;
        eval {
            my $data = decode_json($input);
            if (ref($data) eq 'HASH' && ref($data->{rate_limits}) eq 'HASH') {
                my %windows;
                for my $key ('five_hour', 'seven_day') {
                    my $window = $data->{rate_limits}->{$key};
                    next unless ref($window) eq 'HASH' && defined $window->{used_percentage};
                    $windows{$key} = { used_percentage => $window->{used_percentage}, resets_at => $window->{resets_at} };
                }
                if (%windows) {
                    my ($file, $temp) = tempfile('.orbit-quota-XXXXXXXX', DIR => dirname($target), UNLINK => 1);
                    print {$file} encode_json({ captured_at => time, rate_limits => \%windows }) or die $!;
                    close $file or die $!;
                    rename($temp, $target) or die $!;
                }
            }
        };
        print $input if $forward;
        """#

    private static let intermediateClaudeScript = #"""
        use strict;
        use warnings;
        use Time::HiRes qw(time);
        binmode STDIN;
        binmode STDOUT;
        local $/;
        my $input = <STDIN> // '';
        my ($target, $forward) = @ARGV;
        eval {
            my $data = decode_json($input);
            if (ref($data) eq 'HASH') {
                my %snapshot = (captured_at => time);
                my %windows;
                if (ref($data->{rate_limits}) eq 'HASH') {
                    for my $key ('five_hour', 'seven_day') {
                        my $window = $data->{rate_limits}->{$key};
                        next unless ref($window) eq 'HASH' && defined $window->{used_percentage};
                        $windows{$key} = { used_percentage => $window->{used_percentage}, resets_at => $window->{resets_at} };
                    }
                }
                my $api = $ENV{ANTHROPIC_API_KEY};
                if (%windows && !$api) {
                    $snapshot{rate_limits} = \%windows;
                } elsif (ref($data->{cost}) eq 'HASH' && defined $data->{cost}->{total_cost_usd}) {
                    $snapshot{session_cost_usd} = $data->{cost}->{total_cost_usd};
                    $snapshot{api_key_session} = $api ? JSON::PP::true : JSON::PP::false;
                    $target = dirname($target) . '/orbit-claude-cost.json';
                }
                if (keys(%snapshot) > 1) {
                    my ($file, $temp) = tempfile('.orbit-quota-XXXXXXXX', DIR => dirname($target), UNLINK => 1);
                    print {$file} encode_json(\%snapshot) or die $!;
                    close $file or die $!;
                    rename($temp, $target) or die $!;
                }
            }
        };
        print $input if $forward;
        """#

    private static func availableLiveQuota(_ profile: NotchAIProfile) -> Bool {
        if case .available(let quota) = NotchAIUsageReader.read(profile) { return quota.windows.first?.usedPercent == 28 }
        return false
    }

    private static func runShell(_ command: String, input: String, path: String = "/usr/bin:/bin", authMode: String? = nil) throws -> String {
        let run = try startShell(command, input: input, path: path, authMode: authMode)
        let data = run.stdout.fileHandleForReading.readDataToEndOfFile()
        run.process.waitUntilExit()
        precondition(run.process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    private static func startShell(_ command: String, input: String, path: String, authMode: String?,
                                   marker: String? = nil, configDirectory: String? = nil) throws -> (process: Process, stdout: Pipe) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.environment = ["PATH": path]
        if let configDirectory {
            process.environment?["CLAUDE_CONFIG_DIR"] = configDirectory
            process.environment?["ORBIT_EXPECT_CONFIG_SET"] = "x"
            process.environment?["ORBIT_EXPECT_CONFIG_DIR"] = configDirectory
        }
        if let authMode {
            if authMode != "keychain_api" { process.environment?["ANTHROPIC_API_KEY"] = "fake-key" }
            process.environment?["ORBIT_FIXTURE_AUTH_MODE"] = authMode
            if authMode == "console_scopes" { process.environment?["CLAUDE_CODE_OAUTH_SCOPES"] = "user:inference" }
            if authMode == "subscription_env" { process.environment?["CLAUDE_CODE_OAUTH_TOKEN"] = "fixture-only-token" }
            if authMode == "subscription_fd" { process.environment?["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"] = "9" }
        }
        if let marker { process.environment?["ORBIT_FIXTURE_AUTH_MARKER"] = marker }
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        return (process, stdout)
    }

    private static func profile(_ provider: NotchAIProvider, _ directory: String, in root: URL,
                                key: String = "") -> NotchAIProfile {
        NotchAIProfile(name: directory, provider: provider, folder: root.appendingPathComponent(directory).path, providerKey: key)
    }

    private static func event(secondsAgo: TimeInterval, limits: Any) throws -> String {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
        let line: [String: Any] = [
            "timestamp": stamp, "type": "event_msg",
            "payload": ["type": "token_count", "rate_limits": limits]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
    }

    private static func write(_ value: String, to path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
