import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Talks to installed provider CLIs without a shell or a dependency on their configuration files.
enum NotchUsageCLI {
    static func executable(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        var candidates = (inherited + common).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
        if name == "codex" {
            candidates += ["/Applications", home.appendingPathComponent("Applications").path].map {
                URL(fileURLWithPath: $0).appendingPathComponent("Codex.app/Contents/Resources/codex")
            }
            // Finder-launched apps usually do not have a shell-managed Node bin directory on PATH.
            let versions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            let installed = (try? FileManager.default.contentsOfDirectory(atPath: versions.path)) ?? []
            candidates += installed.filter { $0.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { versions.appendingPathComponent($0).appendingPathComponent("bin/codex") }
        }
        return candidates.first { url in
            FileManager.default.isExecutableFile(atPath: url.path)
                && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func run<T>(_ executable: URL, arguments: [String], overrides: [String: String],
                       input: (FileHandle, Output) throws -> T) -> T? {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        var childEnvironment = environment.merging(overrides) { _, override in override }
        // npm installs may use a node shebang. Use the interpreter next to that installation.
        let bin = executable.deletingLastPathComponent().path
        childEnvironment["PATH"] = bin + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = childEnvironment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try process.run()
            defer {
                try? stdin.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
            }
            return try input(stdin.fileHandleForWriting, Output(descriptor: stdout.fileHandleForReading.fileDescriptor))
        } catch {
            return nil
        }
    }

    struct Output {
        let descriptor: Int32
        // All replies share a deadline and a byte budget, including unrelated notifications.
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        var buffer = Data()
        var received = 0

        mutating func nextLine() throws -> Data? {
            while true {
                if let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    buffer.removeSubrange(...end)
                    return line
                }
                guard try readMore() else {
                    guard !buffer.isEmpty else { return nil }
                    let final = buffer
                    buffer.removeAll()
                    return final
                }
            }
        }

        mutating func readDocument() throws -> Data {
            while try readMore() {}
            return buffer
        }

        private mutating func readMore() throws -> Bool {
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
                var watcher = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&watcher, 1, 100)
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { break }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count == 0 { return false }
                if count < 0 && errno == EINTR { continue }
                guard count > 0, received + count <= 256 * 1024 else { break }
                received += count
                buffer.append(contentsOf: chunk.prefix(count))
                return true
            }
            throw CocoaError(.fileReadUnknown)
        }
    }
}

enum NotchCodexQuota {
    static func read(executable: URL, profile: URL, now: Date = .now) -> NotchAIUsageResult? {
        // The launch accepts a home directory, whereas the file reader also accepts sessions directly.
        let home = profile.lastPathComponent == "sessions" ? profile.deletingLastPathComponent() : profile
        return NotchUsageCLI.run(executable, arguments: ["app-server"], overrides: ["CODEX_HOME": home.path]) { stdin, stdout in
            var stdout = stdout
            func send(_ value: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
                data.append(10)
                try stdin.write(contentsOf: data)
            }
            func result(_ id: Int) throws -> [String: Any]? {
                while let line = try stdout.nextLine() {
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          message["id"] as? Int == id else { continue }
                    return message["result"] as? [String: Any]
                }
                return nil
            }

            try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "orbit", "version": "1"]]])
            guard try result(1) != nil else { return nil }
            try send(["method": "initialized"])
            try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
            guard let authentication = try result(2) else { return nil }
            guard let account = authentication["account"] as? [String: Any],
                  account["type"] as? String == "chatgpt" else { return NotchAIUsageResult.missing }
            do {
                try send(["id": 3, "method": "account/rateLimits/read"])
                guard let payload = try result(3) else { return NotchAIUsageResult.missing }
                return NotchAIUsageReader.codexAccountSnapshot(payload, now: now)
            } catch {
                // Rollouts have no account identity. Once the CLI responds, do not
                // fall back to another account's earlier local snapshot.
                return NotchAIUsageResult.missing
            }
        } ?? nil
    }
}

/// Desktop Code sessions do not run status lines. Read the shared subscription quota directly,
/// using only an existing Claude Code login; Claude remains responsible for refreshing its tokens.
enum NotchClaudeQuota {
    struct Reading: Sendable {
        var result: NotchAIUsageResult?
        var retryAfter: TimeInterval = 60
        var credentialID: String?
        var allowsPrevious = false
    }

