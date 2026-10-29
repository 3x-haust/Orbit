import Foundation

/// The Korean web spell checkers, reached the way the open-source hanspell (MIT) and py-hanspell
/// projects do. Unofficial: used only after the user agrees, each request times out after 4 s, and
/// any failure hands over to the next engine. The text is never logged.
@MainActor
enum WebSpell {
    static let timeout: TimeInterval = 4
    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// No cache, no cookies kept, nothing written to disk.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout + 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    /// One fix as a checker reports it: the 어절 as written and what it should be.
    struct Fix {
        var original: String
        var replacement: String
        var kind: SpellKind
        var reason: String?
        var detail: String?
    }

    // MARK: Daum (dic.daum.net)

    static func daum(_ text: String) async throws -> (String, [SpellHint]) {
        try await run(text, maxChars: 1000, maxWords: .max) { chunk in
            var request = URLRequest(url: URL(string: "https://dic.daum.net/grammar_checker.do")!)
            request.httpMethod = "POST"
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = form(["sentence": chunk]).data(using: .utf8)
            let html = try await fetch(request, engine: "Daum")
            guard html.contains("맞춤법 검사기 본문") else { throw SpellError.engine("Daum’s spell checker answered in a way Orbit doesn’t understand.".loc) }
            return parseDaum(html)
        }
    }

