import Foundation

@main struct NotchAIUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-ai-quota-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if condition { passed += 1 } else { failed += 1 }
        }

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
        {"api_key_session":true,"session_cost_usd":0.12,"captured_at":\(now.timeIntervalSince1970 - 60)}
        """
        _ = try write(oldCost, to: "claude-cache/orbit-claude-cost.json", in: root)
        check(available(cache).map(\.usedPercent) == [17, 25], "A new native subscription cache supersedes historical API cost")
        let unidentifiedCache = """
        {"cachedUsageUtilization":{"fetchedAtMs":\((now.timeIntervalSince1970 - 10) * 1000),
          "utilization":{"five_hour":{"utilization":19}}}}
        """
        _ = try write(unidentifiedCache, to: "claude-cache/.claude.json", in: root)
        check(available(cache).isEmpty, "A native cache without account identity cannot supersede an identified source")

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
        test "$*" = "auth status" || exit 1
        case "${ORBIT_FIXTURE_AUTH_MODE:-}" in
            blocked) exec /bin/sleep 10 ;;
            api_key|claude.ai)
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
        let legacyScript = "'" + legacyClaudeScript.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    private static func availableLiveQuota(_ profile: NotchAIProfile) -> Bool {
        if case .available(let quota) = NotchAIUsageReader.read(profile) { return quota.windows.first?.usedPercent == 28 }
        return false
    }

    private static func runShell(_ command: String, input: String, path: String = "/usr/bin:/bin", authMode: String? = nil) throws -> String {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.environment = ["PATH": path]
        if let authMode {
            process.environment?["ANTHROPIC_API_KEY"] = "fake-key"
            process.environment?["ORBIT_FIXTURE_AUTH_MODE"] = authMode
        }
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
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
