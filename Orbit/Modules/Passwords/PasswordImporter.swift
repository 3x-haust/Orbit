import AppKit
import Foundation

/// When two items are the same login: same username on the same site. Exact hosts only — a look-alike
/// domain must never be merged into a real one.
enum ImportMatch {
    static func sameLogin(_ a: VaultItem, _ b: VaultItem) -> Bool {
        guard a.kind == b.kind else { return false }
        guard a.kind == .login else {
            // Notes, cards and identities: identical title and content.
            return a.title == b.title && a.notes == b.notes && a.cardNumber == b.cardNumber && a.email == b.email
        }
        guard a.username.lowercased() == b.username.lowercased() else { return false }
        let ha = Set(a.hosts), hb = Set(b.hosts)
        if ha.isEmpty, hb.isEmpty { return a.title.lowercased() == b.title.lowercased() }
        return !ha.isDisjoint(with: hb)
    }
}

/// Finds passwords already on this Mac — browsers, password-manager CLIs, or an export the person makes
/// while Orbit watches for it — and turns them into a preview to pick from. Decrypted items only ever live
/// in memory; the one file written is the browser's temporary database copy, deleted right away.
@MainActor @Observable
final class PasswordImporter {
    enum Guided: String, CaseIterable, Identifiable {
        case applePasswords, firefox, onePassword, bitwarden
        var id: String { rawValue }

        var title: String {
            switch self {
            case .applePasswords: "Apple Passwords"
            case .firefox: "Firefox"
            case .onePassword: "1Password"
            case .bitwarden: "Bitwarden"
            }
        }

        var bundleIDs: [String] {
            switch self {
            case .applePasswords: ["com.apple.Passwords"]
            case .firefox: ["org.mozilla.firefox"]
            case .onePassword: ["com.1password.1password", "com.agilebits.onepassword7"]
            case .bitwarden: ["com.bitwarden.desktop"]
            }
        }

        /// Plain steps to make the export, ending where the file lands.
        var steps: [String] {
            switch self {
            case .applePasswords: ["In Passwords, choose File › Export All Passwords…", "Save it to Downloads or the Desktop."]
            case .firefox: ["In Firefox’s Passwords page, open the ··· menu and choose Export Passwords…", "Save it to Downloads or the Desktop."]
            case .onePassword: ["In 1Password, choose File › Export and pick 1PUX.", "Save it to Downloads or the Desktop."]
            case .bitwarden: ["In Bitwarden, choose File › Export Vault and pick .json (not encrypted).", "Save it to Downloads or the Desktop."]
            }
        }

        var extensions: Set<String> {
            switch self {
            case .applePasswords, .firefox: ["csv"]
            case .onePassword: ["1pux", "csv"]
            case .bitwarden: ["json", "csv"]
            }
        }
    }

    enum Source: Identifiable {
        case browser(ChromiumImport.Profile, profiles: Int)
        case onePasswordCLI(String)
        case bitwardenCLI(String)
        case guided(Guided)

        var id: String {
            switch self {
            case .browser(let p, _): "browser:" + p.id
            case .onePasswordCLI: "op"
            case .bitwardenCLI: "bw"
            case .guided(let g): "guided:" + g.rawValue
            }
        }
    }

    struct Candidate: Identifiable {
        enum Status { case new, update, same }
        var item: VaultItem
        var status: Status
        var include: Bool
        var origin: String
        var id: UUID { item.id }
    }

    private(set) var browsers: [Source] = []
    private(set) var tools: [Source] = []
    private(set) var guided: [Guided] = Guided.allCases
    var candidates: [Candidate] = []
    private(set) var busy: String?
    var error: String?
    /// The export Orbit is waiting for, and the file it found (offered to the Trash after importing).
    private(set) var watching: Guided?
    private(set) var exportFile: URL?
    private var watchTask: Task<Void, Never>?

    static let browserBundleIDs: [String: String] = [
        "Chrome": "com.google.Chrome", "Chrome Beta": "com.google.Chrome.beta", "Chrome Canary": "com.google.Chrome.canary",
        "Chromium": "org.chromium.Chromium", "Microsoft Edge": "com.microsoft.edgemac", "Brave": "com.brave.Browser",
        "Arc": "company.thebrowser.Browser", "Vivaldi": "com.vivaldi.Vivaldi", "Opera": "com.operasoftware.Opera",
        "Aside": "at.studio.AsideBrowser", "Dia": "company.thebrowser.dia",
    ]

