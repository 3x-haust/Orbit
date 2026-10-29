import AppKit
import Carbon
import CryptoKit

/// Orbit's side of Tavi, the automatic 한/영 input method. An input method has to be its own
/// bundle in ~/Library/Input Methods, so Orbit ships Tavi's component and manages it here:
/// install/update, on/off, learning, and the personal word list Tavi shares on disk.
@MainActor @Observable
final class TaviBridge {
    static let shared = TaviBridge()

    static let inputMethodID = "dev.3xhaust.inputmethod.tavi"
    private static let sharedChange = Notification.Name("dev.3xhaust.tavi.shared-state-changed")

    enum Status: Equatable {
        case notInstalled, updateAvailable(String), needsAdding, ready, working(String), failed(String)
    }

    struct Word: Codable, Identifiable, Equatable {
        var id: String { raw }
        let raw: String
        var text: String
        var confirmations: Int
    }

    private(set) var status: Status = .notInstalled
    private(set) var installedVersion: String?
    private(set) var words: [Word] = []
    private(set) var isSelected = false
    /// Whether the user added Tavi in Keyboard Settings. Only that list survives a restart; an
    /// enable from code is gone at the next login, so it doesn't count.
    private(set) var isAdded = false

    private let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/Tavi.app")
    /// The input method Orbit carries, and a newer one fetched from Tavi's releases; the newest wins.
    private var bundled: URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TaviInputMethod.app"), Self.downloaded]
            .filter { Self.version($0) != nil }
        return candidates.max { a, b in Self.isNewer(Self.version(b) ?? "", than: Self.version(a) ?? "") }
    }
    private static let downloaded = Storage.dir("Tavi").appendingPathComponent("TaviInputMethod.app")
    private let wordsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tavi/words.json")
    private let prefs = UserDefaults(suiteName: inputMethodID)

    var bundledVersion: String? { bundled.flatMap(Self.version) }
    var standaloneAppInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Tavi.app") }

    private init() {
        // Adding Tavi in Keyboard Settings (or removing it) shows up here right away.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TaviBridge.shared.sourcesChanged() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TaviBridge.shared.refresh() }
        }
    }

    // MARK: Settings shared with the input method

    /// Off hands typing back to the keyboard the user had before Tavi, the way Tavi's own switch does.
    var enabled: Bool {
        get { prefs?.object(forKey: "compositionEnabled") as? Bool ?? true }
        set {
            prefs?.set(newValue, forKey: "compositionEnabled")
            notifyInputMethod()
            if newValue { select() } else if Self.currentSourceID == Self.inputMethodID { selectPrevious() }
            refresh()
        }
    }

    private func selectPrevious() {
        let previous = prefs?.string(forKey: "previousInputSource")
        let filter = previous.map { [kTISPropertyInputSourceID as String: $0] as CFDictionary }
        if let filter, let s = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first {
            TISSelectInputSource(s)
        } else if let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
            TISSelectInputSource(ascii)
        }
    }

    var learning: Bool {
        get { prefs?.object(forKey: "learning") as? Bool ?? true }
        set { prefs?.set(newValue, forKey: "learning"); notifyInputMethod(); refresh() }
    }

    private func notifyInputMethod() {
        prefs?.synchronize()
        CFPreferencesAppSynchronize(Self.inputMethodID as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            Self.sharedChange, object: "orbit", userInfo: nil, deliverImmediately: true)
    }

    // MARK: State

    func refresh() {
        if case .working = status { return }
        installedVersion = Self.version(installed)
        isSelected = Self.currentSourceID == Self.inputMethodID
        isAdded = Self.addedInKeyboardSettings
        loadWords()
        guard let installedVersion else { status = .notInstalled; return }
        if let bundledVersion, Self.isNewer(bundledVersion, than: installedVersion) { status = .updateAvailable(bundledVersion); return }
        status = isAdded ? .ready : .needsAdding
    }

    /// The user just added Tavi in Keyboard Settings: switch to it, which is what they came for.
    private func sourcesChanged() {
        let wasAdded = isAdded
        refresh()
        if !wasAdded, isAdded, status == .ready, enabled, !isSelected { select() }
    }

    private static func version(_ app: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == inputMethodID else { return nil }
        let release = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(release) (\(build))"
    }

    /// "1.1.5 (10)" → "1.1.5".
    private static func release(_ version: String?) -> String? { version?.split(separator: " ").first.map(String.init) }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        return parts(b).lexicographicallyPrecedes(parts(a))
    }

    private static var source: TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: inputMethodID] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    /// Keyboard Settings' own list, the one macOS keeps across logins.
    private static var addedInKeyboardSettings: Bool {
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let list = CFPreferencesCopyAppValue("AppleEnabledInputSources" as CFString, "com.apple.HIToolbox" as CFString) as? [[String: Any]] ?? []
        return list.contains { ($0["Bundle ID"] as? String) == inputMethodID || ($0["Input Mode"] as? String)?.hasPrefix(inputMethodID) == true }
    }

    private static var currentSourceID: String? {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let v = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(v).takeUnretainedValue() as String
    }

    // MARK: Install / select

    /// Installs or updates the input method. Registering and selecting are done by the input method
    /// itself (`--register-input-source`, `--select-input-source`), as Tavi's own installer does:
    /// macOS only honors those from the input method's process.
    /// - Parameter quietly: an automatic update — opens nothing and selects Tavi again only if it was selected.
    func install(quietly: Bool = false) async {
        guard let bundled else { status = .failed("This build of Orbit doesn’t include Tavi.".loc); return }
        status = .working(quietly ? "Updating Tavi…".loc : "Installing Tavi…".loc)
        let wasSelected = Self.currentSourceID == Self.inputMethodID
        if let current = Self.currentSourceID, current != Self.inputMethodID { prefs?.set(current, forKey: "previousInputSource") }
        do {
            if wasSelected, let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                TISSelectInputSource(ascii)
            }
            await stopRunningInputMethod()
            let fm = FileManager.default
            try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = installed.deletingLastPathComponent().appendingPathComponent(".Tavi.orbit-\(UUID().uuidString).app")
            try fm.copyItem(at: bundled, to: staging)
            if fm.fileExists(atPath: installed.path) {
                guard Self.version(installed) != nil else { throw CocoaError(.fileWriteFileExists) }
                _ = try fm.replaceItemAt(installed, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: installed)
            }
            try await Self.run(installed, ["--register-input-source"])
            try await Self.run(installed, ["--input-source-registered"])
            TaviLog.write("installed \(Self.version(installed) ?? "?")")
            status = .notInstalled
            refresh()
            if status == .ready, quietly ? wasSelected : enabled { await selectNow() }
            else if status == .needsAdding, !quietly { openKeyboardSettings() }
        } catch {
            TaviLog.write("install failed: \(error)")
            status = .failed("Couldn’t install Tavi: %@".loc(error.localizedDescription))
            if wasSelected, Self.version(installed) != nil { try? await Self.run(installed, ["--select-input-source"]) }
        }
    }

    /// Switches to Tavi. Until it's in Keyboard Settings there's nothing to switch to, so that opens
    /// the settings instead.
    func select() {
        guard isAdded || Self.addedInKeyboardSettings else { refresh(); openKeyboardSettings(); return }
        Task { await selectNow() }
    }

    private func selectNow() async {
        if let current = Self.currentSourceID, current != Self.inputMethodID { prefs?.set(current, forKey: "previousInputSource") }
        // A freshly registered source can take a moment before macOS lets it be selected.
        for delay in [0.0, 0.5, 1.0, 2.0] {
            try? await Task.sleep(for: .seconds(delay))
            if (try? await Self.run(installed, ["--select-input-source"])) != nil { break }
        }
        refresh()
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources")!)
    }

    private func stopRunningInputMethod() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.inputMethodID) {
            app.terminate()
            for _ in 0..<25 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(200)) }
            if !app.isTerminated { app.forceTerminate() }
        }
    }

    private enum RunFailure: Error, LocalizedError {
        case exited(Int32, String)
        var errorDescription: String? {
            if case .exited(let code, let output) = self { return "Tavi exited with \(code). \(output)" }
            return nil
        }
    }

    /// Runs the input method's own command-line actions.
    @discardableResult
    private static func run(_ bundle: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = bundle.appendingPathComponent("Contents/MacOS/Tavi")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else { throw RunFailure.exited(process.terminationStatus, String(text.suffix(400))) }
            return text
        }.value
    }

    // MARK: Updates

    /// Tavi's releases; the standalone app updated itself from here, so without it Orbit does.
    private static let repo = "3x-haust/tavi"
    /// The maintainer's Ed25519 key (Tavi's `TaviUpdatePublicKey`); only archives it signed are installed.
    private static let publicKey = Data(base64Encoded: "k6crVb3PuDp1IXIJMFq7CmoR9SXKo6JaV15oivGtEOM=")!

    enum UpdateState: Equatable { case idle, checking, upToDate, downloading, failed(String) }
    private(set) var updateState: UpdateState = .idle
    @ObservationIgnored private var updateTimer: Timer?

    var autoUpdate: Bool {
        get { Pref.defaults.object(forKey: "tavi.autoUpdate") as? Bool ?? true }
        set { Pref.defaults.set(newValue, forKey: "tavi.autoUpdate"); scheduleUpdates() }
    }

    /// From launch: a first look a minute in, then once a day.
    func startUpdates() {
        refresh()
        scheduleUpdates()
    }

    private func scheduleUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard autoUpdate else { return }
        let first = Timer(timeInterval: 60, repeats: false) { _ in
            MainActor.assumeIsolated {
                let t = TaviBridge.shared
                Task { await t.checkForUpdate(userInitiated: false) }
                let daily = Timer(timeInterval: 24 * 3600, repeats: true) { _ in
                    MainActor.assumeIsolated { Task { await TaviBridge.shared.checkForUpdate(userInitiated: false) } }
                }
                daily.tolerance = 600
                RunLoop.main.add(daily, forMode: .common)
                t.updateTimer = daily
            }
        }
        first.tolerance = 10
        RunLoop.main.add(first, forMode: .common)
        updateTimer = first
    }

    /// Looks for a newer Tavi, fetches and verifies it the way Tavi's own updater does (GitHub's
    /// SHA-256 digest, the maintainer's Ed25519 signature, the code signature), then installs it.
    func checkForUpdate(userInitiated: Bool) async {
        guard installedVersion != nil || Self.version(installed) != nil else { return }
        if !userInitiated { guard autoUpdate else { return } }
        if case .working = status { return }
        updateState = .checking
        // What Orbit already carries may be newer than what's installed.
        if case .updateAvailable = status, !userInitiated { await install(quietly: true) }
        let have = [Self.release(Self.version(installed)), Self.release(bundledVersion)].compactMap { $0 }
            .max { Self.isNewer($1, than: $0) } ?? "0"
        do {
            guard let release = try await Self.latestRelease() else { updateState = .upToDate; return }
            guard Self.isNewer(release.version, than: have) else {
                updateState = .upToDate
                if userInitiated, case .updateAvailable = status { await install(quietly: false) }
                return
            }
            updateState = .downloading
            let helper = try await Self.fetch(release)
            try? FileManager.default.removeItem(at: Self.downloaded)
            try FileManager.default.moveItem(at: helper, to: Self.downloaded)
            TaviLog.write("fetched Tavi \(release.version)")
            await install(quietly: !userInitiated || isAdded)
            updateState = .upToDate
        } catch {
            TaviLog.write("update check failed: \(error)")
            updateState = .failed(error.localizedDescription)
        }
    }

    private struct Release {
        let version: String
        let archive: URL
        let sha256: String
        let signature: URL
    }

    private enum UpdateFailure: Error, LocalizedError {
        case download, checksum, unsigned, bundle, codeSignature
        var errorDescription: String? {
            switch self {
            case .download: "Couldn’t download the update".loc
            case .checksum, .unsigned, .bundle, .codeSignature: "The update didn’t pass its checks, so it wasn’t installed".loc
            }
        }
    }

    private static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Orbit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> ([String: Any], URL)? {
            guard let a = assets.first(where: { $0["name"] as? String == name }),
                  let link = a["browser_download_url"] as? String, let url = URL(string: link), url.scheme == "https" else { return nil }
            return (a, url)
        }
        guard let zip = asset("Tavi-\(version).zip"), let sig = asset("Tavi-\(version).zip.sig"),
              let digest = zip.0["digest"] as? String, digest.hasPrefix("sha256:") else { return nil }
        return Release(version: version, archive: zip.1, sha256: String(digest.dropFirst(7)).lowercased(), signature: sig.1)
    }

    /// Downloads and checks a release; returns the input method inside it.
    private static func fetch(_ release: Release) async throws -> URL {
        let (signature, signed) = try await URLSession.shared.data(from: release.signature)
        guard (signed as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.download }
        let (file, response) = try await URLSession.shared.download(from: release.archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.download }
        let archive = try Data(contentsOf: file, options: .mappedIfSafe)
        guard SHA256.hash(data: archive).map({ String(format: "%02x", $0) }).joined() == release.sha256 else { throw UpdateFailure.checksum }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: archive) else { throw UpdateFailure.unsigned }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tavi-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard try await tool("/usr/bin/ditto", ["-x", "-k", file.path, folder.path]) else { throw UpdateFailure.bundle }
        let app = folder.appendingPathComponent("Tavi.app")
        let helper = app.appendingPathComponent("Contents/Helpers/TaviInputMethod.app")
        guard Bundle(url: app)?.infoDictionary?["CFBundleIdentifier"] as? String == "dev.3xhaust.tavi",
              Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String == release.version,
              self.release(version(helper)) == release.version else { throw UpdateFailure.bundle }
        guard try await tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else { throw UpdateFailure.codeSignature }
        return helper
    }

    private static func tool(_ path: String, _ arguments: [String]) async throws -> Bool {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    // MARK: Personal words

    private func loadWords() {
        guard let data = try? Data(contentsOf: wordsURL), let list = try? JSONDecoder().decode([Word].self, from: data) else { words = []; return }
        words = list.sorted { $0.confirmations != $1.confirmations ? $0.confirmations > $1.confirmations : $0.raw < $1.raw }
    }

    func setWord(raw: String, text: String) {
        let raw = raw.trimmingCharacters(in: .whitespaces), text = text.trimmingCharacters(in: .whitespaces)
        // Same rule as Tavi's own store: typed keys are printable ASCII, the result has no whitespace.
        guard !raw.isEmpty, !text.isEmpty, raw.count <= 64, text.count <= 64,
              raw.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            Toast.show("Type the keys without spaces, up to 64 characters", symbol: "exclamationmark.triangle.fill")
            return
        }
        var list = words
        if let i = list.firstIndex(where: { $0.raw == raw }) { list[i].text = text; list[i].confirmations = max(list[i].confirmations, 3) }
        else { list.append(Word(raw: raw, text: text, confirmations: 3)) }
        save(list)
    }

    func remove(_ word: Word) { save(words.filter { $0.raw != word.raw }) }

    private func save(_ list: [Word]) {
        do {
            try FileManager.default.createDirectory(at: wordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(list).write(to: wordsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: wordsURL.path)
            notifyInputMethod()
        } catch {
            Toast.show("Couldn’t save the word list", symbol: "exclamationmark.triangle.fill")
        }
        loadWords()
    }
}

/// Tavi's install and update steps, in the input log.
enum TaviLog {
    static func write(_ line: String) { ScrollLog.write("tavi: \(line)") }
}
