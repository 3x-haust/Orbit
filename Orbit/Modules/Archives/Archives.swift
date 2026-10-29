import AppKit
import UniformTypeIdentifiers

/// Orbit's Keka: compress and extract, from the Archives page, Finder's right-click menu, or by
/// double-clicking an archive once Orbit is the default app for them.
@MainActor @Observable
final class Archives {
    static let shared = Archives()

    @MainActor @Observable
    final class Job: Identifiable {
        enum Kind { case compress, extract }
        enum State: Equatable { case running, done(URL), failed(String), cancelled }
        let id = UUID()
        let kind: Kind
        let name: String
        var progress: Double = 0
        var state: State = .running
        let cancel = ArchiveCancel()
        init(kind: Kind, name: String) { self.kind = kind; self.name = name }
        var isRunning: Bool { state == .running }
    }

    private(set) var jobs: [Job] = []
    var running: Bool { jobs.contains { $0.isRunning } }

    // MARK: Settings

    private enum Key {
        static let format = "archives.format", level = "archives.level", askPassword = "archives.askPassword",
                   split = "archives.splitMB", skipMac = "archives.skipMacFiles", trashOriginals = "archives.trashOriginals",
                   reveal = "archives.revealAfter", trashArchive = "archives.trashArchiveAfter",
                   previousHandlers = "archives.previousHandlers", handling = "archives.handling",
                   windows = "archives.windowsCompatible", zipEncryption = "archives.zipEncryption", nameEncoding = "archives.nameEncoding"
    }
    private let d = UserDefaults.standard

    var format: ArchiveFormat { didSet { d.set(format.rawValue, forKey: Key.format) } }
    var level: ArchiveLevel { didSet { d.set(level.rawValue, forKey: Key.level) } }
    var askPassword: Bool { didSet { d.set(askPassword, forKey: Key.askPassword) } }
    /// Megabytes per part; 0 = one file.
    var splitMB: Int { didSet { d.set(splitMB, forKey: Key.split) } }
    var skipMacFiles: Bool { didSet { d.set(skipMacFiles, forKey: Key.skipMac) } }
    var trashOriginals: Bool { didSet { d.set(trashOriginals, forKey: Key.trashOriginals) } }
    var revealAfter: Bool { didSet { d.set(revealAfter, forKey: Key.reveal) } }
    var trashArchiveAfter: Bool { didSet { d.set(trashArchiveAfter, forKey: Key.trashArchive) } }
    /// ZIPs any Windows PC reads right: Korean names, no illegal characters.
    var windowsCompatible: Bool { didSet { d.set(windowsCompatible, forKey: Key.windows) } }
    var zipEncryption: ZipEncryption { didSet { d.set(zipEncryption.rawValue, forKey: Key.zipEncryption) } }
    /// For old ZIPs whose names come out garbled: which language's code page they were written in.
    var nameEncoding: NameEncoding { didSet { d.set(nameEncoding.rawValue, forKey: Key.nameEncoding) } }

    private init() {
        format = ArchiveFormat(rawValue: d.string(forKey: Key.format) ?? "") ?? .zip
        level = ArchiveLevel(rawValue: d.string(forKey: Key.level) ?? "") ?? .normal
        askPassword = d.bool(forKey: Key.askPassword)
        splitMB = d.integer(forKey: Key.split)
        skipMacFiles = d.object(forKey: Key.skipMac) as? Bool ?? true
        trashOriginals = d.bool(forKey: Key.trashOriginals)
        revealAfter = d.object(forKey: Key.reveal) as? Bool ?? true
        trashArchiveAfter = d.bool(forKey: Key.trashArchive)
        windowsCompatible = d.object(forKey: Key.windows) as? Bool ?? true
        zipEncryption = ZipEncryption(rawValue: d.string(forKey: Key.zipEncryption) ?? "") ?? .aes256
        nameEncoding = NameEncoding(rawValue: d.string(forKey: Key.nameEncoding) ?? "") ?? .auto
        isDefaultHandler = Self.orbitHandlesArchives
    }

    func start() {
        NSApp.servicesProvider = ArchiveServices.shared
        refreshServices()
    }

    // MARK: Opening