    static func parseDaum(_ html: String) -> [Fix] {
        var fixes: [Fix] = []
        let marks = html.ranges(of: "data-error-type")
        for (i, mark) in marks.enumerated() {
            guard let tagEnd = html[mark.lowerBound...].firstIndex(of: ">") else { continue }
            let tag = String(html[mark.lowerBound..<tagEnd])
            var attrs: [String: String] = [:]
            for m in tag.matches(of: #/data-error-(\w+)="([^"]*)"/#) { attrs[String(m.1)] = decode(String(m.2)) }
            guard let input = attrs["input"], let output = attrs["output"], !input.isEmpty else { continue }
            // Its help: between this mark and the next.
            let blockEnd = i + 1 < marks.count ? marks[i + 1].lowerBound : html.endIndex
            let block = String(html[tagEnd..<blockEnd])
            let help = items(in: block, list: "help")
            let examples = items(in: block, list: "examples")
            let kind: SpellKind = switch attrs["type"] ?? "" {
            case "space": .spacing
            case "spell", "space_spell": .spelling
            case "doubt", "style", "recommend": .wording
            default: .grammar
            }
            var detail = help.joined(separator: "\n")
            if !examples.isEmpty { detail += (detail.isEmpty ? "" : "\n\n") + "예문\n" + examples.map { "· " + $0 }.joined(separator: "\n") }
            fixes.append(Fix(original: input, replacement: output, kind: kind,
                             reason: help.first.flatMap { $0 == "도움말이 없습니다." ? nil : $0 }, detail: detail.nilIfBlank))
        }
        return fixes
    }

    private static func items(in block: String, list id: String) -> [String] {
        guard let start = block.range(of: "id=\"\(id)\""), let end = block[start.upperBound...].range(of: "</ul>") else { return [] }
        let inner = String(block[start.upperBound..<end.lowerBound])
        return inner.matches(of: #/<li>(.*?)<\/li>/#.dotMatchesNewlines()).map { clean(String($0.1)) }.filter { !$0.isEmpty }
    }

    // MARK: Naver (SpellerProxy, with the passport key from the search page)

    private static var passportKey: String?

    static func naver(_ text: String) async throws -> (String, [SpellHint]) {
        // Its GET query has a length limit of about 100 Korean words.
        try await run(text, maxChars: 300, maxWords: 80) { chunk in
            var body = try await naverRequest(chunk)
            if body.contains("유효한 키가 아닙니다") { passportKey = nil; body = try await naverRequest(chunk) }
            guard let open = body.firstIndex(of: "("), let close = body.lastIndex(of: ")"), open < close,
                  let json = try? JSONSerialization.jsonObject(with: Data(body[body.index(after: open)..<close].utf8)) as? [String: Any],
                  let message = json["message"] as? [String: Any]
            else { throw SpellError.engine("Naver’s spell checker answered in a way Orbit doesn’t understand.".loc) }
            guard let result = message["result"] as? [String: Any] else {
                throw SpellError.engine("Naver’s spell checker didn’t check the text.".loc)
            }
            return parseNaver(result)
        }
    }

    static func parseNaver(_ result: [String: Any]) -> [Fix] {
        guard (result["errata_count"] as? Int ?? 0) > 0,
              let origin = result["origin_html"] as? String, let fixed = result["html"] as? String else { return [] }
        let originals = origin.matches(of: #/<span class='result_underline'>(.*?)<\/span>/#.dotMatchesNewlines()).map { decode(String($0.1)) }
        let fixes = fixed.matches(of: #/<em class='([a-z]+)_text'>(.*?)<\/em>/#.dotMatchesNewlines()).map { (String($0.1), decode(strip(String($0.2)))) }
        return zip(originals, fixes).compactMap { o, f in
            let (kind, reason): (SpellKind, String?) = switch f.0 {
            case "red": (.spelling, nil)
            case "green": (.spacing, nil)
            case "blue": (.wording, "Probably not standard Korean".loc)
            default: (.wording, "Reads more naturally this way".loc)
            }
            return o == f.1 ? nil : Fix(original: o, replacement: f.1, kind: kind, reason: reason)
        }
    }

    private static func naverRequest(_ chunk: String) async throws -> String {
        let key = try await naverKey()
        var c = URLComponents(string: "https://m.search.naver.com/p/csearch/ocontent/util/SpellerProxy")!
        c.queryItems = [.init(name: "_callback", value: "jQuery"), .init(name: "q", value: chunk), .init(name: "where", value: "nexearch"),
                        .init(name: "color_blindness", value: "0"), .init(name: "passportKey", value: key)]
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: c.url!)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://search.naver.com/", forHTTPHeaderField: "Referer")
        return try await fetch(request, engine: "Naver")
    }

    private static func naverKey() async throws -> String {
        if let passportKey { return passportKey }
        var request = URLRequest(url: URL(string: "https://search.naver.com/search.naver?query=%EB%A7%9E%EC%B6%A4%EB%B2%95+%EA%B2%80%EC%82%AC%EA%B8%B0")!)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let page = try await fetch(request, engine: "Naver")
        guard let m = page.firstMatch(of: #/passportKey=([a-f0-9]+)/#) else {
            throw SpellError.engine("Naver’s spell checker didn’t let Orbit in.".loc)
        }
        passportKey = String(m.1)
        return passportKey!
    }

    // MARK: Shared

    /// Checks the text a chunk at a time (0.4 s apart, as hanspell does) and applies each chunk's
    /// fixes to the text as written, so spaces and line breaks stay exactly the user's.
    private static func run(_ text: String, maxChars: Int, maxWords: Int, check: (String) async throws -> [Fix]) async throws -> (String, [SpellHint]) {
        var corrected = ""
        var hints: [SpellHint] = []
        for (i, chunk) in chunks(text, maxChars: maxChars, maxWords: maxWords).enumerated() {
            try Task.checkCancellation()
            if i > 0 { try await Task.sleep(for: .milliseconds(400)) }
            let body = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { corrected += chunk; continue }
            let (fixed, h) = apply(try await check(body), to: chunk)
            corrected += fixed
            hints += h
        }
        return (corrected, hints)
    }

    /// Pieces of at most `maxChars` characters and `maxWords` words, cut after a sentence or a line
    /// where possible. Together they are the text.
    static func chunks(_ text: String, maxChars: Int, maxWords: Int) -> [String] {
        let tokens = SpellDiff.tokens(text).map(\.text)
        var out: [String] = []
        var current: [String] = []
        var size = 0
        func ends(_ t: String) -> Bool {
            t.contains(where: \.isNewline) || t.trimmingCharacters(in: .whitespaces).last.map { ".?!。…".contains($0) } == true
        }
        for t in tokens {
            if !current.isEmpty, size + t.count > maxChars || current.count + 1 > maxWords {
                // Back to the last sentence end in this piece, if there is one.
                if let cut = current.lastIndex(where: ends), cut < current.count - 1 {
                    out.append(current[...cut].joined())
                    current = Array(current[(cut + 1)...])
                } else {
                    out.append(current.joined())
                    current = []
                }
                size = current.reduce(0) { $0 + $1.count }
            }
            current.append(t)
            size += t.count
        }
        if !current.isEmpty { out.append(current.joined()) }
        return out
    }

    /// Each fix, in order, at the next place its 어절 appears (spaces in it match any run of spaces).
    static func apply(_ fixes: [Fix], to chunk: String) -> (String, [SpellHint]) {
        var out = chunk
        var from = out.startIndex
        var hints: [SpellHint] = []
        for f in fixes where f.original != f.replacement {
            guard let r = find(f.original, in: out, from: from) ?? find(f.original, in: out, from: out.startIndex) else { continue }
            let written = String(out[r])
            out.replaceSubrange(r, with: f.replacement)
            from = out.index(r.lowerBound, offsetBy: f.replacement.count, limitedBy: out.endIndex) ?? out.endIndex
            hints.append(SpellHint(original: written, replacement: f.replacement, reason: f.reason, kind: f.kind, detail: f.detail))
        }
        return (out, hints)
    }

    private static func find(_ token: String, in s: String, from: String.Index) -> Range<String.Index>? {
        guard from <= s.endIndex else { return nil }
        if let r = s.range(of: token, range: from..<s.endIndex) { return r }
        let words = token.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard words.count > 1, let re = try? NSRegularExpression(pattern: words.joined(separator: "\\s+")) else { return nil }
        let ns = NSRange(from..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, range: ns), let r = Range(m.range, in: s) else { return nil }
        return r
    }

    /// The last request to each checker: they turn away calls that come too close together.
    private static var lastRequest: [String: Date] = [:]

    private static func fetch(_ request: URLRequest, engine: String) async throws -> String {
        if let last = lastRequest[engine], Date().timeIntervalSince(last) < 0.4 {
            try await Task.sleep(for: .seconds(0.4 - Date().timeIntervalSince(last)))
        }
        lastRequest[engine] = Date()
        var request = request
        request.timeoutInterval = timeout
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let e as URLError where e.code == .timedOut { throw SpellError.network("%@ took too long to answer.".loc(engine.loc)) }
        catch { throw SpellError.network("Couldn’t reach %@’s spell checker.".loc(engine.loc)) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SpellError.network("Couldn’t reach %@’s spell checker.".loc(engine.loc)) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func form(_ fields: [String: String]) -> String {
        var c = URLComponents()
        c.queryItems = fields.map { .init(name: $0.key, value: $0.value) }
        return c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
    }

    // MARK: HTML

    static func clean(_ html: String) -> String {
        decode(strip(html.replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n")))
            .replacingOccurrences(of: "\t", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strip(_ s: String) -> String { s.replacing(#/<[^>]*>/#, with: "") }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        out = out.replacing(#/&#(x?)([0-9a-fA-F]+);/#) { m in
            let n = UInt32(String(m.2), radix: m.1.isEmpty ? 10 : 16)
            return n.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(m.0)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
