import Foundation

/// One searchable thing in the app window: a page, a group card or a row (built by tools/settings_index.py).
struct SettingsEntry {
    enum Kind { case page, group, row }
    let kind: Kind
    let page: String
    let group: String, groupKo: String
    let title: String, titleKo: String
    let subtitle: String, subtitleKo: String
    let symbol: String
    /// The row titles it may show under (both sides of a ternary title), for scrolling to it.
    let anchors: [String]
    /// The labels of the controls in the row ("Empty Trash…").
    let labels: [String]
    /// Words chosen for it by hand: other apps' names, what people call it.
    let keywords: [String]
    /// Other words for the words it uses, from tools/settings_synonyms.json.
    let related: [String]
}

/// An Orbit action, found by its title and run straight from the results.
struct SettingsActionEntry {
    let id: String
    let titles: [String], titlesKo: [String]
    let keywords: [String]
    let related: [String]
}

/// Matching that understands how people actually type here: Korean half-composed ("잠작" on the way
/// to 잠자기), initial consonants only ("ㅈㅈㄱ"), Korean typed with the keyboard still in English
/// ("wkawkrl"), no spaces ("잠자기방지"), small typos, and other words for the same thing.
enum SearchMatcher {
    // MARK: Prepared text

    /// One character as compared: a lowercased Unicode scalar (Hangul syllables and jamo are one each).
    typealias Unit = UInt32

    /// A string in every form a query is compared against, each character tied back to the original
    /// so the matched letters can be highlighted.
    struct Text {
        /// Lowercased letters and digits, spaces and punctuation dropped.
        let norm: [Unit]
        let normSource: [Int]
        /// Whether `norm[i]` starts a word.
        let wordStart: [Bool]
        /// Hangul split into keystrokes (ㅘ → ㅗㅏ, ㄺ → ㄹㄱ); everything else as in `norm`.
        let jamo: [Unit]
        let jamoSource: [Int]
        let jamoWordStart: [Bool]
        /// The initial consonant of each syllable; other characters as in `norm`.
        let initials: [Unit]
        let hasJamo: Bool

        init(_ s: String) {
            var norm: [Unit] = [], normSource: [Int] = [], starts: [Bool] = []
            var jamo: [Unit] = [], jamoSource: [Int] = [], jamoStarts: [Bool] = []
            var initials: [Unit] = []
            var boundary = true
            var previousLower = false
            var lastHangul: Bool?
            for (i, ch) in s.enumerated() {
                guard ch.isLetter || ch.isNumber else { boundary = true; previousLower = false; continue }
                // camelCase and Latin/Hangul switches start a word too ("Wi-Fi", "EQ프리셋").
                if ch.isUppercase && previousLower { boundary = true }
                previousLower = ch.isLowercase
                guard let u = ch.lowercased().unicodeScalars.first?.value else { continue }
                let hangul = SearchMatcher.isHangul(u)
                if let lastHangul, lastHangul != hangul { boundary = true }
                lastHangul = hangul
                starts.append(boundary)
                norm.append(u); normSource.append(i)
                for (k, key) in SearchMatcher.keystrokes(u).enumerated() {
                    jamo.append(key); jamoSource.append(i); jamoStarts.append(boundary && k == 0)
                }
                initials.append(SearchMatcher.initial(u) ?? u)
                boundary = false
            }
            self.norm = norm; self.normSource = normSource; wordStart = starts
            self.jamo = jamo; self.jamoSource = jamoSource; jamoWordStart = jamoStarts
            self.initials = initials
            hasJamo = jamo.contains(where: SearchMatcher.isJamo)
        }
    }

    /// The query, prepared once per keystroke.
    struct Query {
        let raw: String
        let whole: Text
        let tokens: [Text]
        /// Words like "켜기" or "turn on" that describe the wish rather than the thing.
        let soft: [Bool]
        /// The query as Hangul keystrokes when it looks like Korean typed on an English layout.
        let asHangul: [Unit]?
        var isEmpty: Bool { whole.norm.isEmpty }

