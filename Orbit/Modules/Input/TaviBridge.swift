import AppKit
import Carbon

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

    private let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/Tavi.app")
    private var bundled: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TaviInputMethod.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private let wordsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tavi/words.json")
    private let prefs = UserDefaults(suiteName: inputMethodID)

    var bundledVersion: String? { bundled.flatMap(Self.version) }
    var standaloneAppInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Tavi.app") }

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
        loadWords()
        guard let installedVersion else { status = .notInstalled; return }
        if let bundledVersion, Self.isNewer(bundledVersion, than: installedVersion) { status = .updateAvailable(bundledVersion); return }
        status = Self.source.map(Self.isEnabled) == true ? .ready : .needsAdding
    }

    private static func version(_ app: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == inputMethodID else { return nil }
        let release = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(release) (\(build))"
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        return parts(b).lexicographicallyPrecedes(parts(a))
    }

    private static var source: TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: inputMethodID] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    private static func isEnabled(_ s: TISInputSource) -> Bool {
        guard let v = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsEnabled) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(v).takeUnretainedValue())
    }

    private static var currentSourceID: String? {
        guard let s = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let v = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(v).takeUnretainedValue() as String
    }

    // MARK: Install / select

    func install() async {
        guard let bundled else { status = .failed("This build of Orbit doesn’t include Tavi.".loc); return }
        status = .working("Installing Tavi…".loc)
        do {
            if Self.currentSourceID == Self.inputMethodID, let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
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
            guard TISRegisterInputSource(installed as CFURL) == noErr else { throw CocoaError(.featureUnsupported) }
            status = .notInstalled
            refresh()
            if status == .needsAdding { openKeyboardSettings() } else { select() }
        } catch {
            status = .failed("Couldn’t install Tavi: %@".loc(error.localizedDescription))
        }
    }

    func select() {
        guard let s = Self.source else { return }
        if let current = Self.currentSourceID, current != Self.inputMethodID { prefs?.set(current, forKey: "previousInputSource") }
        TISEnableInputSource(s)
        TISSelectInputSource(s)
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
