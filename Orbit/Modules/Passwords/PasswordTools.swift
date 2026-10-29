import CryptoKit
import Foundation
import Security

// MARK: - Generator

/// Random, memorable and PIN passwords, drawn with the system's secure random source and no modulo bias.
enum PasswordGenerator {
    enum Style: String, CaseIterable, Identifiable, Codable {
        case random, memorable, pin
        var id: String { rawValue }
        var title: String {
            switch self {
            case .random: "Random"
            case .memorable: "Memorable"
            case .pin: "PIN"
            }
        }
    }

    struct Options: Codable, Equatable {
        var style: Style = .random
        var length = 20
        var digits = true
        var symbols = true
        /// Leaves out 0/O, 1/l/I and the like.
        var avoidAmbiguous = false
        var words = 4
        var separator = "-"
        var capitalize = true
        var pinLength = 6
    }

    static func make(_ o: Options) -> String {
        switch o.style {
        case .random: random(o)
        case .memorable: memorable(o)
        case .pin: (0..<max(4, o.pinLength)).map { _ in String(uniform(10)) }.joined()
        }
    }

    private static func random(_ o: Options) -> String {
        let ambiguous = Set("0O1lI|`'\"")
        func pool(_ s: String) -> [Character] { Array(s).filter { !o.avoidAmbiguous || !ambiguous.contains($0) } }
        let lower = pool("abcdefghijklmnopqrstuvwxyz"), upper = pool("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits = pool("0123456789"), symbols = pool("!@#$%^&*-_=+?.:;~")
        var sets = [lower, upper]
        if o.digits { sets.append(digits) }
        if o.symbols { sets.append(symbols) }
        let all = sets.flatMap { $0 }
        let length = max(8, min(100, o.length))
        // At least one of each kind asked for, then shuffled so they aren't at the front.
        var chars = sets.map { $0[uniform($0.count)] }
        while chars.count < length { chars.append(all[uniform(all.count)]) }
        for i in stride(from: chars.count - 1, to: 0, by: -1) { chars.swapAt(i, uniform(i + 1)) }
        return String(chars)
    }

    private static func memorable(_ o: Options) -> String {
        let list = WordList.words
        var words = (0..<max(3, min(10, o.words))).map { _ in list[uniform(list.count)] }
        if o.capitalize { words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if o.digits { let i = uniform(words.count); words[i] += String(uniform(10)) }
        return words.joined(separator: o.separator)
    }

    /// A uniform integer in 0..<n, by rejection sampling.
    static func uniform(_ n: Int) -> Int {
        precondition(n > 0)
        let bound = UInt32(n)
        let limit = UInt32.max - UInt32.max % bound
        while true {
            var r: UInt32 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &r)
            if r < limit { return Int(r % bound) }
        }
    }

    /// Bits of entropy of what `make` produces with these options — exact, not an estimate.
    static func entropy(_ o: Options) -> Double {
        switch o.style {
        case .random:
            var n = 52.0
            if o.digits { n += 10 }
            if o.symbols { n += 17 }
            return Double(max(8, o.length)) * log2(n)
        case .memorable:
            return Double(max(3, o.words)) * log2(Double(WordList.words.count)) + (o.digits ? log2(10) + log2(Double(o.words)) : 0)
        case .pin:
            return Double(max(4, o.pinLength)) * log2(10)
        }
    }
}

/// Words for memorable passwords: the system dictionary's short common-looking words.
enum WordList {
    static let words: [String] = {
        if let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            let list = text.split(separator: "\n").filter { w in
                (4...7).contains(w.count) && w.allSatisfy { $0.isLowercase && $0.isASCII }
            }.map(String.init)
            if list.count > 5000 { return list }
        }
        return ["orbit", "planet", "comet", "lunar", "solar", "nova", "rocket", "galaxy", "meteor", "nebula", "quasar",
                "cosmic", "zenith", "aurora", "eclipse", "photon", "stellar", "gravity", "saturn", "venus", "mercury",
                "pluto", "titan", "europa", "vector", "signal", "beacon", "harbor", "forest", "river", "meadow", "canyon",
                "glacier", "summit", "valley", "island", "breeze", "ember", "falcon", "otter", "maple", "cedar", "willow",
                "pepper", "ginger", "honey", "cocoa", "lemon", "mango", "olive", "peach", "plum", "berry", "cobalt",
                "copper", "silver", "amber", "coral", "ivory", "jade", "onyx", "pearl", "ruby", "topaz", "velvet"]
    }()
}

// MARK: - Strength