        init(_ s: String) {
            raw = s
            whole = Text(s)
            let words = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "›" || $0 == ">" }).map(String.init)
            tokens = words.map(Text.init).filter { !$0.norm.isEmpty }
            soft = words.filter { !Text($0).norm.isEmpty }.map { SearchMatcher.softWords.contains($0.lowercased()) }
            asHangul = SearchMatcher.latinToHangul(s)
        }
    }

    static let softWords: Set<String> = [
        "켜기", "켜", "켜줘", "끄기", "꺼", "꺼줘", "하기", "설정", "설정하기", "바꾸기", "변경", "열기", "보기", "사용", "사용하기", "어디", "방법", "어떻게",
        "turn", "on", "off", "enable", "disable", "set", "setting", "settings", "change", "open", "show", "use", "how", "to", "the", "a", "my",
    ]

    // MARK: Scoring

    struct Hit {
        var score: Double
        /// Matched character indices in the original string.
        var marks: [Int]
    }

    /// How well one query token matches one text, or nil. `fuzzy` adds typo and scattered-letter
    /// matching, which only pays off on names (titles, keywords).
    @_optimize(speed)
    static func match(_ q: Text, in t: Text, fuzzy: Bool = true) -> Hit? {
        let qn = q.norm, tn = t.norm
        guard !qn.isEmpty, !tn.isEmpty else { return nil }
        func marks(_ r: Range<Int>, _ source: [Int]) -> [Int] { r.map { source[$0] } }

        if qn == tn { return Hit(score: 1000, marks: marks(0..<tn.count, t.normSource)) }
        if let r = find(qn, in: tn) {
            let coverage = Double(qn.count) / Double(tn.count)
            if r.lowerBound == 0 { return Hit(score: 880 + 60 * coverage, marks: marks(r, t.normSource)) }
            if t.wordStart[r.lowerBound] { return Hit(score: 800 + 60 * coverage, marks: marks(r, t.normSource)) }
            // Any word-start occurrence beats the first plain one.
            if let w = find(qn, in: tn, from: r.lowerBound + 1, wordStart: t.wordStart) {
                return Hit(score: 800 + 60 * coverage, marks: marks(w, t.normSource))
            }
            // Inside a word: natural for Korean compounds (클립"보드"), mostly noise for short Latin ("eq" in "requires").
            let korean = qn.contains(where: isHangul)
            let inside: Double = korean ? (qn.count >= 2 ? 640 : 300) : qn.count >= 4 ? 600 : qn.count == 3 ? 430 : 180
            return Hit(score: inside + 40 * coverage, marks: marks(r, t.normSource))
        }
        // Korean mid-composition, or typed without the last vowel: compare keystrokes.
        let qj = q.jamo
        if q.hasJamo, qj.count >= 2, t.hasJamo, let r = find(qj, in: t.jamo) {
            let coverage = Double(qj.count) / Double(t.jamo.count)
            let start = r.lowerBound == 0 ? 850.0 : t.jamoWordStart[r.lowerBound] ? 760 : 620
            return Hit(score: start + 40 * coverage, marks: unique(r.map { t.jamoSource[$0] }))
        }
        // ㅈㅈㄱ → 잠자기.
        if qn.count >= 2, t.hasJamo, qn.allSatisfy(isInitialConsonant), let r = find(qn, in: t.initials) {
            let start = r.lowerBound == 0 ? 820.0 : t.wordStart[r.lowerBound] ? 740 : 600
            return Hit(score: start + 30 * Double(qn.count) / Double(tn.count), marks: marks(r, t.normSource))
        }
        guard fuzzy else { return nil }
        // A letter or two off ("bluetoth", "잠지기").
        let korean = q.hasJamo
        if korean && !t.hasJamo { return nil }
        let (needle, hay, starts, source) = korean ? (qj, t.jamo, t.jamoWordStart, t.jamoSource) : (qn, tn, t.wordStart, t.normSource)
        if needle.count >= 4 {
            let allowed = needle.count >= 8 ? 2 : 1
            for start in hay.indices where starts[start] {
                let end = min(hay.count, start + needle.count + allowed)
                guard end - start >= needle.count - allowed else { continue }
                if let (d, len) = prefixDistance(needle, hay, from: start, to: end, limit: allowed) {
                    let score = 520 - Double(d) * 60 + (start == 0 ? 30 : 0)
                    return Hit(score: score, marks: unique((start..<(start + len)).map { source[$0] }))
                }
            }
        }
        // Letters in order, close together ("clphst" → "Clipboard history").
        if needle.count >= 3, let m = subsequence(needle, in: hay) {
            let span = Double(m.last! - m.first! + 1)
            let compact = Double(needle.count) / span
            guard compact >= 0.34 else { return nil }
            let onStarts = m.filter { starts[$0] }.count
            let score = 260 + 180 * compact + 25 * Double(onStarts) + (m.first == 0 ? 30 : 0)
            return Hit(score: min(score, 560), marks: unique(m.map { source[$0] }))
        }
        return nil
    }

    /// The query as Hangul keystrokes, matched against the text's keystrokes.
    @_optimize(speed)
    static func matchHangulKeys(_ keys: [Unit], in t: Text) -> Hit? {
        guard keys.count >= 3, t.hasJamo, let r = find(keys, in: t.jamo) else { return nil }
        let start = r.lowerBound == 0 ? 780.0 : t.jamoWordStart[r.lowerBound] ? 700 : 560
        return Hit(score: start, marks: unique(r.map { t.jamoSource[$0] }))
    }

    private static func unique(_ xs: [Int]) -> [Int] { Array(Set(xs)).sorted() }

    // MARK: Hangul

    static func isHangul(_ v: Unit) -> Bool { (0xAC00...0xD7A3).contains(v) || (0x3131...0x318E).contains(v) }
    static func isJamo(_ v: Unit) -> Bool { (0x3131...0x318E).contains(v) }
    static func isInitialConsonant(_ v: Unit) -> Bool { initialsTable.contains(v) }

    private static func units(_ s: String) -> [Unit] { s.unicodeScalars.map(\.value) }
    private static let initialsTable: [Unit] = units("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let medials: [[Unit]] = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅗㅏ", "ㅗㅐ", "ㅗㅣ", "ㅛ", "ㅜ", "ㅜㅓ", "ㅜㅔ", "ㅜㅣ", "ㅠ", "ㅡ", "ㅡㅣ", "ㅣ"].map(units)
    private static let finals: [[Unit]] = ["", "ㄱ", "ㄲ", "ㄱㅅ", "ㄴ", "ㄴㅈ", "ㄴㅎ", "ㄷ", "ㄹ", "ㄹㄱ", "ㄹㅁ", "ㄹㅂ", "ㄹㅅ", "ㄹㅌ", "ㄹㅍ", "ㄹㅎ", "ㅁ", "ㅂ", "ㅂㅅ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"].map(units)
    /// Compound jamo typed on their own, split the same way.
    private static let compound: [Unit: [Unit]] = Dictionary(uniqueKeysWithValues: [
        ("ㅘ", "ㅗㅏ"), ("ㅙ", "ㅗㅐ"), ("ㅚ", "ㅗㅣ"), ("ㅝ", "ㅜㅓ"), ("ㅞ", "ㅜㅔ"), ("ㅟ", "ㅜㅣ"), ("ㅢ", "ㅡㅣ"),
        ("ㄳ", "ㄱㅅ"), ("ㄵ", "ㄴㅈ"), ("ㄶ", "ㄴㅎ"), ("ㄺ", "ㄹㄱ"), ("ㄻ", "ㄹㅁ"), ("ㄼ", "ㄹㅂ"), ("ㄽ", "ㄹㅅ"), ("ㄾ", "ㄹㅌ"), ("ㄿ", "ㄹㅍ"), ("ㅀ", "ㄹㅎ"), ("ㅄ", "ㅂㅅ"),
    ].map { (units($0.0)[0], units($0.1)) })

    static func keystrokes(_ v: Unit) -> [Unit] {
        if (0xAC00...0xD7A3).contains(v) {
            let i = Int(v - 0xAC00)
            return [initialsTable[i / 588]] + medials[(i % 588) / 28] + finals[i % 28]
        }
        return compound[v] ?? [v]
    }

    static func initial(_ v: Unit) -> Unit? {
        guard (0xAC00...0xD7A3).contains(v) else { return nil }
        return initialsTable[Int(v - 0xAC00) / 588]
    }

    private static let twoSet: [Character: Unit] = {
        let pairs: [(Character, String)] = [
            ("q", "ㅂ"), ("w", "ㅈ"), ("e", "ㄷ"), ("r", "ㄱ"), ("t", "ㅅ"), ("y", "ㅛ"), ("u", "ㅕ"), ("i", "ㅑ"), ("o", "ㅐ"), ("p", "ㅔ"),
            ("a", "ㅁ"), ("s", "ㄴ"), ("d", "ㅇ"), ("f", "ㄹ"), ("g", "ㅎ"), ("h", "ㅗ"), ("j", "ㅓ"), ("k", "ㅏ"), ("l", "ㅣ"),
            ("z", "ㅋ"), ("x", "ㅌ"), ("c", "ㅊ"), ("v", "ㅍ"), ("b", "ㅠ"), ("n", "ㅜ"), ("m", "ㅡ"),
            ("Q", "ㅃ"), ("W", "ㅉ"), ("E", "ㄸ"), ("R", "ㄲ"), ("T", "ㅆ"), ("O", "ㅒ"), ("P", "ㅖ"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, units($0.1)[0]) })
    }()
    private static let vowels = Set(units("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ"))

    /// Two-set (두벌식) keys → jamo keystrokes, for "dlfqks" meaning 일반. Nil for real English words.
    static func latinToHangul(_ s: String) -> [Unit]? {
        let letters = s.filter { !$0.isWhitespace }
        guard letters.count >= 3, letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let keys = letters.map { twoSet[$0] ?? twoSet[Character($0.lowercased())]! }
        // Real Korean has a vowel every few keys and only pairs vowels as ㅘ ㅝ ㅢ and friends.
        let pairable = Set(units("ㅗㅜㅡ"))
        let vowelCount = keys.filter { vowels.contains($0) }.count
        let badPair = (0..<keys.count - 1).contains { vowels.contains(keys[$0]) && vowels.contains(keys[$0 + 1]) && !pairable.contains(keys[$0]) }
        guard vowelCount > 0, vowelCount * 4 >= keys.count, !badPair else { return nil }
        return keys
    }

    // MARK: Primitives

    /// The first occurrence of `needle` at or after `from` (only at word starts, if given).
    @_optimize(speed)
    static func find(_ needle: [Unit], in hay: [Unit], from: Int = 0, wordStart: [Bool]? = nil) -> Range<Int>? {
        let n = needle.count, h = hay.count
        guard n > 0, n <= h, from <= h - n else { return nil }
        let first = needle[0]
        return needle.withUnsafeBufferPointer { nb in
            hay.withUnsafeBufferPointer { hb in
                var i = from
                outer: while i <= h - n {
                    defer { i += 1 }
                    guard hb[i] == first else { continue }
                    if let wordStart, !wordStart[i] { continue }
                    var j = 1
                    while j < n { if hb[i + j] != nb[j] { continue outer }; j += 1 }
                    return i..<(i + n)
                }
                return nil
            }
        }
    }

    /// Tightest in-order run of `needle`'s letters in `hay`.
    @_optimize(speed)
    static func subsequence(_ needle: [Unit], in hay: [Unit]) -> [Int]? {
        var best: [Int]?
        for start in hay.indices where hay[start] == needle[0] {
            var m = [start], j = 1, i = start + 1
            while j < needle.count, i < hay.count {
                if hay[i] == needle[j] { m.append(i); j += 1 }
                i += 1
            }
            guard j == needle.count else { break }
            if best == nil || (m.last! - m.first!) < (best!.last! - best!.first!) { best = m }
        }
        return best
    }

    /// Edit distance (with swaps) between `q` and the best-matching prefix of `hay[from..<to]`, if within `limit`.
    @_optimize(speed)
    static func prefixDistance(_ q: [Unit], _ hay: [Unit], from: Int, to: Int, limit: Int) -> (Int, Int)? {
        let n = q.count, m = to - from
        guard n > 0, m > 0 else { return nil }
        let w = m + 1
        var d = [Int](repeating: 0, count: (n + 1) * w)
        for i in 0...n { d[i * w] = i }
        for j in 0...m { d[j] = j }
        for i in 1...n {
            var rowMin = Int.max
            for j in 1...m {
                let cost = q[i - 1] == hay[from + j - 1] ? 0 : 1
                var v = min(d[(i - 1) * w + j] + 1, d[i * w + j - 1] + 1, d[(i - 1) * w + j - 1] + cost)
                if i > 1, j > 1, q[i - 1] == hay[from + j - 2], q[i - 2] == hay[from + j - 1] { v = min(v, d[(i - 2) * w + j - 2] + 1) }
                d[i * w + j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return nil }
        }
        let lowest = max(1, n - limit)
        guard lowest <= m else { return nil }
        var best: (Int, Int)?
        for j in lowest...m where d[n * w + j] <= limit {
            if best == nil || d[n * w + j] < best!.0 { best = (d[n * w + j], j) }
        }
        return best
    }
}

