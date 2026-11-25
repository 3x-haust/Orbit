import CoreFoundation
import Darwin
import Foundation

struct NotchAIUsageOptions: Codable, Equatable {
    var profiles = NotchAIProfile.builtIns
    var mode: NotchAIUsageMode = .remaining
    var period: NotchAIUsagePeriod = .all
    var colorByUsage = true

    private enum CodingKeys: String, CodingKey { case profiles, mode, period, colorByUsage }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try values.decode([NotchAIProfile].self, forKey: .profiles)
        mode = try values.decode(NotchAIUsageMode.self, forKey: .mode)
        period = try values.decode(NotchAIUsagePeriod.self, forKey: .period)
        colorByUsage = try values.decodeIfPresent(Bool.self, forKey: .colorByUsage) ?? true
    }

    static func decode(_ data: Data) -> Self {
        guard let options = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var seen = Set<UUID>()
        var result = options
        result.profiles = options.profiles.filter { seen.insert($0.id).inserted }
        return result
    }
}

enum NotchAIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, custom, codexBar

    var id: Self { self }

    fileprivate var defaultFolder: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings: (environment: String, directory: String)
        switch self {
        case .codex: settings = ("CODEX_HOME", ".codex")
        case .claude: settings = ("CLAUDE_CONFIG_DIR", ".claude")
        case .custom, .codexBar: return nil
        }
        if let override = ProcessInfo.processInfo.environment[settings.environment],
           let url = NotchAIProfile.folderURL(override) {
            return url
        }
        return home.appendingPathComponent(settings.directory, isDirectory: true)
    }
}

struct NotchAIProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var provider: NotchAIProvider
    var folder: String = ""
    var providerKey: String = ""
    var isVisible: Bool = true

    static let builtIns = [
        Self(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), name: "Codex", provider: .codex),
        Self(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)), name: "Claude", provider: .claude)
    ]

    var sourceFolder: URL? {
        folder.isEmpty ? provider.defaultFolder : Self.folderURL(folder)
    }

    fileprivate static func folderURL(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}

enum NotchAIUsageMode: String, Codable, CaseIterable, Sendable {
    case used, remaining
}

enum NotchAIUsagePeriod: String, Codable, CaseIterable, Sendable {
    case fiveHours, weekly, all
}

/// Color always follows remaining allowance, independent of the displayed percentage mode.
enum NotchAIQuotaLevel: Equatable {
    case plentiful, comfortable, low, critical

    init(usedPercent: Double) {
        let remaining = 100 - usedPercent
        self = remaining >= 75 ? .plentiful : remaining >= 50 ? .comfortable : remaining >= 25 ? .low : .critical
    }
}

struct NotchAIResetCountdown: Equatable {
    enum Unit: String { case days = "d", hours = "h", minutes = "m" }
    let value: Int
    let unit: Unit

    init?(resetAt: Date?, now: Date) {
        guard let resetAt else { return nil }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0 else { return nil }
        if seconds >= 86400 {
            unit = .days
            value = Int(seconds / 86400)
        } else if seconds >= 3600 {
            unit = .hours
            value = Int(seconds / 3600)
        } else {
            unit = .minutes
            value = max(1, Int(seconds / 60))
        }
    }
}

struct NotchAIQuotaWindow: Identifiable, Equatable, Sendable {
    let minutes: Int
    let usedPercent: Double
    let resetAt: Date?
    let observedAt: Date

    var id: Int { minutes }

    static func pairs(_ windows: [Self]) -> [[Self]] {
        var remaining = windows
        var rows: [[Self]] = []
        if let short = remaining.first(where: { $0.minutes == 300 }),
           let weekly = remaining.first(where: { $0.minutes == 10080 }) {
            rows.append([short, weekly])
            remaining.removeAll { $0.minutes == 300 || $0.minutes == 10080 }
        }
        for index in stride(from: 0, to: remaining.count, by: 2) {
            rows.append(Array(remaining[index..<min(index + 2, remaining.count)]))
        }
        return rows
    }
}

struct NotchAIQuotaSnapshot: Equatable, Sendable {
    let windows: [NotchAIQuotaWindow]
}

