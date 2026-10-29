import AppKit

/// What's playing, from macOS's Now Playing center.
///
/// Since macOS 15.4, MediaRemote only answers Apple's own processes. `/usr/bin/perl` is one of them, so
/// Orbit runs perl and has it load `OrbitMediaRemote.dylib` (bundled in Orbit's Frameworks), which
/// streams one JSON line per change — the approach of the open-source mediaremote-adapter.
@MainActor
final class MediaRemoteBridge {
    /// One line from the adapter. Read leniently: MediaRemote's numbers and flags come through as
    /// whatever NSNumber they were (a flag is often `1`, not `true`).
    struct Payload {
        var type: String
        var title, artist, album, bundle, parentBundle, appName, artwork, message: String?
        var duration, elapsed, rate, timestamp: Double?
        var playing: Bool?
        var isMusicApp: Bool?
        var pid: Int32?
        var artworkKey: String?

        init?(_ d: [String: Any]) {
            guard let type = d["type"] as? String else { return nil }
            self.type = type
            func str(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
            func flag(_ k: String) -> Bool? { (d[k] as? NSNumber)?.boolValue }
            title = str("title"); artist = str("artist"); album = str("album")
            bundle = str("bundle"); parentBundle = str("parentBundle"); appName = str("appName")
            artwork = str("artwork"); message = str("message")
            duration = num("duration"); elapsed = num("elapsed"); rate = num("rate"); timestamp = num("timestamp")
            playing = flag("playing"); isMusicApp = flag("isMusicApp")
            pid = (d["pid"] as? NSNumber)?.int32Value
            artworkKey = (d["artworkKey"] as? NSNumber)?.stringValue
        }
    }

    /// MediaRemote's command numbers.
    enum Command: Int {
        case play = 0, pause = 1, togglePlayPause = 2, stop = 3, next = 4, previous = 5
        case like = 106, ban = 107
    }

    var onPayload: ((Payload) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var running = false

    private var process: Process?
    private var input: Pipe?
    private var buffer = Data()
    private var restarts = 0
    private var stopping = false

    /// perl installs a C function from the dylib as a sub and calls it; its arguments are ignored.
    private static let script = """
    use strict; use DynaLoader;
    my ($lib, $fn) = @ARGV;
    my $h = DynaLoader::dl_load_file($lib, 0) or die "load: " . DynaLoader::dl_error() . "\\n";
    my $s = DynaLoader::dl_find_symbol($h, $fn) or die "symbol: " . DynaLoader::dl_error() . "\\n";
    DynaLoader::dl_install_xsub("main::run", $s);
    run();
    """

    static var library: URL? {
        let url = Bundle.main.privateFrameworksURL?.appendingPathComponent("OrbitMediaRemote.dylib")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static var available: Bool { library != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") }

    func start() {
        guard !running else { return }
        guard let lib = Self.library else { onFailure?("The Now Playing helper is missing from Orbit."); return }
        stopping = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.script, lib.path, "orbit_stream"]
        let out = Pipe(), inPipe = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardInput = inPipe
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let message = String(data: err.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in self?.ended(status: status, message: message) }
        }
        do {
            try p.run()
            process = p
            input = inPipe
            running = true
            NowPlayingLog.write("adapter started (pid \(p.processIdentifier))")
        } catch {
            NowPlayingLog.write("adapter failed to start: \(error)")
            onFailure?("Couldn’t start the Now Playing helper.")
        }
    }

    func stop() {
        stopping = true
        running = false
        try? input?.fileHandleForWriting.close() // the adapter exits when its stdin closes
        process?.terminate()
        process = nil
        input = nil
        buffer.removeAll()
    }

    /// Asks the adapter for a fresh read (it streams changes on its own; this is for catching up).
    func refresh() {
        guard running, let input else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("r\n".utf8))
    }

    func send(_ command: Command) { run(env: ["ORBIT_MR_CMD": String(command.rawValue)]) }

    /// Sends to one app rather than whatever is now playing — how auto-pause reaches the music app
    /// while a browser video owns the now-playing slot.
    func send(_ command: Command, to bundle: String) {
        run(env: ["ORBIT_MR_CMD": String(command.rawValue), "ORBIT_MR_APP": bundle])
    }

    func seek(to seconds: Double) { run(env: ["ORBIT_MR_SEEK": String(format: "%.3f", max(0, seconds))]) }

    private func run(env: [String: String]) {
        guard let lib = Self.library else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.script, lib.path, "orbit_send"]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let payload = Payload(obj) else { continue }
            if payload.type == "error" {
                NowPlayingLog.write("adapter error: \(payload.message ?? "?")")
                onFailure?(payload.message ?? "Now Playing isn’t available.")
                continue
            }
            restarts = 0
            onPayload?(payload)
        }
    }

    private func ended(status: Int32, message: String) {
        running = false
        process = nil
        guard !stopping else { return }
        NowPlayingLog.write("adapter exited \(status): \(message.prefix(300))")
        restarts += 1
        guard restarts <= 5 else { onFailure?("The Now Playing helper keeps stopping."); return }
        // Back off a little each time; a crash loop must not spin.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts * restarts)) { [weak self] in
            guard let self, !self.stopping else { return }
            self.start()
        }
    }
}

enum NowPlayingLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nowplaying.log")
    }()

    static func write(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