    /// Files handed to Orbit by Finder (double-click, Open With, drag onto the Dock icon).
    func open(_ urls: [URL]) {
        let archives = urls.filter(Self.isArchive)
        if !archives.isEmpty { extract(archives) }
        let rest = urls.filter { !Self.isArchive($0) }
        if !rest.isEmpty { compress(rest) }
    }

    /// Dropped on the page: archives get unpacked, anything else gets packed together.
    func handleDrop(_ urls: [URL]) {
        if !urls.isEmpty, urls.allSatisfy(Self.isArchive) { extract(urls) } else { compress(urls) }
    }

    static let extractableExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "lz", "lzma", "zst", "tzst",
        "z", "cab", "cpio", "lha", "lzh", "xar", "iso", "dmg", "jar", "apk", "warc", "pkg",
    ]

    static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.range(of: #"^\d{3}$"#, options: .regularExpression) != nil { return true } // split parts
        if ext == "pkg" { return false } // installers open in Installer
        if extractableExtensions.contains(ext) { return true }
        if let t = UTType(filenameExtension: ext), t.conforms(to: .archive), !t.conforms(to: .diskImage) { return true }
        return false
    }

    // MARK: Extract

    func extract(_ urls: [URL]) {
        // A split set is one archive: only start from one of its parts.
        var seen = Set<String>()
        for url in urls {
            let first = LibArchive.volumes(for: url).first ?? url
            guard seen.insert(first.path).inserted else { continue }
            extract(first, password: nil)
        }
    }

    private func extract(_ url: URL, password: String?, job existing: Job? = nil) {
        let job = existing ?? add(Job(kind: .extract, name: url.lastPathComponent))
        job.state = .running
        let encoding = nameEncoding
        Task.detached { [cancel = job.cancel] in
            let result = Result { try ArchiveEngine.extract(url, password: password, encoding: encoding, cancel: cancel) { p in
                Task { @MainActor in job.progress = p }
            } }
            await MainActor.run {
                switch result {
                case .success(let out):
                    self.finish(job, .done(out))
                    if self.revealAfter { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                    if self.trashArchiveAfter {
                        NSWorkspace.shared.recycle(LibArchive.volumes(for: url))
                    }
                case .failure(let error as ArchiveError) where error == .needsPassword || error == .wrongPassword:
                    if let pw = PasswordPrompt.ask(for: url.lastPathComponent, retry: error == .wrongPassword) {
                        job.progress = 0
                        self.extract(url, password: pw, job: job)
                    } else {
                        self.finish(job, .cancelled)
                    }
                case .failure(let error as ArchiveError) where error == .cancelled:
                    self.finish(job, .cancelled)
                case .failure(let error):
                    self.finish(job, .failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: Compress

    func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var options = CompressOptions(format: format, level: level, password: nil,
                                      splitSize: splitMB > 0 ? Int64(splitMB) * 1_000_000 : nil, skipMacFiles: skipMacFiles,
                                      windowsCompatible: windowsCompatible, zipEncryption: zipEncryption)
        if askPassword, format.supportsPassword {
            guard let pw = PasswordPrompt.ask(for: urls.count == 1 ? urls[0].lastPathComponent : "Archive".loc, creating: true) else { return }
            options.password = pw
        }
        let name = urls.count == 1 ? urls[0].lastPathComponent : "%ld items".loc(urls.count)
        let job = add(Job(kind: .compress, name: name))
        let trash = trashOriginals
        Task.detached { [cancel = job.cancel, options] in
            let result = Result { try ArchiveEngine.compress(urls, options: options, cancel: cancel) { p in
                Task { @MainActor in job.progress = p }
            } }
            await MainActor.run {
                switch result {
                case .success(let out):
                    self.finish(job, .done(out.url))
                    if trash { NSWorkspace.shared.recycle(urls) }
                    if self.revealAfter { NSWorkspace.shared.activateFileViewerSelecting([out.url]) }
                    if out.longPaths > 0 {
                        Toast.show("Some paths are too long for Windows", symbol: "exclamationmark.triangle.fill",
                                   detail: "%ld are over 260 characters — Windows may not unpack them".loc(out.longPaths))
                    } else if out.renamed > 0 {
                        Toast.show("Renamed %ld for Windows".loc(out.renamed), symbol: "checkmark.circle.fill",
                                   detail: "Characters like : ? * aren’t allowed there")
                    }
                case .failure(let error as ArchiveError) where error == .cancelled:
                    self.finish(job, .cancelled)
                case .failure(let error):
                    self.finish(job, .failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: Jobs

    private func add(_ job: Job) -> Job {
        jobs.insert(job, at: 0)
        if jobs.count > 8 { jobs.removeLast(jobs.count - 8) }
        ArchiveHUD.shared.update()
        return job
    }

    private func finish(_ job: Job, _ state: Job.State) {
        job.state = state
        if case .done = state { job.progress = 1 }
        ArchiveHUD.shared.update()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
        ArchiveHUD.shared.update()
    }

    // MARK: Default app

    /// Types Orbit takes over when it's the archive app. Disk images and installers stay with macOS.
    static let handledTypes: [String] = [
        "public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive", "public.tar-archive",
        "org.gnu.gnu-zip-archive", "org.gnu.gnu-zip-tar-archive", "public.bzip2-archive", "public.tar-bzip2-archive",
        "org.tukaani.xz-archive", "org.tukaani.tar-xz-archive", "public.lzip-archive", "org.tukaani.lzma-archive",
        "com.facebook.zstandard-archive", "public.z-archive", "public.cpio-archive", "public.archive.lha", "com.microsoft.cab",
    ]

    private(set) var isDefaultHandler: Bool
    private(set) var changingHandler = false

    /// LaunchServices keeps handlers by bundle ID, not by copy — with several Orbit builds on disk it
    /// may name any of them, so compare IDs, never paths.
    static var orbitHandlesArchives: Bool {
        handlerID(for: "public.zip-archive")?.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame
    }

    private static func handlerID(for uti: String) -> String? {
        guard let type = UTType(uti), let url = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Who opens .zip files now, for the page ("Now: Keka").
    var currentZipApp: String? {
        if Self.orbitHandlesArchives { return "Orbit" }
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .zip) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func setDefaultHandler(_ on: Bool) {
        guard !changingHandler else { return }
        changingHandler = true
        isDefaultHandler = on // the switch moves at once; reality is read back below
        Task {
            let ws = NSWorkspace.shared
            let me = Bundle.main.bundleURL
            let myID = Bundle.main.bundleIdentifier ?? "com.lyu.orbit"
            // Make sure LaunchServices knows this copy (and its document types) before asking.
            let reg = LSRegisterURL(me as CFURL, true)
            Self.log("register \(me.path): \(reg)")
            // Never remember Orbit itself (another copy of it) as "the app before Orbit".
            var previous = (d.dictionary(forKey: Key.previousHandlers) as? [String: String] ?? [:]).filter { _, path in
                Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier != myID
            }
            var failures = 0
            for id in Self.handledTypes {
                guard let type = UTType(id) else { continue }
                if on {
                    if let current = ws.urlForApplication(toOpen: type), Bundle(url: current)?.bundleIdentifier != myID {
                        previous[id] = current.path
                    }
                    if !(await Self.setHandler(at: me, bundleID: myID, for: type)) { failures += 1 }
                } else {
                    let back = previous[id].map { URL(fileURLWithPath: $0) }
                        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                        ?? Self.fallbackHandler(for: type, excluding: myID)
                    if !(await Self.setHandler(at: back, bundleID: Bundle(url: back)?.bundleIdentifier, for: type)) { failures += 1 }
                }
            }
            let now = Self.orbitHandlesArchives
            Self.log("asked on=\(on); zip now \(Self.handlerID(for: "public.zip-archive") ?? "nil"); failures \(failures)")
            if on == now { d.set(on ? previous : [:], forKey: Key.previousHandlers) }
            d.set(now, forKey: Key.handling)
            isDefaultHandler = now
            changingHandler = false
            if on != now {
                Toast.show("Couldn’t change the archive app", symbol: "exclamationmark.triangle.fill", detail: "macOS didn’t allow it — try again")
            } else {
                Toast.show(on ? "Orbit opens archives now" : "Archives open like before", symbol: "archivebox.fill")
            }
        }
    }

    /// Archive Utility when it can open the type, else any other app that can.
    private static func fallbackHandler(for type: UTType, excluding myID: String) -> URL {
        let utility = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app")
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: type).filter { Bundle(url: $0)?.bundleIdentifier != myID }
        if apps.contains(where: { $0.standardizedFileURL == utility.standardizedFileURL }) || apps.isEmpty { return utility }
        return apps[0]
    }

    /// NSWorkspace first (it may ask for confirmation); LaunchServices by bundle ID if that fails.
    private static func setHandler(at app: URL, bundleID: String?, for type: UTType) async -> Bool {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            log("\(type.identifier) → \(bundleID ?? app.lastPathComponent): ok")
        } catch {
            log("\(type.identifier) → \(bundleID ?? app.lastPathComponent): NSWorkspace \(error.localizedDescription)")
            guard let bundleID else { return false }
            let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, bundleID as CFString)
            log("\(type.identifier): LSSetDefaultRoleHandlerForContentType \(status)")
            if status != noErr { return false }
        }
        return handlerID(for: type.identifier)?.caseInsensitiveCompare(bundleID ?? "") == .orderedSame
    }

    static func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("archives.log")
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Finder menu

    enum ServicesState { case unknown, ready, disabled, missing }
    private(set) var servicesState: ServicesState = .unknown

    /// Re-registers the Finder menu items and reads back whether macOS lists them and has them on.
    func refreshServices() {
        NSUpdateDynamicServices()
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            p.arguments = ["-dump_pboard"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var listed = false
            if (try? p.run()) != nil {
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                listed = text.contains("compressWithOrbit") && text.contains("extractWithOrbit")
            }
            // Turned off by the user in Keyboard Shortcuts › Services?
            let status = UserDefaults(suiteName: "pbs")?.dictionary(forKey: "NSServicesStatus") ?? [:]
            let off = status.contains { key, value in
                key.hasPrefix("com.lyu.orbit") && ((value as? [String: Any])?["enabled_context_menu"] as? Bool) == false
            }
            let state: ServicesState = !listed ? .missing : (off ? .disabled : .ready)
            await MainActor.run { self.servicesState = state }
        }
    }

    /// Keyboard › Keyboard Shortcuts…, where Services (and Orbit's Finder items) are switched on and off.
    func openServicesSettings() {
        NSUpdateDynamicServices()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if error != nil {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
        }
    }

    func refreshHandlerState() { isDefaultHandler = Self.orbitHandlesArchives }

    // MARK: Pickers

    func chooseAndCompress() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Compress".loc
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { compress(panel.urls) }
    }

    func chooseAndExtract() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Extract".loc
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { extract(panel.urls.filter(Self.isArchive)) }
    }
}

/// Finder's right-click › Quick Actions › "Compress with Orbit" / "Extract with Orbit".
final class ArchiveServices: NSObject {
    static let shared = ArchiveServices()

    @objc func compressWithOrbit(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.files(pboard)
        Task { @MainActor in Archives.shared.compress(urls) }
    }

    @objc func extractWithOrbit(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.files(pboard)
        Task { @MainActor in Archives.shared.extract(urls.filter(Archives.isArchive)) }
    }

    private static func files(_ pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// Asks for an archive's password in a small sheet-like alert. The text never leaves the field.
@MainActor
enum PasswordPrompt {
    static func ask(for name: String, retry: Bool = false, creating: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = creating ? "Set a password for “%@”".loc(name) : (retry ? "That password didn’t work".loc : "“%@” needs a password".loc(name))
        alert.informativeText = creating ? "You’ll need it to open the archive. Orbit doesn’t keep it.".loc : "Enter the password to unpack it.".loc
        alert.icon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Password".loc
        let again = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        again.placeholderString = "Again, to be sure".loc
        if creating {
            let stack = NSStackView(views: [field, again])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 240, height: 56)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }
        alert.addButton(withTitle: creating ? "Compress".loc : "Extract".loc)
        alert.addButton(withTitle: "Cancel".loc)
        alert.window.initialFirstResponder = field
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let pw = field.stringValue
            if pw.isEmpty { continue }
            if creating, pw != again.stringValue {
                alert.informativeText = "The two passwords don’t match.".loc
                again.stringValue = ""
                continue
            }
            field.stringValue = ""
            again.stringValue = ""
            return pw
        }
    }
}