    struct Source: Hashable, Sendable {
        let folder: URL
        let credentialFolder: URL
        let keychainService: String
    }

    static func source(for profile: NotchAIProfile,
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Source? {
        let standard = home.appendingPathComponent(".claude").path
        let configured = profile.folder.isEmpty ? environment["CLAUDE_CONFIG_DIR"] : (profile.folder as NSString).expandingTildeInPath
        if profile.folder.isEmpty, let configured, !configured.isEmpty, !configured.hasPrefix("/") { return nil }
        guard let folder = NotchAIProfile.folderURL(configured?.isEmpty == false ? configured! : standard) else { return nil }
        // A selected custom profile must not inherit a different profile's storage override.
        let secure = profile.folder.isEmpty ? environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] : nil
        if let secure, !secure.isEmpty, !secure.hasPrefix("/") { return nil }
        let storagePath = secure.map { $0.isEmpty ? standard : $0 } ?? configured ?? standard
        guard let credentialFolder = NotchAIProfile.folderURL(storagePath.precomposedStringWithCanonicalMapping) else { return nil }
        return Source(folder: folder, credentialFolder: credentialFolder,
                      keychainService: keychainService(configDirectory: secure ?? configured))
    }

    struct Credentials: Decodable {
        let accessToken: String
        let expiresAt: Double
        let scopes: [String]
        let subscriptionType: String?

        static func decode(_ data: Data, now: Date) -> Self? {
            struct Document: Decodable { let claudeAiOauth: Credentials }
            guard let value = try? JSONDecoder().decode(Document.self, from: data).claudeAiOauth,
                  !value.accessToken.isEmpty, !value.accessToken.contains(where: { $0.isWhitespace }),
                  value.expiresAt.isFinite, value.expiresAt / 1000 > now.timeIntervalSince1970,
                  value.scopes.contains("user:profile"), value.scopes.contains("user:inference"),
                  ["pro", "max", "team", "enterprise"].contains(value.subscriptionType) else { return nil }
            return value
        }
    }

    static func keychainService(configDirectory: String?) -> String {
        guard let path = configDirectory?.precomposedStringWithCanonicalMapping, !path.isEmpty else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash
    }

    enum StoredCredentials {
        case missing, unavailable
        case document(Data)
    }

    static func credentials(from source: Source, now: Date = .now,
                            keychain: (String) -> StoredCredentials = readKeychain) -> Credentials? {
        // Match Claude Code's Keychain-first document selection. A present but unusable
        // account must not fall through to an older still-valid account in the plaintext file.
        switch keychain(source.keychainService) {
        case .document(let data): return Credentials.decode(data, now: now)
        case .unavailable: return nil
        case .missing: return fileCredentials(in: source.credentialFolder, now: now)
        }
    }

    private static func fileCredentials(in folder: URL, now: Date) -> Credentials? {
        let file = folder.appendingPathComponent(".credentials.json")
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        if descriptor >= 0 {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 256 * 1024,
                  let data = try? handle.read(upToCount: 256 * 1024 + 1), data.count <= 256 * 1024 else { return nil }
            return Credentials.decode(data, now: now)
        }
        return nil
    }

    private static func readKeychain(_ service: String) -> StoredCredentials {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = item as? Data else { return .unavailable }
        return .document(data)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func read(from source: Source) async -> Reading {
        guard let credentials = credentials(from: source) else { return Reading() }
        return await fetch(credentials, session: session)
    }

    static func fetch(_ credentials: Credentials, session: URLSession, now: Date = .now) async -> Reading {
        let identity = SHA256.hash(data: Data(credentials.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let transient = Reading(credentialID: identity, allowsPrevious: true)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return transient }
            if response.statusCode == 429 {
                let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
                return Reading(retryAfter: delay.isFinite ? max(300, min(delay, 3600)) : 300,
                               credentialID: identity, allowsPrevious: true)
            }
            if response.statusCode == 401 || response.statusCode == 403 { return Reading(result: .missing, credentialID: identity) }
            guard response.statusCode == 200, data.count <= 256 * 1024,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return transient }
            let result = NotchAIUsageReader.claudeAccountSnapshot(payload, now: now)
            return Reading(result: result == .missing ? nil : result, credentialID: identity, allowsPrevious: true)
        } catch {
            return transient
        }
    }
}