struct NotchAISessionCost: Equatable, Sendable {
    let usd: Double
    let observedAt: Date
}

enum NotchAIUsageResult: Equatable, Sendable {
    case available(NotchAIQuotaSnapshot)
    case sessionCost(NotchAISessionCost)
    case missing
    case unreadable
    case invalid
}

/// Reads quota snapshots from provider-specific artifacts. Runs off the main actor.
enum NotchAIUsageReader {
    private static let snapshotBytes = 256 * 1024
    private static let codexTailBytes = 512 * 1024
    private static let codexEntryLimit = 8192
    private static let codexFileLimit = 32
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let rateLimitsMarker = Data("\"rate_limits\"".utf8)
    private typealias JSON = [String: Any]

    static func read(_ profile: NotchAIProfile, now: Date = .now) -> NotchAIUsageResult {
        guard let folder = profile.sourceFolder else { return .missing }
        let dates = Dates(now: now)
        do {
            switch profile.provider {
            case .codex:
                return try codexSnapshot(in: folder, dates: dates)
            case .claude:
                return try claudeUsage(in: folder, dates: dates)
            case .custom:
                let (data, _) = try snapshotFile("orbit-quota.json", in: folder)
                return try customSnapshot(data, dates: dates)
            case .codexBar:
                let key = profile.providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty else { return .missing }
                let (data, _) = try snapshotFile("codexbar-usage.json", in: folder)
                return try codexBarSnapshot(data, provider: key, dates: dates)
            }
        } catch SourceError.invalid {
            return .invalid
        } catch {
            return isMissing(error) ? .missing : .unreadable
        }
    }

    static func codexAccountSnapshot(_ payload: [String: Any], now: Date) -> NotchAIUsageResult {
        let buckets = payload["rateLimitsByLimitId"] as? JSON
        let limits = (buckets?["codex"] as? JSON) ?? (payload["rateLimits"] as? JSON)
        guard let limits, isCodexAccountLimit(limits["limitId"]) else { return .missing }
        let dates = Dates(now: now)
        return windows(["primary", "secondary"].map { key in
            let row = limits[key] as? JSON
            return window(row, minutes: codexMinutes(row?["windowDurationMins"]), usedKey: "usedPercent",
                          resetKey: "resetsAt", observed: now, dates: dates)
        })
    }

    static func claudeAccountSnapshot(_ payload: [String: Any], now: Date) -> NotchAIUsageResult {
        let dates = Dates(now: now)
        return windows([(key: "five_hour", minutes: 300), (key: "seven_day", minutes: 10_080)].map { period in
            window(payload[period.key], minutes: period.minutes, usedKey: "utilization", resetKey: "resets_at",
                   observed: now, dates: dates)
        })
    }

    private static func claudeUsage(in folder: URL, dates: Dates) throws -> NotchAIUsageResult {
        var capture: NotchAIUsageResult = .missing
        var captureError: Error?
        do {
            let (data, modified) = try snapshotFile("orbit-quota.json", in: folder)
            let document = try object(data)
            capture = claudeSnapshot(document, modified: modified, dates: dates)
        } catch {
            if !isMissing(error) { captureError = error }
        }

        var quota: NotchAIQuotaSnapshot?
        if case .available(let direct) = capture { quota = direct }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let standard = home.appendingPathComponent(".claude", isDirectory: true)
        let cacheFolders = folder.standardizedFileURL.path == standard.standardizedFileURL.path ? [folder, home] : [folder]
        for location in cacheFolders {
            guard let (data, _) = try? snapshotFile(".claude.json", in: location, maxBytes: 2 * 1024 * 1024),
                  let state = try? object(data),
                  let cached = claudeCache(state, dates: dates),
                  let time = cached.windows.first?.observedAt else { continue }
            if quota?.windows.first.map({ time > $0.observedAt }) ?? true { quota = cached }
        }
        if let (data, _) = try? snapshotFile("orbit-claude-cost.json", in: folder),
           let document = try? object(data),
           document["api_key_session"] as? Bool == true,
           let usd = number(document["session_cost_usd"]), usd >= 0,
           let observed = dates.observation(document["captured_at"]),
           let verified = dates.observation(document["auth_checked_at"]),
           abs(verified.timeIntervalSince(observed)) <= 65,
           quota?.windows.first.map({ observed > $0.observedAt }) ?? true {
            return .sessionCost(.init(usd: usd, observedAt: observed))
        }
        if let quota { return .available(quota) }
        if let captureError { throw captureError }
        return capture
    }

