import AppKit
import Observation
import UniformTypeIdentifiers

/// The user's snippets, kept in Application Support/Orbit/snippets.json.
@MainActor @Observable
final class SnippetStore {
    static let shared = SnippetStore()

    private(set) var snippets: [Snippet] = []

    static let enabledKey = "snippets.enabled"
    static let triggerKey = "snippets.trigger"
    static let excludedKey = "snippets.excludedApps"
    static let terminalsKey = "snippets.inTerminals"

    /// Typing a keyword expands it anywhere.
    var enabled: Bool { didSet { Pref.defaults.set(enabled, forKey: Self.enabledKey); SnippetEngine.shared.start() } }
    var trigger: SnippetBuffer.Trigger { didSet { Pref.defaults.set(trigger.rawValue, forKey: Self.triggerKey) } }
    var inTerminals: Bool { didSet { Pref.defaults.set(inTerminals, forKey: Self.terminalsKey) } }
    var excludedApps: [String] { didSet { Pref.defaults.set(excludedApps, forKey: Self.excludedKey) } }

    static let passwordManagers = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
    ]
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty"]

    private static let file = "snippets.json"

    private init() {
        let d = Pref.defaults
        enabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        trigger = d.string(forKey: Self.triggerKey).flatMap(SnippetBuffer.Trigger.init) ?? .immediate
        inTerminals = d.object(forKey: Self.terminalsKey) as? Bool ?? true
        excludedApps = d.stringArray(forKey: Self.excludedKey) ?? Self.passwordManagers
        if let saved = Storage.load([Snippet].self, from: Self.file) {
            snippets = saved
        } else {
            snippets = Self.starters
            save()
        }
    }

    /// A few to show how it works; delete them freely.
    private static var starters: [Snippet] {
        [
            Snippet(name: "Today’s date".loc, keyword: ";date", content: "{date:yyyy-MM-dd}", folder: "Examples".loc),
            Snippet(name: "Current time".loc, keyword: ";time", content: "{time}", folder: "Examples".loc),
            Snippet(name: "Email address".loc, keyword: ";email", content: "you@example.com", folder: "Examples".loc),
            Snippet(name: "Reply greeting".loc, keyword: ";hi",
                    content: "Hi {input:Name},\n\n{cursor}\n\nThanks!".loc, folder: "Examples".loc),
        ]
    }

    var active: [Snippet] { snippets.filter { $0.enabled && !$0.keyword.isEmpty } }
    var folders: [String] { Array(Set(snippets.map(\.folder).filter { !$0.isEmpty })).sorted() }

    func snippet(id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    /// `{snippet:…}` refers to another snippet by name or keyword.
    func content(named name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return snippets.first { $0.keyword == n || $0.name.caseInsensitiveCompare(n) == .orderedSame }?.content
    }

    @discardableResult
    func add(_ s: Snippet = Snippet(name: "", keyword: "", content: "")) -> Snippet {
        snippets.insert(s, at: 0)
        save()
        return s
    }

    func update(_ s: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return }
        snippets[i] = s
        save()
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func markUsed(_ id: UUID) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].used += 1
        save()
    }

    /// Another snippet whose keyword starts this one's (or the other way round): typing the longer
    /// one would expand the shorter one first.
    func clash(for s: Snippet) -> Snippet? {
        guard !s.keyword.isEmpty else { return nil }
        return snippets.first {
            $0.id != s.id && !$0.keyword.isEmpty && ($0.keyword == s.keyword
                || (trigger == .immediate && (s.keyword.hasPrefix($0.keyword) || $0.keyword.hasPrefix(s.keyword))))
        }
    }

    func search(_ query: String) -> [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return snippets.sorted { $0.used > $1.used } }
        return snippets.compactMap { s -> (Snippet, Int)? in
            let score = [Fuzzy.score(q, s.name), Fuzzy.score(q, s.keyword), s.content.localizedCaseInsensitiveContains(q) ? 300 : nil]
                .compactMap { $0 }.max()
            return score.map { (s, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private var saveWork: DispatchWorkItem?

    private func save() {
        saveWork?.cancel()
        let snapshot = snippets
        let work = DispatchWorkItem { Storage.save(snapshot, to: Self.file) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Import

    /// Raycast and Alfred-style JSON, TextExpander CSV (abbreviation,content,label) or plain CSV.
    /// Returns how many came in.
    @discardableResult
    func importFile(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        var found: [Snippet] = []
        if let json = try? JSONSerialization.jsonObject(with: data) {
            found = Self.parseJSON(json)
        } else if let text = String(data: data, encoding: .utf8) {
            found = Self.parseCSV(text)
        }
        let existing = Set(snippets.map(\.keyword))
        let fresh = found.filter { $0.keyword.isEmpty || !existing.contains($0.keyword) }
        snippets.insert(contentsOf: fresh, at: 0)
        save()
        return fresh.count
    }

    private static func parseJSON(_ json: Any) -> [Snippet] {
        // Raycast: [{name, text, keyword}]; Alfred: {alfredsnippet: {name, keyword, snippet}};
        // also anything shaped {snippets: [...]}.
        if let dict = json as? [String: Any] {
            if let inner = dict["alfredsnippet"] { return parseJSON([inner]) }
            if let list = dict["snippets"] { return parseJSON(list) }
            return parseJSON([dict])
        }
        guard let list = json as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let d = (item["alfredsnippet"] as? [String: Any]) ?? item
            let content = (d["text"] ?? d["snippet"] ?? d["content"] ?? d["plainText"]) as? String
            guard let content, !content.isEmpty else { return nil }
            let keyword = (d["keyword"] ?? d["abbreviation"]) as? String ?? ""
            let name = (d["name"] ?? d["label"] ?? d["title"]) as? String
            return Snippet(name: name ?? String(content.prefix(30)), keyword: keyword,
                           content: convertPlaceholders(content), folder: "Imported".loc)
        }
    }

    private static func parseCSV(_ text: String) -> [Snippet] {
        rows(text).compactMap { cols in
            guard cols.count >= 2, !cols[1].isEmpty, cols[0].lowercased() != "abbreviation", cols[0].lowercased() != "keyword" else { return nil }
            let name = cols.count >= 3 && !cols[2].isEmpty ? cols[2] : String(cols[1].prefix(30))
            return Snippet(name: name, keyword: cols[0], content: convertPlaceholders(cols[1]), folder: "Imported".loc)
        }
    }

    /// Raycast `{clipboard}`/`{cursor}` already match; TextExpander `%clipboard`, `%|`, Alfred `{date}`.
    private static func convertPlaceholders(_ s: String) -> String {
        s.replacingOccurrences(of: "%clipboard", with: "{clipboard}")
            .replacingOccurrences(of: "%|", with: "{cursor}")
            .replacingOccurrences(of: "%Y-%m-%d", with: "{date:yyyy-MM-dd}")
    }

    /// A small CSV reader: quoted fields, doubled quotes, newlines inside quotes.
    private static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var it = Array(text).makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else if c != "\r" { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    func exportJSON(to url: URL) {
        let list = snippets.map { ["name": $0.name, "keyword": $0.keyword, "text": $0.content] }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
