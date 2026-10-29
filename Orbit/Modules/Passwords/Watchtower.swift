import CryptoKit
import Foundation

/// Finds logins worth fixing: weak, reused, old, and (opt-in) ones that appeared in a breach.
enum Watchtower {
    enum Issue: String, CaseIterable, Identifiable {
        case breached, reused, weak, old
        var id: String { rawValue }

        var title: String {
            switch self {
            case .breached: "Exposed in a breach"
            case .reused: "Reused passwords"
            case .weak: "Weak passwords"
            case .old: "Not changed in a year"
            }
        }

        var detail: String {
            switch self {
            case .breached: "These passwords showed up in leaked password lists. Change them first."
            case .reused: "One leak would open every account that shares the password."
            case .weak: "Easy for a computer to guess. Make a new one with the generator."
            case .old: "Older passwords have had longer to leak."
            }
        }

        var symbol: String {
            switch self {
            case .breached: "exclamationmark.shield"
            case .reused: "repeat"
            case .weak: "lock.open"
            case .old: "clock.arrow.circlepath"
            }
        }
    }

    /// Local checks only; nothing leaves the Mac.
    static func scan(_ items: [VaultItem], breached: Set<UUID> = []) -> [Issue: [VaultItem]] {
        let logins = items.filter { $0.kind == .login && !$0.password.isEmpty }
        var byPassword: [String: [VaultItem]] = [:]
        for item in logins { byPassword[item.password, default: []].append(item) }
        let yearAgo = Date().addingTimeInterval(-365 * 86_400)
        return [
            .breached: logins.filter { breached.contains($0.id) },
            .reused: byPassword.values.filter { $0.count > 1 }.flatMap { $0 },
            .weak: logins.filter { PasswordStrength.level($0.password) <= .weak },
            .old: logins.filter { ($0.passwordChanged ?? $0.created) < yearAgo },
        ]
    }

    /// Have I Been Pwned's range API, k-anonymity style: only the first 5 hex characters of each
    /// password's SHA-1 are sent, and the match is made here. Requests are padded so their size says nothing.
    static func checkBreaches(_ items: [VaultItem]) async -> Set<UUID> {
        var byPrefix: [String: [(UUID, String)]] = [:]
        for item in items where item.kind == .login && !item.password.isEmpty {
            let hex = Insecure.SHA1.hash(data: Data(item.password.utf8)).map { String(format: "%02X", $0) }.joined()
            byPrefix[String(hex.prefix(5)), default: []].append((item.id, String(hex.dropFirst(5))))
        }
        var found: Set<UUID> = []
        for (prefix, entries) in byPrefix {
            guard let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)") else { continue }
            var request = URLRequest(url: url)
            request.setValue("true", forHTTPHeaderField: "Add-Padding")
            request.setValue("Orbit-Passwords", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            var counts: [Substring: Int] = [:]
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":")
                if parts.count == 2, let n = Int(parts[1].trimmingCharacters(in: .whitespaces)), n > 0 { counts[parts[0]] = n }
            }
            for (id, suffix) in entries where counts[Substring(suffix)] != nil { found.insert(id) }
        }
        return found
    }
}
