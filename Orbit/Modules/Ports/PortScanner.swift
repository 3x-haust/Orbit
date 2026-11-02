import AppKit
import Darwin
import Observation

/// A TCP port something on this Mac is listening on, with who opened it and, for a dev server, the project it serves.
struct ListeningPort: Identifiable, Equatable {
    enum Kind: Int { case dev, app, system }

    let port: Int
    let pid: pid_t
    var id: String { "\(pid):\(port)" }
    /// The process, or the app its helper belongs to ("Discord", not "Discord Helper (Renderer)").
    let name: String
    /// What the command line says it is: "Next.js", "Vite", "Postgres"…
    let tool: String?
    let kind: Kind
    /// Reachable from other devices, not only this Mac (bound to every interface or a LAN address).
    let exposed: Bool
    let project: Project?
    /// The `.app` it belongs to, for its icon.
    let appPath: String?
    let started: Date?

    struct Project: Equatable {
        let name: String
        let path: String
    }

    var url: URL { URL(string: "http://localhost:\(port)")! }
}

/// Lists listening TCP ports with `lsof`, only while something looks (the Ports page, the launcher).
/// Sockets of other users' and macOS's root processes aren't visible without admin rights, so those don't show.
@MainActor @Observable
final class PortScanner {
    static let shared = PortScanner()