/// A quick, offline strength estimate for passwords the person typed: a guess at the search space,
/// knocked down for common passwords, repeats, sequences and dictionary words.
enum PasswordStrength {
    enum Level: Int, Comparable {
        case terrible, weak, fair, good, great
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .terrible: "Terrible"
            case .weak: "Weak"
            case .fair: "Fair"
            case .good: "Good"
            case .great: "Excellent"
            }
        }
    }

    static func bits(_ p: String) -> Double {
        guard !p.isEmpty else { return 0 }
        let lower = p.lowercased()
        if common.contains(lower) { return 4 }
        var pool = 0
        if p.contains(where: \.isLowercase) { pool += 26 }
        if p.contains(where: \.isUppercase) { pool += 26 }
        if p.contains(where: \.isNumber) { pool += 10 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber && $0.isASCII }) { pool += 33 }
        if p.contains(where: { !$0.isASCII }) { pool += 100 }
        // Count runs and repeats as a single character each.
        var effective = 0.0
        let chars = Array(lower)
        for (i, c) in chars.enumerated() {
            if i > 0, c == chars[i - 1] { effective += 0.2; continue }
            if i > 1, let a = c.asciiValue, let b = chars[i - 1].asciiValue, let d = chars[i - 2].asciiValue,
               Int(a) - Int(b) == Int(b) - Int(d), abs(Int(a) - Int(b)) == 1 { effective += 0.3; continue }
            effective += 1
        }
        var bits = effective * log2(Double(max(pool, 10)))
        for w in common where w.count >= 4 && lower.contains(w) { bits -= Double(w.count) * 3; break }
        return max(0, bits)
    }

    static func level(_ p: String) -> Level {
        switch bits(p) {
        case ..<28: .terrible
        case ..<40: .weak
        case ..<60: .fair
        case ..<80: .good
        default: .great
        }
    }

    private static let common: Set<String> = [
        "123456", "password", "12345678", "qwerty", "123456789", "12345", "1234", "111111", "1234567", "dragon",
        "123123", "baseball", "abc123", "football", "monkey", "letmein", "696969", "shadow", "master", "666666",
        "qwertyuiop", "123321", "mustang", "1234567890", "michael", "654321", "superman", "1qaz2wsx", "7777777",
        "121212", "000000", "qazwsx", "123qwe", "killer", "trustno1", "jordan", "jennifer", "zxcvbnm", "asdfgh",
        "hunter", "buster", "soccer", "harley", "batman", "andrew", "tigger", "sunshine", "iloveyou", "2000",
        "charlie", "robert", "thomas", "hockey", "ranger", "daniel", "starwars", "klaster", "112233", "george",
        "computer", "michelle", "jessica", "pepper", "1111", "zxcvbn", "555555", "11111111", "131313", "freedom",
        "777777", "pass", "maggie", "159753", "aaaaaa", "ginger", "princess", "joshua", "cheese", "amanda", "summer",
        "love", "ashley", "nicole", "chelsea", "biteme", "matthew", "access", "yankees", "987654321", "dallas",
        "austin", "thunder", "taylor", "matrix", "admin", "welcome", "passw0rd", "p@ssw0rd", "qwer1234", "asdf1234",
        "sarang", "saranghae", "dkssud", "qwe123", "1q2w3e4r", "1q2w3e", "a123456", "q1w2e3r4", "zaq12wsx",
    ]
}

// MARK: - One-time codes

/// RFC 6238 time-based codes from an `otpauth://totp/…` URI or a bare base-32 secret.
struct TOTP: Equatable {
    enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    var secret: [UInt8]
    var digits = 6
    var period = 30
    var algorithm = Algorithm.sha1
    var issuer: String?
    var account: String?

    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.lowercased().hasPrefix("otpauth://") {
            guard let c = URLComponents(string: t), c.host?.lowercased() == "totp" else { return nil }
            let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard let s = q["secret"], let bytes = Self.base32(s) else { return nil }
            secret = bytes
            digits = Int(q["digits"] ?? "") ?? 6
            period = Int(q["period"] ?? "") ?? 30
            algorithm = Algorithm(rawValue: (q["algorithm"] ?? "SHA1").uppercased()) ?? .sha1
            issuer = q["issuer"]
            let label = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            account = label.split(separator: ":").last.map(String.init)
        } else {
            guard let bytes = Self.base32(t) else { return nil }
            secret = bytes
        }
        guard !secret.isEmpty, (6...8).contains(digits), period > 0 else { return nil }
    }

    func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let value = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var pow: UInt32 = 1
        for _ in 0..<digits { pow *= 10 }
        let s = String(value % pow)
        return String(repeating: "0", count: digits - s.count) + s
    }

    func secondsLeft(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    static func base32(_ s: String) -> [UInt8]? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out: [UInt8] = []
        var buffer = 0, bits = 0
        for c in s.uppercased() where c != "=" && c != " " && c != "-" {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}