actor NotchAIUsageService {
    static let shared = NotchAIUsageService()

    private struct CachedReading {
        let result: NotchAIUsageResult?
        let expires: Date
    }

    private struct ClaudeReading {
        let result: NotchAIUsageResult?
        let expires: Date
        let credentialID: String?
    }

    private var codex: [URL: CachedReading] = [:]
    private var codexTasks: [URL: Task<NotchAIUsageResult?, Never>] = [:]
    private var claude: [NotchClaudeQuota.Source: ClaudeReading] = [:]
    private var claudeTasks: [NotchClaudeQuota.Source: Task<NotchClaudeQuota.Reading, Never>] = [:]
    private let claudeRead: @Sendable (NotchClaudeQuota.Source) async -> NotchClaudeQuota.Reading
    private let clock: @Sendable () -> Date

    init(claudeRead: @escaping @Sendable (NotchClaudeQuota.Source) async -> NotchClaudeQuota.Reading = { await NotchClaudeQuota.read(from: $0) },
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.claudeRead = claudeRead
        self.clock = clock
    }

    func prepare(_ profiles: [NotchAIProfile], preferences: UserDefaults) {
        ClaudeStatusLineBridge.automaticallyConnect(profiles, preferences: preferences)
    }

    func read(_ profile: NotchAIProfile) async -> NotchAIUsageResult {
        let folder = profile.sourceFolder
        if profile.provider == .codex, let folder, let result = await readCodex(folder) {
            return result
        }
        if profile.provider == .claude {
            let local = await readLocal(profile)
            if case .sessionCost(let cost) = local, (0...120).contains(clock().timeIntervalSince(cost.observedAt)) {
                return local
            }
            if let source = NotchClaudeQuota.source(for: profile), let result = await readClaude(source) { return result }
            return local
        }
        return await readLocal(profile)
    }

    private func readLocal(_ profile: NotchAIProfile) async -> NotchAIUsageResult {
        let now = clock()
        let local = Task.detached(priority: .utility) { NotchAIUsageReader.read(profile, now: now) }
        return await withTaskCancellationHandler { await local.value } onCancel: { local.cancel() }
    }

    private func readClaude(_ source: NotchClaudeQuota.Source) async -> NotchAIUsageResult? {
        let now = clock()
        if let reading = claude[source], reading.expires > now { return currentQuota(reading.result, now: now) }
        let task: Task<NotchClaudeQuota.Reading, Never>
        if let pending = claudeTasks[source] {
            task = pending
        } else {
            let read = claudeRead
            task = Task.detached(priority: .utility) { await read(source) }
            claudeTasks[source] = task
        }
        let reading = await task.value
        claudeTasks[source] = nil
        let previous = claude[source]
        let retained = reading.allowsPrevious && reading.credentialID != nil && previous?.credentialID == reading.credentialID
            ? currentQuota(previous?.result, now: clock()) : nil
        let changedIdentity = previous?.credentialID != nil && reading.credentialID != nil && previous?.credentialID != reading.credentialID
        let result = reading.result ?? (changedIdentity ? .missing : retained)
        claude[source] = ClaudeReading(result: result, expires: clock().addingTimeInterval(reading.retryAfter), credentialID: reading.credentialID)
        return result
    }

    private func currentQuota(_ result: NotchAIUsageResult?, now: Date) -> NotchAIUsageResult? {
        if result == .missing { return .missing }
        guard case .available(let quota) = result else { return nil }
        let windows = quota.windows.filter {
            now < ($0.resetAt ?? $0.observedAt.addingTimeInterval(Double($0.minutes) * 60))
        }
        return windows.isEmpty ? nil : .available(.init(windows: windows))
    }

    private func readCodex(_ folder: URL) async -> NotchAIUsageResult? {
        let now = Date()
        codex = codex.filter { $0.value.expires > now }
        if let reading = codex[folder] { return reading.result }
        if let task = codexTasks[folder] { return await task.value }
        let task = Task.detached(priority: .utility) {
            NotchUsageCLI.executable("codex").flatMap { NotchCodexQuota.read(executable: $0, profile: folder) }
        }
        codexTasks[folder] = task
        let result = await task.value
        codexTasks[folder] = nil
        codex[folder] = CachedReading(result: result, expires: Date().addingTimeInterval(120))
        return result
    }

}