/// Scores a whole query against a document of weighted fields.
struct SearchDocument {
    struct Field {
        let text: SearchMatcher.Text
        let weight: Double
        /// The field shown as the result's title.
        let display: Bool
    }

    let fields: [Field]

    init(_ fields: [(String, Double, Bool)]) {
        self.fields = fields.filter { !$0.0.isEmpty }.map { Field(text: .init($0.0), weight: $0.1, display: $0.2) }
    }

    /// How well the query matches, 0 for not at all.
    @_optimize(speed)
    func score(_ q: SearchMatcher.Query) -> Double {
        guard !q.isEmpty else { return 0 }
        // The whole query as one string first: "잠자기방지", "clipboard history".
        var whole = 0.0
        for f in fields where f.weight * 1000 > whole {
            if let h = SearchMatcher.match(q.whole, in: f.text, fuzzy: f.weight >= 0.7) { whole = max(whole, h.score * f.weight) }
            if let keys = q.asHangul, let h = SearchMatcher.matchHangulKeys(keys, in: f.text) { whole = max(whole, h.score * 0.92 * f.weight) }
        }
        guard q.tokens.count > 1 else { return whole }
        // Then word by word: every real word must land somewhere.
        var total = 0.0, counted = 0, missed = 0
        for (i, token) in q.tokens.enumerated() {
            var best = 0.0
            for f in fields where f.weight * 1000 > best {
                if let h = SearchMatcher.match(token, in: f.text, fuzzy: f.weight >= 0.7) { best = max(best, h.score * f.weight) }
            }
            if q.soft[i] {
                if best > 0 { total += best * 0.3 }
                continue
            }
            if best <= 0 { missed += 1; continue }
            total += best
            counted += 1
        }
        guard counted > 0 else { return whole }
        let required = q.soft.filter { !$0 }.count
        if missed > (required >= 3 ? 1 : 0) { return whole }
        let words = total / Double(counted) * (missed > 0 ? 0.6 : 1)
        return max(whole * 1.05, words)
    }
}
