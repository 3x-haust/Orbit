import Foundation

// The parts of snippets that don't touch the system — what was typed, what it turns into — kept
// Foundation-only so they can be checked on their own.

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var keyword: String
    var content: String
    var folder: String = ""
    var enabled = true
    var created = Date()
    var used = 0
}

/// The last few characters typed, as the keyboard produced them.
struct SnippetBuffer {
    enum Trigger: String, CaseIterable { case immediate, delimiter }

    struct Match: Equatable {
        let keyword: String
        /// The space or tab that set it off, already in the text after the keyword.
        let delimiter: Character?
    }

    private(set) var text = ""
    static let capacity = 48
    static let delimiters: Set<Character> = [" ", "\t"]

    mutating func type(_ s: String) {
        text += s
        if text.count > Self.capacity { text = String(text.suffix(Self.capacity)) }
    }

    mutating func backspace() { if !text.isEmpty { text.removeLast() } }
    mutating func reset() { text = "" }

    /// The longest keyword the buffer now ends with. With `.delimiter`, only once a space or tab
    /// follows it. `waitForDelimiter` holds back keywords that would expand mid-composition (a Hangul
    /// syllable still being built): they fire on the next space or tab instead.
    func match(_ keywords: [String], trigger: Trigger, waitForDelimiter: (String) -> Bool = { _ in false }) -> Match? {
        guard !text.isEmpty else { return nil }
        let sorted = keywords.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        if let last = text.last, Self.delimiters.contains(last) {
            let before = String(text.dropLast())
            if let k = sorted.first(where: { before.hasSuffix($0) && (trigger == .delimiter || waitForDelimiter($0)) }) {
                return Match(keyword: k, delimiter: last)
            }
        }
        guard trigger == .immediate else { return nil }
        if let k = sorted.first(where: { text.hasSuffix($0) && !waitForDelimiter($0) }) {
            return Match(keyword: k, delimiter: nil)
        }
        return nil
    }
}

/// Fills in a snippet's placeholders.
enum SnippetTemplate {
    struct Context {
        var clipboard: String = ""
        var now = Date()
        var inputs: [String: String] = [:]
        /// Another snippet's content by its name or keyword, for `{snippet:…}`.
        var lookup: (String) -> String? = { _ in nil }
        var locale = Locale.current
    }

    struct Result: Equatable {
        let text: String
        /// Characters between `{cursor}` and the end: how far to step back after inserting.
        let cursorFromEnd: Int
    }

