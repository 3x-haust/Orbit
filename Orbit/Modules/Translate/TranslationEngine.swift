import Foundation
#if canImport(Translation)
import Translation
#endif

/// Where translations come from. Google needs nothing; DeepL needs a (free) API key; Apple runs on-device.
enum TranslationEngine: String, CaseIterable, Identifiable {
    case google, deepl, apple
    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .deepl: "DeepL"
        case .apple: "Apple"
        }
    }

    var detail: String {
        switch self {
        case .google: "Free, no setup. Text is sent to Google."
        case .deepl: "Most natural results. Free API key: 500,000 characters a month."
        case .apple: "On-device and private. Works offline."
        }
    }
}

struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [TranslationLanguage] = [
        .init(code: "ko", name: "한국어"), .init(code: "en", name: "English"), .init(code: "ja", name: "日本語"),
        .init(code: "zh-CN", name: "中文 (简体)"), .init(code: "zh-TW", name: "中文 (繁體)"), .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"), .init(code: "de", name: "Deutsch"), .init(code: "it", name: "Italiano"),
        .init(code: "pt", name: "Português"), .init(code: "ru", name: "Русский"), .init(code: "vi", name: "Tiếng Việt"),
        .init(code: "th", name: "ไทย"), .init(code: "id", name: "Bahasa Indonesia"),
    ]

    static func named(_ code: String) -> String {
        if let exact = all.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) { return exact.name }
        // "zh" alone, or region variants Google returns ("zh-tw", "pt-br"…).
        let base = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code
        return all.first { $0.code.lowercased().hasPrefix(base) }?.name ?? code.uppercased()
    }

    /// Same language, ignoring the region ("zh-CN" and "zh-tw" are both Chinese).
    static func same(_ a: String, _ b: String) -> Bool {
        a.split(separator: "-").first?.lowercased() == b.split(separator: "-").first?.lowercased()
    }
}

enum Formality: String, CaseIterable {
    case auto, formal, casual
}

struct TranslationResult: Equatable {
    var text: String
    var detectedSource: String?
    var engine: TranslationEngine
}

enum TranslationError: LocalizedError {
    case needsKey, badKey, quota, network(String), unsupported

    var errorDescription: String? {
        switch self {
        case .needsKey: "Add a DeepL API key in Orbit › Translate.".loc
        case .badKey: "DeepL didn’t accept the API key.".loc
        case .quota: "DeepL’s monthly free limit is used up.".loc
        case .network(let s): s
        case .unsupported: "Apple Translation can’t translate this language pair yet.".loc
        }
    }
}

enum Translator {
    /// The language a string is most likely written in — decides which way to translate.
    static func guessLanguage(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        let hangul = scalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count
        let kana = scalars.filter { (0x3040...0x30FF).contains($0.value) }.count
        let han = scalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let latin = scalars.filter { CharacterSet.letters.contains($0) && $0.isASCII }.count
        let total = max(1, hangul + kana + han + latin)
        if Double(hangul) / Double(total) > 0.3 { return "ko" }
        if kana > 0 { return "ja" }
        if Double(han) / Double(total) > 0.3 {
            // A few everyday characters only Traditional Chinese uses.
            let traditional = Set("國語學體廣門們這說話時來對開關東車馬鳥魚從會個後過還點電視號應當實發經")
            return text.contains(where: { traditional.contains($0) }) ? "zh-TW" : "zh-CN"
        }
        if Double(latin) / Double(total) > 0.6 { return "en" }
        return nil
    }

    /// Korean, Japanese and Chinese are told apart by their script alone, more reliably than Google's
    /// auto-detect (which calls short Chinese text "en"). Latin-script text is left to the engine.
    static func scriptLanguage(_ text: String) -> String? {
        guard let guess = guessLanguage(text), ["ko", "ja", "zh-CN", "zh-TW"].contains(guess) else { return nil }
        return guess
    }

    static func translate(_ text: String, to target: String, from source: String?, engine: TranslationEngine,
                          formality: Formality, deeplKey: String) async throws -> TranslationResult {
        switch engine {
        case .google: try await google(text, to: target, from: source)
        case .deepl: try await deepl(text, to: target, from: source, formality: formality, key: deeplKey)
        case .apple: try await apple(text, to: target, from: source)
        }
    }

    // MARK: Google (the public web endpoint Chrome's translate bar uses)

    private static func google(_ text: String, to target: String, from source: String?) async throws -> TranslationResult {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [
            .init(name: "client", value: "gtx"), .init(name: "sl", value: source ?? "auto"),
            .init(name: "tl", value: target), .init(name: "dt", value: "t"), .init(name: "dj", value: "1"),
        ]
        var request = URLRequest(url: c.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [.init(name: "q", value: text)]
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        request.timeoutInterval = 12

        let (data, response) = try await fetch(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentences = json["sentences"] as? [[String: Any]]
        else { throw TranslationError.network("Google didn’t answer. Try again in a moment.".loc) }
        let joined = sentences.compactMap { $0["trans"] as? String }.joined()
        return TranslationResult(text: joined, detectedSource: json["src"] as? String, engine: .google)
    }

    // MARK: DeepL

    private static func deepl(_ text: String, to target: String, from source: String?, formality: Formality, key: String) async throws -> TranslationResult {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.needsKey }
        let host = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        var request = URLRequest(url: URL(string: "\(host)/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["text": [text], "target_lang": deeplCode(target, target: true)]
        if let source { payload["source_lang"] = deeplCode(source, target: false) }
        switch formality {
        case .auto: break
        case .formal: payload["formality"] = "prefer_more"
        case .casual: payload["formality"] = "prefer_less"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 403: throw TranslationError.badKey
        case 456: throw TranslationError.quota
        default: throw TranslationError.network("DeepL didn’t answer. Try again in a moment.".loc)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["translations"] as? [[String: Any]])?.first,
              let out = first["text"] as? String
        else { throw TranslationError.network("DeepL sent something Orbit couldn’t read.".loc) }
        return TranslationResult(text: out, detectedSource: (first["detected_source_language"] as? String)?.lowercased(), engine: .deepl)
    }

    private static func deeplCode(_ code: String, target: Bool) -> String {
        switch code {
        case "en": target ? "EN-US" : "EN"
        case "pt": target ? "PT-BR" : "PT"
        case "zh-CN": target ? "ZH-HANS" : "ZH"
        case "zh-TW": target ? "ZH-HANT" : "ZH"
        default: code.uppercased()
        }
    }

    // MARK: Apple (on-device)

    private static func apple(_ text: String, to target: String, from source: String?) async throws -> TranslationResult {
        #if canImport(Translation)
        let src = Locale.Language(identifier: source ?? guessLanguage(text) ?? "en")
        let dst = Locale.Language(identifier: target)
        let availability = LanguageAvailability()
        guard await availability.status(from: src, to: dst) == .installed else { throw TranslationError.unsupported }
        let session = TranslationSession(installedSource: src, target: dst)
        let response = try await session.translate(text)
        return TranslationResult(text: response.targetText, detectedSource: source, engine: .apple)
        #else
        throw TranslationError.unsupported
        #endif
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: request) }
        catch { throw TranslationError.network("You seem to be offline.".loc) }
    }
}