    private static func claudeCache(_ state: JSON, dates: Dates) -> NotchAIQuotaSnapshot? {
        guard let cache = state["cachedUsageUtilization"] as? JSON,
              let timestamp = number(cache["fetchedAtMs"]),
              let observed = dates.observation(timestamp / 1_000),
              observed <= dates.now, dates.now.timeIntervalSince(observed) <= 3_600,
              let account = cache["accountUuid"] as? String, !account.isEmpty,
              account == (state["oauthAccount"] as? JSON)?["accountUuid"] as? String,
              let usage = cache["utilization"] as? JSON else { return nil }
        let current = [(key: "five_hour", minutes: 300), (key: "seven_day", minutes: 10_080)].compactMap { period in
            window(usage[period.key], minutes: period.minutes, usedKey: "utilization", resetKey: "resets_at",
                   observed: observed, dates: dates)
        }.filter { window in
            window.resetAt.map { $0 > dates.now } ?? true
        }
        return current.isEmpty ? nil : NotchAIQuotaSnapshot(windows: current)
    }

    private static func claudeSnapshot(_ document: JSON, modified: Date, dates: Dates) -> NotchAIUsageResult {
        guard let rawLimits = document["rate_limits"], !(rawLimits is NSNull) else { return .missing }
        guard let limits = rawLimits as? JSON,
              let observed = dates.observation(document["captured_at"], fallback: modified) else {
            return .invalid
        }
        let result = windows([
            window(limits["five_hour"], minutes: 300, usedKey: "used_percentage", resetKey: "resets_at", observed: observed, dates: dates),
            window(limits["seven_day"], minutes: 10_080, usedKey: "used_percentage", resetKey: "resets_at", observed: observed, dates: dates)
        ])
        let reportedWindow = ["five_hour", "seven_day"].contains { key in
            limits[key].map { !($0 is NSNull) } ?? false
        }
        return reportedWindow && result == .missing ? .invalid : result
    }

    private static func customSnapshot(_ data: Data, dates: Dates) throws -> NotchAIUsageResult {
        let document = try object(data)
        guard integer(document["version"]) == 1,
              let observed = dates.observation(document["observedAt"]),
              let rows = document["windows"] as? [Any] else { return .invalid }
        let result = windows(rows.map { row in
            let minutes = (row as? JSON).flatMap { integer($0["minutes"]) }
            return window(row, minutes: minutes, usedKey: "usedPercent", resetKey: "resetAt", observed: observed, dates: dates)
        })
        return !rows.isEmpty && result == .missing ? .invalid : result
    }

    private static func codexBarSnapshot(_ data: Data, provider: String, dates: Dates) throws -> NotchAIUsageResult {
        let document = try json(data)
        let rows: [JSON]
        if let row = document as? JSON { rows = [row] }
        else if let list = document as? [JSON] { rows = list }
        else { return .invalid }

        let matches = rows.filter { ($0["provider"] as? String)?.lowercased() == provider }
        guard let row = matches.first else { return .missing }
        // A profile refers to one exported account. An ambiguous export should require a corrected file.
        guard matches.count == 1 else { return .invalid }
        guard let usage = row["usage"] as? JSON else { return .missing }
        guard let observed = dates.observation(usage["updatedAt"]) else { return .invalid }
        func rateWindow(_ row: JSON?) -> NotchAIQuotaWindow? {
            window(row, minutes: integer(row?["windowMinutes"]), usedKey: "usedPercent",
                   resetKey: "resetsAt", observed: observed, dates: dates)
        }
        let standard = ["primary", "secondary", "tertiary"].map { rateWindow(usage[$0] as? JSON) }
        if provider == "antigravity", let extra = usage["extraRateWindows"] as? [JSON] {
            // Same period can cover distinct model families. Use the most constrained known
            // summary bucket for each period, with its own reset and without adding percentages.
            let summaries = extra.compactMap { row -> NotchAIQuotaWindow? in
                guard (row["id"] as? String)?.hasPrefix("antigravity-quota-summary-") == true,
                      row["usageKnown"] as? Bool != false else { return nil }
                return rateWindow(row["window"] as? JSON)
            }
            if !summaries.isEmpty {
                return windows(summaries.sorted { $0.usedPercent > $1.usedPercent })
            }
        }
        return windows(standard)
    }

