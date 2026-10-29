import Foundation

/// The search behind the app window's sidebar field: every page, group and row in the generated
/// index, plus Orbit's actions.
enum SettingsSearch {
    struct Result: Identifiable, Equatable {
        enum Target: Equatable {
            case entry(Int)
            case action(String)
        }
        let target: Target
        let score: Double
        var id: String {
            switch target {
            case .entry(let i): "e\(i)"
            case .action(let a): "a\(a)"
            }
        }
        var entry: SettingsEntry? {
            if case .entry(let i) = target { return SettingsIndex.entries[i] }
            return nil
        }
        static func == (a: Result, b: Result) -> Bool { a.id == b.id }
    }

    /// Weights: what a thing is called beats how it's described, which beats where it lives.
    private static let documents: [SearchDocument] = SettingsIndex.entries.map { e in
        let pageEntry = SettingsIndex.entries.first { $0.kind == .page && $0.page == e.page }
        let titleWeight = e.kind == .row ? 1.0 : e.kind == .page ? 1.02 : 0.9
        var fields: [(String, Double, Bool)] = [
            (e.title, titleWeight, true), (e.titleKo, titleWeight, true),
            (e.subtitle, 0.55, false), (e.subtitleKo, 0.55, false),
            (e.group, 0.45, false), (e.groupKo, 0.45, false),
        ]
        fields += e.labels.map { ($0, 0.6, false) }
        fields += e.keywords.map { ($0, e.kind == .page ? 0.9 : 0.8, false) }
        fields += e.related.map { ($0, 0.5, false) }
        if e.kind != .page, let p = pageEntry {
            fields += [(p.title, 0.4, false), (p.titleKo, 0.4, false)]
        }
        return SearchDocument(fields)
    }

    private static let actionDocuments: [SearchDocument] = SettingsIndex.actions.map { a in
        SearchDocument(a.titles.map { ($0, 0.97, true) } + a.titlesKo.map { ($0, 0.97, true) } + a.keywords.map { ($0, 0.85, false) } + a.related.map { ($0, 0.5, false) })
    }

    static func search(_ text: String, limit: Int = 60) -> [Result] {
        let q = SearchMatcher.Query(text.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var out: [Result] = []
        for (i, d) in documents.enumerated() {
            let s = d.score(q)
            if s > 0 { out.append(Result(target: .entry(i), score: s)) }
        }
        for (i, d) in actionDocuments.enumerated() {
            let s = d.score(q)
            if s > 0 { out.append(Result(target: .action(SettingsIndex.actions[i].id), score: s)) }
        }
        out.sort { $0.score > $1.score }
        // Once something matches well, the long tail of fuzzy guesses is noise.
        if let best = out.first?.score {
            let floor = best >= 750 ? best * 0.55 : best >= 500 ? best * 0.5 : 0
            out = out.filter { $0.score >= floor }
        }
        return Array(out.prefix(limit))
    }

    /// Characters of `display` to highlight for `query`.
    static func marks(_ query: String, in display: String) -> Set<Int> {
        let q = SearchMatcher.Query(query)
        let t = SearchMatcher.Text(display)
        var out = Set<Int>()
        if let h = SearchMatcher.match(q.whole, in: t) { out.formUnion(h.marks) }
        else if let keys = q.asHangul, let h = SearchMatcher.matchHangulKeys(keys, in: t) { out.formUnion(h.marks) }
        if q.tokens.count > 1 {
            for token in q.tokens { if let h = SearchMatcher.match(token, in: t) { out.formUnion(h.marks) } }
        }
        return out
    }
}