    /// `{input:Name}` fields in order of appearance, each once — nested snippets included.
    static func inputs(in content: String, lookup: (String) -> String? = { _ in nil }, depth: Int = 0) -> [String] {
        var names: [String] = []
        for token in tokens(content) {
            if token.hasPrefix("input:") {
                let name = String(token.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            } else if token.hasPrefix("snippet:"), depth < 5, let inner = lookup(String(token.dropFirst(8))) {
                for n in inputs(in: inner, lookup: lookup, depth: depth + 1) where !names.contains(n) { names.append(n) }
            }
        }
        return names
    }

    static func render(_ content: String, _ ctx: Context) -> Result {
        let marker = "\u{E000}" // stands in for {cursor} until the end
        var out = expand(content, ctx, depth: 0, cursor: marker)
        var fromEnd = 0
        if let r = out.range(of: marker) {
            fromEnd = out[r.upperBound...].count
            out.removeSubrange(r)
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return Result(text: out, cursorFromEnd: fromEnd)
    }

    private static func expand(_ content: String, _ ctx: Context, depth: Int, cursor: String) -> String {
        var out = ""
        var i = content.startIndex
        while i < content.endIndex {
            let ch = content[i]
            if ch == "{", let close = content[i...].firstIndex(of: "}"),
               let value = value(String(content[content.index(after: i)..<close]), ctx, depth: depth, cursor: cursor) {
                out += value
                i = content.index(after: close)
            } else {
                out.append(ch)
                i = content.index(after: i)
            }
        }
        return out
    }

    /// nil leaves the braces as typed.
    private static func value(_ token: String, _ ctx: Context, depth: Int, cursor: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        let (head, arg): (String, String?) = {
            guard let colon = t.firstIndex(of: ":") else { return (t.lowercased(), nil) }
            return (t[..<colon].lowercased(), String(t[t.index(after: colon)...]))
        }()
        switch head {
        case "clipboard": return ctx.clipboard
        case "cursor": return cursor
        case "uuid": return UUID().uuidString
        case "date", "time", "datetime":
            let f = DateFormatter()
            f.locale = ctx.locale
            if let arg, !arg.isEmpty {
                f.dateFormat = arg
            } else {
                f.dateStyle = head == "time" ? .none : .medium
                f.timeStyle = head == "date" ? .none : .short
            }
            return f.string(from: ctx.now)
        case "input":
            guard let arg else { return nil }
            return ctx.inputs[arg.trimmingCharacters(in: .whitespaces)] ?? ""
        case "snippet":
            guard let arg, depth < 5, let inner = ctx.lookup(arg) else { return depth < 5 ? nil : "" }
            return expand(inner, ctx, depth: depth + 1, cursor: cursor)
        default: return nil
        }
    }

    private static func tokens(_ content: String) -> [String] {
        var found: [String] = []
        var rest = content[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            found.append(rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
            rest = rest[rest.index(after: close)...]
        }
        return found
    }
}

/// What a run of keys becomes on the standard Korean 2-set (두벌식) keyboard: typed in 한글 mode,
/// ";addr" lands in the field as ";ㅁㅇㅇㄱ", and that's what has to be deleted.
enum Dubeolsik {
    private static let consonants: [Character: Character] = [
        "r": "ㄱ", "R": "ㄲ", "s": "ㄴ", "e": "ㄷ", "E": "ㄸ", "f": "ㄹ", "a": "ㅁ", "q": "ㅂ", "Q": "ㅃ",
        "t": "ㅅ", "T": "ㅆ", "d": "ㅇ", "w": "ㅈ", "W": "ㅉ", "c": "ㅊ", "z": "ㅋ", "x": "ㅌ", "v": "ㅍ", "g": "ㅎ",
    ]
    private static let vowels: [Character: Character] = [
        "k": "ㅏ", "o": "ㅐ", "O": "ㅒ", "i": "ㅑ", "j": "ㅓ", "p": "ㅔ", "P": "ㅖ", "u": "ㅕ",
        "h": "ㅗ", "y": "ㅛ", "n": "ㅜ", "b": "ㅠ", "m": "ㅡ", "l": "ㅣ",
    ]
    private static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let medials = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    private static let finals: [Character?] = [nil] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ").map { $0 }
    private static let vowelPairs: [String: Character] = ["ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"]
    private static let finalPairs: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ",
        "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]

    static func hasLetters(_ s: String) -> Bool { s.contains { jamo($0) != nil } }

    /// Whether the run ends inside a syllable the input method is still composing.
    static func endsComposing(_ s: String) -> Bool { s.last.map { jamo($0) != nil } ?? false }

    private static func jamo(_ c: Character) -> (Character, Bool)? {
        if let j = consonants[c] { return (j, true) }
        if let j = vowels[c] ?? vowels[Character(c.lowercased())] { return (j, false) }
        if let j = consonants[Character(c.lowercased())] { return (j, true) }
        return nil
    }

    static func compose(_ keys: String) -> String {
        var out = ""
        var cho: Character?, jung: Character?, jong: Character?

        func commit() {
            if let c = cho, let v = jung, let ci = initials.firstIndex(of: c), let vi = medials.firstIndex(of: v) {
                let fi = finals.firstIndex(of: jong) ?? 0
                out.unicodeScalars.append(Unicode.Scalar(0xAC00 + (ci * 21 + vi) * 28 + fi)!)
            } else {
                if let c = cho { out.append(c) }
                if let v = jung { out.append(v) }
                if let f = jong { out.append(f) }
            }
            cho = nil; jung = nil; jong = nil
        }

        for key in keys {
            guard let (j, isConsonant) = jamo(key) else { commit(); out.append(key); continue }
            if isConsonant {
                if cho != nil, jung != nil, jong == nil, finals.contains(j) {
                    jong = j
                } else if let f = jong, let pair = finalPairs["\(f)\(j)"] {
                    jong = pair
                } else {
                    commit(); cho = j
                }
            } else {
                if let f = jong {
                    // The final consonant moves on to start the next syllable.
                    var next = f
                    if let (pair, _) = finalPairs.first(where: { $0.value == f }) {
                        jong = pair.first; next = pair.last!
                    } else {
                        jong = nil
                    }
                    commit()
                    cho = next; jung = j
                } else if let v = jung {
                    if let pair = vowelPairs["\(v)\(j)"] { jung = pair } else { commit(); jung = j }
                } else {
                    jung = j
                }
            }
        }
        commit()
        return out
    }
}