    private static func codexSnapshot(in folder: URL, dates: Dates) throws -> NotchAIUsageResult {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let candidates = try codexFiles(in: folder, keys: keys)
        var snapshot: NotchAIUsageResult = .missing
        var newest: Date?
        var unreadable = false
        for candidate in candidates {
            guard !Task.isCancelled else { return .missing }
            do {
                let (data, truncated) = try codexTail(candidate)
                let lines = data.split(separator: 10, omittingEmptySubsequences: false)
                for line in (truncated ? lines.dropFirst() : lines[...]).reversed() {
                    guard line.range(of: tokenCountMarker) != nil, line.range(of: rateLimitsMarker) != nil,
                          let event = try? object(line), event["type"] as? String == "event_msg",
                          let payload = event["payload"] as? JSON, payload["type"] as? String == "token_count",
                          let limits = payload["rate_limits"] as? JSON,
                          isCodexAccountLimit(limits["limit_id"]),
                          let observed = dates.observation(event["timestamp"]),
                          newest.map({ observed > $0 }) ?? true else { continue }
                    let result = windows(["primary", "secondary"].map { key in
                        let row = limits[key] as? JSON
                        return window(row, minutes: codexMinutes(row?["window_minutes"]), usedKey: "used_percent",
                                      resetKey: "resets_at", observed: observed, dates: dates,
                                      resetDelay: number(row?["resets_in_seconds"]))
                    })
                    if result != .missing {
                        snapshot = result
                        newest = observed
                    }
                }
            } catch {
                if !isMissing(error) { unreadable = true }
            }
        }
        return snapshot == .missing && unreadable ? .unreadable : snapshot
    }

    private static func isCodexAccountLimit(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        return (value as? String)?.lowercased() == "codex"
    }

    private static func codexMinutes(_ value: Any?) -> Int? {
        // Some older Codex versions wrote canonical limits rounded down by one minute.
        switch integer(value) {
        case 299: return 300
        case 10_079: return 10_080
        case let minutes: return minutes
        }
    }

    private static func codexFiles(in folder: URL, keys: Set<URLResourceKey>) throws -> [URL] {
        let folder = folder.resolvingSymlinksInPath()
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SourceError.invalid }
        let manager = FileManager.default
        var budget = codexEntryLimit
        var files: [(url: URL, modified: Date)] = []
        var enumerationError: Error?
        var roots: [(url: URL, depth: Int)] = [
            (folder.appendingPathComponent("archived_sessions", isDirectory: true), 3),
            (folder, 0),
            (folder.appendingPathComponent("sessions", isDirectory: true), 0)
        ]
        while !Task.isCancelled, budget > 0, let root = roots.popLast() {
            if root.url != folder {
                guard let values = try? root.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
            }
            guard let entries = manager.enumerator(at: root.url, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else { continue }
            var children: [(url: URL, depth: Int)] = []
            for case let url as URL in entries {
                budget -= 1
                if let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true {
                    let name = url.lastPathComponent
                    if values.isRegularFile == true, name.hasPrefix("rollout-"), url.pathExtension == "jsonl" {
                        files.append((url, values.contentModificationDate ?? .distantPast))
                    }
                    if values.isDirectory == true, root.depth < 3, isCodexDateFolder(name, depth: root.depth) {
                        children.append((url, root.depth + 1))
                    }
                }
                if budget <= 0 { break }
            }
            roots += children.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        }
        if files.isEmpty, let enumerationError { throw enumerationError }
        return files.sorted {
            if $0.modified == $1.modified { return $0.url.path > $1.url.path }
            return $0.modified > $1.modified
        }.prefix(codexFileLimit).map(\.url)
    }