    // MARK: Finding sources

    func detect() {
        let profiles = ChromiumImport.installedProfiles()
        let perBrowser = Dictionary(grouping: profiles, by: \.browser.name)
        browsers = profiles.map { .browser($0, profiles: perBrowser[$0.browser.name]?.count ?? 1) }
        tools = []
        if let op = Self.executable("op") { tools.append(.onePasswordCLI(op)) }
        if let bw = Self.executable("bw") { tools.append(.bitwardenCLI(bw)) }
        // A CLI covers its app; the guided export stays for people without it.
        guided = Guided.allCases.filter { g in
            switch g {
            case .onePassword: !tools.contains { if case .onePasswordCLI = $0 { true } else { false } }
            case .bitwarden: !tools.contains { if case .bitwardenCLI = $0 { true } else { false } }
            default: true
            }
        }
    }

    static func appURL(_ bundleIDs: [String]) -> URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    static func icon(_ bundleIDs: [String]) -> NSImage? {
        appURL(bundleIDs).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private static func executable(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", NSHomeDirectory() + "/.local/bin/"]
            .map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Reading

    func importBrowser(_ profile: ChromiumImport.Profile) {
        run("Reading %@…".loc(profile.browser.name)) {
            // macOS asks once whether Orbit may use the browser's key.
            try await Task.detached { try ChromiumImport.read(profile) }.value
        } origin: { profile.browser.name }
    }

    func importOnePassword(_ op: String) {
        run("Asking 1Password…".loc) {
            try await OnePasswordCLI.items(op)
        } origin: { "1Password" }
    }

    func importBitwarden(_ bw: String, masterPassword: String) {
        run("Unlocking Bitwarden…".loc) {
            try await BitwardenCLI.items(bw, masterPassword: masterPassword)
        } origin: { "Bitwarden" }
    }

    func importFile(_ url: URL, origin: String) {
        run("Reading %@…".loc(url.lastPathComponent)) {
            try await Task.detached { try VaultImport.read(url) }.value
        } origin: { origin }
    }

    private func run(_ message: String, _ work: @escaping () async throws -> [VaultItem], origin: @escaping () -> String) {
        guard busy == nil else { return }
        busy = message
        error = nil
        Task {
            do {
                let items = try await work()
                add(items, origin: origin())
                if items.isEmpty { error = "Nothing to import there.".loc }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription?.loc ?? "Couldn’t read the passwords.".loc
            }
            busy = nil
        }
    }

    /// Adds items to the preview, marking ones the vault (or the preview) already has.
    private func add(_ items: [VaultItem], origin: String) {
        let existing = Vault.shared.items
        for item in items {
            if candidates.contains(where: { ImportMatch.sameLogin($0.item, item) && $0.item.password == item.password }) { continue }
            let status: Candidate.Status
            if let old = existing.first(where: { ImportMatch.sameLogin($0, item) }) {
                status = old.password == item.password ? .same : .update
            } else {
                status = .new
            }
            candidates.append(Candidate(item: item, status: status, include: status != .same, origin: origin))
        }
    }

    var selectedCount: Int { candidates.filter(\.include).count }

    /// Puts the chosen items in the vault and clears the preview.
    func commit() -> (added: Int, updated: Int) {
        let chosen = candidates.filter(\.include).map(\.item)
        candidates = []
        return Vault.shared.merge(chosen)
    }

    func discard() {
        candidates = []
        error = nil
    }

    // MARK: Guided exports

    /// Opens the app and waits for its export to appear in Downloads or on the Desktop.
    func startGuided(_ g: Guided) {
        stopWatching()
        watching = g
        exportFile = nil
        error = nil
        if let app = Self.appURL(g.bundleIDs) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            if g == .firefox, let page = URL(string: "about:logins") {
                NSWorkspace.shared.open([page], withApplicationAt: app, configuration: config)
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: config)
            }
        }
        let since = Date().addingTimeInterval(-2)
        watchTask = Task { [weak self] in
            var sizes: [URL: Int] = [:]
            while !Task.isCancelled {
                if let found = Self.newExport(g.extensions, since: since, sizes: &sizes) {
                    self?.found(found, for: g)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
        watching = nil
    }

    private func found(_ url: URL, for g: Guided) {
        watchTask = nil
        watching = nil
        exportFile = url
        importFile(url, origin: g.title)
    }

    /// The export file is plain text; offer to bin it once its items are in the vault.
    func trashExport() {
        guard let url = exportFile else { return }
        NSWorkspace.shared.recycle([url]) { _, _ in }
        exportFile = nil
    }

    func keepExport() { exportFile = nil }

    /// The newest matching file made after `since`, once its size has stopped changing.
    nonisolated private static func newExport(_ extensions: Set<String>, since: Date, sizes: inout [URL: Int]) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        var best: (URL, Date)?
        for dir in ["Downloads", "Desktop"] {
            let folder = home.appendingPathComponent(dir, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for url in entries where extensions.contains(url.pathExtension.lowercased()) {
                guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let date = max(v.creationDate ?? .distantPast, v.contentModificationDate ?? .distantPast)
                guard date >= since, (v.fileSize ?? 0) > 0 else { continue }
                if best == nil || date > best!.1 { best = (url, date) }
            }
        }
        guard let (url, _) = best, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        defer { sizes[url] = size }
        return sizes[url] == size ? url : nil
    }
}

// MARK: - Command-line tools

/// Runs a password manager's own CLI. Its unlock prompt (1Password's app integration, Touch ID) is its own;
/// Orbit only reads what it prints, in memory.
enum CLI {
    struct Result { let status: Int32; var out: Data; let err: String }

    static func run(_ path: String, _ args: [String], env: [String: String] = [:], input: Data? = nil) async -> Result {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            for (k, v) in env { environment[k] = v }
            p.environment = environment
            let out = Pipe(), err = Pipe(), inp = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = inp
            do { try p.run() } catch { return Result(status: -1, out: Data(), err: error.localizedDescription) }
            if let input { try? inp.fileHandleForWriting.write(contentsOf: input) }
            try? inp.fileHandleForWriting.close()
            // Read both pipes while it runs, so a big vault can't fill a pipe and stall the tool.
            async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let (data, errData) = await (o, e)
            p.waitUntilExit()
            return Result(status: p.terminationStatus, out: data, err: String(decoding: errData, as: UTF8.self))
        }.value
    }

    /// `op item get -` prints one pretty-printed JSON object after another; split them at the top level.
    static func jsonObjects(_ data: Data) -> [[String: Any]] {
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return array }
        if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return [one] }
        var out: [[String: Any]] = []
        let bytes = [UInt8](data)
        var depth = 0, start = -1, inString = false, escaped = false
        for (i, b) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x7B: if depth == 0 { start = i }; depth += 1
            case 0x7D:
                depth -= 1
                if depth == 0, start >= 0,
                   let o = try? JSONSerialization.jsonObject(with: Data(bytes[start...i])) as? [String: Any] {
                    out.append(o)
                }
            default: break
            }
        }
        return out
    }
}

