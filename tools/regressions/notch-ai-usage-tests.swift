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