    private(set) var ports: [ListeningPort] = []
    private(set) var scannedAt: Date?

    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    /// Who's waiting for the scan in flight, such as the launcher redrawing its results.
    @ObservationIgnored private var waiting: [() -> Void] = []

    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if watchers > 0, timer == nil {
            refresh()
            let t = Timer(timeInterval: 2, repeats: true) { _ in Task { @MainActor in PortScanner.shared.refresh() } }
            t.tolerance = 0.3
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if watchers == 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh(then done: (() -> Void)? = nil) {
        if let done { waiting.append(done) }
        guard !busy else { return }
        busy = true
        Task {
            let found = await Task.detached { Self.scan() }.value
            busy = false
            if found != ports { ports = found }
            scannedAt = Date()
            let callbacks = waiting
            waiting = []
            callbacks.forEach { $0() }
        }
    }

    // MARK: Stopping

    /// Stops the process holding the port, after checking it's still the same one: a PID can be reused once it exits.
    /// Returns an error message on failure.
    func stop(_ port: ListeningPort, force: Bool) -> String? {
        guard port.pid > 1, port.pid != getpid(), !ProcessMonitor.critical.contains(port.name) else {
            return "macOS needs this process to keep running."
        }
        guard Self.startTime(port.pid) == port.started else { return "It already stopped." }
        if let app = NSRunningApplication(processIdentifier: port.pid) {
            if force ? app.forceTerminate() : app.terminate() { return nil }
        }
        if kill(port.pid, force ? SIGKILL : SIGTERM) == 0 { return nil }
        return errno == EPERM ? "It belongs to another user or to macOS, so Orbit isn't allowed to end it." : "Couldn’t end it."
    }

    // MARK: Scanning

    private nonisolated static func scan() -> [ListeningPort] {
        // -F: one field per line, so names with spaces ("Code Helper") parse cleanly.
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"]).output
        var bound: [pid_t: (command: String, ports: [Int: Bool])] = [:]
        var pid: pid_t = 0
        for line in out.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            switch field {
            case "p": pid = pid_t(value) ?? 0
            case "c": bound[pid, default: ("", [:])].command = String(value)
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = value[..<colon]
                let local = host == "127.0.0.1" || host == "[::1]" || host == "localhost"
                let exposed = bound[pid]?.ports[port] == true || !local
                bound[pid, default: ("", [:])].ports[port] = exposed
            default: break
            }
        }

        let me = getuid()
        var result: [ListeningPort] = []
        for (pid, entry) in bound where pid > 0 {
            let path = executablePath(pid)
            let args = ProcessMonitor.arguments(pid)
            let bundle = ProcessMonitor.bundlePath(of: path)
            let tool = tool(path: path, args: args, bundle: bundle)
            let kind: ListeningPort.Kind
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/") || owner(pid) != me {
                kind = .system
            } else if bundle != nil, tool == nil {
                kind = .app
            } else {
                kind = .dev
            }
            let project = kind == .dev ? project(from: workingDirectory(pid)) : nil
            let name = bundle.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") }
                ?? (path.isEmpty ? entry.command : (path as NSString).lastPathComponent)
            let started = startTime(pid)
            for (port, exposed) in entry.ports {
                result.append(ListeningPort(port: port, pid: pid, name: name, tool: tool, kind: kind, exposed: exposed,
                                            project: project, appPath: bundle, started: started))
            }
        }
        return result.sorted { ($0.kind.rawValue, $0.port) < ($1.kind.rawValue, $1.port) }
    }

    /// Dev tools recognized from the command line, first match wins. Checked against each argument's last path parts.
    private nonisolated static let tools: [(match: String, name: String)] = [
        ("next", "Next.js"), ("vite", "Vite"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"),
        ("svelte-kit", "SvelteKit"), ("react-scripts", "Create React App"), ("webpack", "webpack"),
        ("storybook", "Storybook"), ("expo", "Expo"), ("metro", "Metro"), ("nest", "NestJS"),
        ("turbo", "Turborepo"), ("wrangler", "Wrangler"), ("firebase", "Firebase"), ("vercel", "Vercel"),
        ("uvicorn", "Uvicorn"), ("gunicorn", "Gunicorn"), ("flask", "Flask"), ("manage.py", "Django"),
        ("jupyter", "Jupyter"), ("streamlit", "Streamlit"), ("http.server", "Python http.server"),
        ("rails", "Rails"), ("puma", "Puma"), ("hugo", "Hugo"), ("jekyll", "Jekyll"),
        ("postgres", "Postgres"), ("mysqld", "MySQL"), ("redis-server", "Redis"), ("mongod", "MongoDB"),
        ("ollama", "Ollama"), ("com.docker.backend", "Docker"), ("vpnkit", "Docker"), ("adb", "Android Debug Bridge"),
        ("gradle", "Gradle"), ("bun", "Bun"), ("deno", "Deno"), ("node", "Node.js"), ("python", "Python"),
        ("ruby", "Ruby"), ("php", "PHP"), ("java", "Java"),
    ]

    private nonisolated static func tool(path: String, args: [String], bundle: String?) -> String? {
        // An app's helpers (Figma, Discord, VS Code's Code Helper) are the app, not a dev server; Docker is the exception.
        if let bundle { return bundle.hasSuffix("/Docker.app") ? "Docker" : nil }
        let parts = ([path] + args).flatMap { arg -> [String] in
            let pieces = arg.split(separator: "/").suffix(3).map { $0.lowercased() }
            return pieces + pieces.map { $0.split(separator: ".").first.map(String.init) ?? $0 }
        }
        // "next@15", and process titles a server sets for itself: "next-server (v16.1.6)".
        for (match, name) in tools where parts.contains(where: { $0 == match || $0.hasPrefix(match + "@") || $0.hasPrefix(match + "-server") }) {
            return name
        }
        // Versioned interpreters: python3.13, node22.
        let exe = (path as NSString).lastPathComponent.lowercased()
        return tools.first { exe.hasPrefix($0.match) && exe.dropFirst($0.match.count).allSatisfy { $0.isNumber || $0 == "." } }?.name
    }

    /// The folder the server runs in, up to the nearest folder that looks like a project. Nothing for the home folder itself.
    private nonisolated static func project(from directory: String?) -> ListeningPort.Project? {
        guard let directory else { return nil }
        let home = NSHomeDirectory()
        guard directory.hasPrefix(home + "/") else { return nil }
        let markers = ["package.json", ".git", "Cargo.toml", "go.mod", "pyproject.toml", "Gemfile", "pom.xml", "build.gradle", "deno.json"]
        let fm = FileManager.default
        var dir = directory
        var root: String?
        while dir.count > home.count {
            if markers.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) {
                root = dir
                // A workspace package inside a monorepo is the project; stop at the first package.json.
                if fm.fileExists(atPath: dir + "/package.json") { break }
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let path = root ?? directory
        var name = (path as NSString).lastPathComponent
        if let data = fm.contents(atPath: path + "/package.json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let package = json["name"] as? String, !package.isEmpty {
            name = package
        }
        return .init(name: name, path: path)
    }

    // MARK: Process facts

    private nonisolated static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    private nonisolated static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    private nonisolated static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private nonisolated static func owner(_ pid: pid_t) -> uid_t? { bsdInfo(pid)?.pbi_uid }

    nonisolated static func startTime(_ pid: pid_t) -> Date? {
        guard let info = bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
