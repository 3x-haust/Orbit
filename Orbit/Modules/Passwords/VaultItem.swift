import Foundation

/// One thing kept in the vault. Everything here — the title too — is only ever stored encrypted.
struct VaultItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case login, note, card, identity
        var id: String { rawValue }

        var title: String {
            switch self {
            case .login: "Login"
            case .note: "Secure Note"
            case .card: "Credit Card"
            case .identity: "Identity"
            }
        }

        var plural: String {
            switch self {
            case .login: "Logins"
            case .note: "Secure Notes"
            case .card: "Credit Cards"
            case .identity: "Identities"
            }
        }

        var symbol: String {
            switch self {
            case .login: "key.horizontal"
            case .note: "note.text"
            case .card: "creditcard"
            case .identity: "person.text.rectangle"
            }
        }
    }

    struct Field: Codable, Hashable, Identifiable {
        var id = UUID()
        var label: String
        var value: String
        /// Shown as dots until revealed, like a password.
        var concealed = false
    }

    struct OldPassword: Codable, Hashable {
        var value: String
        var replaced: Date
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var favorite = false
    var tags: [String] = []
    var created = Date()
    var updated = Date()
    /// When the password itself last changed — Watchtower's "old" check.
    var passwordChanged: Date?

    // Login
    var username = ""
    var password = ""
    var urls: [String] = []
    /// `otpauth://` URI or a bare base-32 secret.
    var totp = ""
    var passwordHistory: [OldPassword] = []

    // Card
    var cardholder = ""
    var cardNumber = ""
    var cardExpiry = ""
    var cardCode = ""
    var cardPIN = ""

    // Identity
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var address = ""
    var company = ""

    var notes = ""
    var fields: [Field] = []

    init(kind: Kind, title: String = "") {
        self.kind = kind
        self.title = title
    }

    /// The second line in lists.
    var subtitle: String {
        switch kind {
        case .login: username.isEmpty ? (urls.first.map(Self.host) ?? "") : username
        case .note: String(notes.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        case .card: cardNumber.count >= 4 ? "•••• " + String(cardNumber.filter(\.isNumber).suffix(4)) : cardholder
        case .identity: [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    var hosts: [String] { urls.map(Self.host).filter { !$0.isEmpty } }

    /// `https://www.example.com/login` → `example.com`.
    static func host(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        let withScheme = t.contains("://") ? t : "https://" + t
        var h = URLComponents(string: withScheme)?.host?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Same site: equal hosts, or one is a subdomain of the other's registrable part (`accounts.google.com` ↔ `google.com`).
    static func sameSite(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return a.hasSuffix("." + registrable(b)) || b.hasSuffix("." + registrable(a)) || registrable(a) == registrable(b)
    }

    /// A rough registrable domain: the last two labels, three for `co.kr`-style suffixes.
    static func registrable(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let secondLevel: Set<String> = ["co", "com", "net", "org", "ac", "go", "or", "ne", "gov", "edu"]
        let n = secondLevel.contains(String(parts[parts.count - 2])) && parts.last!.count == 2 ? 3 : 2
        return parts.suffix(n).joined(separator: ".")
    }

    /// Text searched by the list and Quick Access.
    var searchText: String {
        ([title, username, notes, cardholder, email, company] + urls + tags + fields.filter { !$0.concealed }.map(\.label))
            .joined(separator: " ").lowercased()
    }

    mutating func setPassword(_ new: String) {
        guard new != password else { return }
        if !password.isEmpty { passwordHistory.insert(.init(value: password, replaced: Date()), at: 0) }
        password = new
        passwordChanged = Date()
    }
}