enum OnePasswordCLI {
    enum Failure: LocalizedError {
        case notSignedIn, failed(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn: "1Password’s command-line tool isn’t signed in. In 1Password › Settings › Developer, turn on “Integrate with 1Password CLI”, then try again."
            case .failed(let m): m.isEmpty ? "1Password couldn’t export the items." : m
            }
        }
    }

    static func items(_ op: String) async throws -> [VaultItem] {
        var list = await CLI.run(op, ["item", "list", "--format", "json"])
        defer { VaultCrypto.wipe(&list.out) }
        guard list.status == 0 else {
            throw list.err.localizedCaseInsensitiveContains("sign") ? Failure.notSignedIn : Failure.failed(list.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The list goes straight back in: `op item get -` returns every item with its fields in one go.
        var full = await CLI.run(op, ["item", "get", "-", "--format", "json"], input: list.out)
        defer { VaultCrypto.wipe(&full.out) }
        guard full.status == 0 else { throw Failure.failed(full.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return CLI.jsonObjects(full.out).compactMap(item)
    }

    static func item(_ o: [String: Any]) -> VaultItem? {
        let category = (o["category"] as? String ?? "").uppercased()
        let kind: VaultItem.Kind
        switch category {
        case "LOGIN", "PASSWORD": kind = .login
        case "CREDIT_CARD": kind = .card
        case "IDENTITY": kind = .identity
        default: kind = .note
        }
        var item = VaultItem(kind: kind, title: o["title"] as? String ?? "")
        item.favorite = o["favorite"] as? Bool ?? false
        item.tags = o["tags"] as? [String] ?? []
        item.urls = ((o["urls"] as? [[String: Any]]) ?? []).compactMap { $0["href"] as? String }
        for f in (o["fields"] as? [[String: Any]]) ?? [] {
            let value = f["value"] as? String ?? ""
            guard !value.isEmpty else { continue }
            let id = (f["id"] as? String ?? "").lowercased()
            let purpose = (f["purpose"] as? String ?? "").uppercased()
            let type = (f["type"] as? String ?? "").uppercased()
            let label = f["label"] as? String ?? id
            switch (purpose, type, id) {
            case ("USERNAME", _, _): item.username = value
            case ("PASSWORD", _, _): item.password = value
            case ("NOTES", _, _): item.notes = value
            case (_, "OTP", _): item.totp = value
            case (_, _, "cardholder"): item.cardholder = value
            case (_, _, "ccnum"): item.cardNumber = value
            case (_, _, "expiry"): item.cardExpiry = value
            case (_, _, "cvv"): item.cardCode = value
            case (_, _, "pin"): item.cardPIN = value
            case (_, _, "firstname"): item.firstName = value
            case (_, _, "lastname"): item.lastName = value
            case (_, _, "email"): item.email = value
            case (_, _, "company"): item.company = value
            case (_, _, "address"): item.address = value
            case (_, _, let p) where p.contains("phone"): item.phone = value
            default:
                // A password item's single secret, or anything else: keep it, concealed if it was.
                if category == "PASSWORD", item.password.isEmpty, type == "CONCEALED" { item.password = value }
                else { item.fields.append(.init(label: label, value: value, concealed: type == "CONCEALED")) }
            }
        }
        if kind == .login, !item.password.isEmpty { item.passwordChanged = Date() }
        guard !(item.title.isEmpty && item.password.isEmpty && item.notes.isEmpty && item.fields.isEmpty) else { return nil }
        return item
    }
}

enum BitwardenCLI {
    enum Failure: LocalizedError {
        case notLoggedIn, wrongPassword, failed(String)
        var errorDescription: String? {
            switch self {
            case .notLoggedIn: "Bitwarden’s command-line tool isn’t logged in. Run “bw login” in Terminal once, then try again."
            case .wrongPassword: "Bitwarden didn’t accept that master password."
            case .failed(let m): m.isEmpty ? "Bitwarden couldn’t export the items." : m
            }
        }
    }

    static func needsLogin(_ bw: String) async -> Bool {
        let s = await CLI.run(bw, ["status"])
        let status = (try? JSONSerialization.jsonObject(with: s.out) as? [String: Any])?["status"] as? String
        return status == "unauthenticated"
    }

    static func items(_ bw: String, masterPassword: String) async throws -> [VaultItem] {
        if await needsLogin(bw) { throw Failure.notLoggedIn }
        // The password goes through the environment, never the command line where other processes can see it.
        var unlock = await CLI.run(bw, ["unlock", "--passwordenv", "ORBIT_BW_PASSWORD", "--raw"], env: ["ORBIT_BW_PASSWORD": masterPassword])
        defer { VaultCrypto.wipe(&unlock.out) }
        let session = String(decoding: unlock.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard unlock.status == 0, !session.isEmpty else { throw Failure.wrongPassword }
        let env = ["BW_SESSION": session]
        var items = await CLI.run(bw, ["list", "items"], env: env)
        defer { VaultCrypto.wipe(&items.out) }
        let folders = await CLI.run(bw, ["list", "folders"], env: env)
        _ = await CLI.run(bw, ["lock"], env: env)
        guard items.status == 0, let list = try? JSONSerialization.jsonObject(with: items.out) as? [[String: Any]] else {
            throw Failure.failed(items.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let folderList = (try? JSONSerialization.jsonObject(with: folders.out) as? [[String: Any]]) ?? []
        return VaultImport.bitwarden(["items": list, "folders": folderList])
    }
}
