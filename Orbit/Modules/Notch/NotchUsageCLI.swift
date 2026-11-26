import Darwin
import Foundation

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

actor NotchAIUsageService {
    static let shared = NotchAIUsageService()

    private struct CodexReading {
        let result: NotchAIUsageResult?
        let expires: Date
    }

    private var codex: [URL: CodexReading] = [:]
    private var codexTasks: [URL: Task<NotchAIUsageResult?, Never>] = [:]

    func read(_ profile: NotchAIProfile) async -> NotchAIUsageResult {
        let folder = profile.sourceFolder
        if profile.provider == .codex, let folder, let result = await readCodex(folder) {
            return result
        }
        let local = Task.detached(priority: .utility) { NotchAIUsageReader.read(profile) }
        return await withTaskCancellationHandler { await local.value } onCancel: { local.cancel() }
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
        codex[folder] = CodexReading(result: result, expires: Date().addingTimeInterval(120))
        return result
    }

}