    private static func isCodexDateFolder(_ name: String, depth: Int) -> Bool {
        name.utf8.count == (depth == 0 ? 4 : 2) && name.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func codexTail(_ url: URL) throws -> (Data, Bool) {
        let (handle, info) = try openRegularFile(url)
        defer { try? handle.close() }
        // Include the preceding byte so an exact line-boundary cut preserves the first record.
        let offset = max(0, info.st_size - off_t(codexTailBytes))
        if offset > 0 { try handle.seek(toOffset: UInt64(offset - 1)) }
        var data = try handle.read(upToCount: codexTailBytes + 1) ?? Data()
        guard offset > 0, let first = data.first else { return (data, false) }
        data.removeFirst()
        return (data, first != 10)
    }

    private static func snapshotFile(_ name: String, in folder: URL, maxBytes: Int = snapshotBytes) throws -> (Data, Date) {
        let (handle, info) = try openRegularFile(folder.appendingPathComponent(name))
        defer { try? handle.close() }
        guard info.st_size <= maxBytes,
              let data = try handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else {
            throw SourceError.invalid
        }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return (data, modified)
    }

    private static func openRegularFile(_ url: URL) throws -> (FileHandle, stat) {
        // Local source files can be swapped by a producer. Avoid following a replacement symlink
        // or blocking while opening a named pipe before checking the actual file descriptor.
        let fd = url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer else { return Int32(-1) }
            return open(pointer, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw SourceError.invalid
        }
        return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), info)
    }

    private enum SourceError: Error {
        case invalid
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case NSPOSIXErrorDomain: return [Int(ENOENT), Int(ENOTDIR)].contains(error.code)
        case NSCocoaErrorDomain: return [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
        default: return false
        }
    }

    private static func json(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw SourceError.invalid }
    }

    private static func object(_ data: Data) throws -> JSON {
        guard let object = try json(data) as? JSON else { throw SourceError.invalid }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? { number(value).flatMap { Int(exactly: $0) } }

    private static func window(_ value: Any?, minutes: Int?, usedKey: String, resetKey: String,
                               observed: Date, dates: Dates, resetDelay: Double? = nil) -> NotchAIQuotaWindow? {
        guard let row = value as? JSON, let minutes, minutes > 0,
              row["usageKnown"] as? Bool != false,
              let used = number(row[usedKey]), (0...100).contains(used) else { return nil }
        var reset = dates.parse(row[resetKey])
        if let raw = row[resetKey], !(raw is NSNull), reset == nil { return nil }
        if reset == nil, let resetDelay, (0...31_622_400).contains(resetDelay) {
            reset = observed.addingTimeInterval(resetDelay)
        }
        return NotchAIQuotaWindow(minutes: minutes, usedPercent: used, resetAt: reset, observedAt: observed)
    }

    private static func windows(_ values: [NotchAIQuotaWindow?]) -> NotchAIUsageResult {
        var seen = Set<Int>()
        let windows = values.compactMap { $0 }.filter { seen.insert($0.minutes).inserted }
            .sorted { $0.minutes < $1.minutes }
        return windows.isEmpty ? .missing : .available(NotchAIQuotaSnapshot(windows: windows))
    }

    private struct Dates {
        let now: Date
        private let plain = ISO8601DateFormatter()
        private let fractional = ISO8601DateFormatter()

        init(now: Date) {
            self.now = now
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }

        func parse(_ value: Any?) -> Date? {
            if let seconds = number(value), seconds > 0, seconds <= 253_402_300_799 {
                return Date(timeIntervalSince1970: seconds)
            }
            guard let string = value as? String else { return nil }
            return fractional.date(from: string) ?? plain.date(from: string)
        }

        func observation(_ value: Any?, fallback: Date? = nil) -> Date? {
            let date = value == nil ? fallback : parse(value)
            guard let date, date <= now.addingTimeInterval(300) else { return nil }
            return date
        }
    }
}
