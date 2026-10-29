import Foundation

/// Reads other password managers' exports. Everything is parsed in memory; nothing is written out.
enum VaultImport {
    enum Source: String, CaseIterable, Identifiable {
        case onePassword, csv, bitwarden, orbit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .onePassword: "1Password (.1pux)"
            case .csv: "CSV (1Password, Chrome, Edge, Brave, Apple Passwords, Bitwarden)"
            case .bitwarden: "Bitwarden (.json)"
            case .orbit: "Orbit export (.orbitpasswords)"
            }
        }
    }

    enum Failure: LocalizedError {
        case unreadable, needsPassword, unknownFormat
        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t read that file."
            case .needsPassword: "This export is locked with a password."
            case .unknownFormat: "This doesn’t look like a password export Orbit knows."
            }
        }
    }

    /// Picks the reader from the file itself.
    static func read(_ url: URL, exportPassword: String? = nil) throws -> [VaultItem] {
        if url.pathExtension.lowercased() == "1pux" { return try onePUX(url) }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        if VaultExport.isExport(data) {
            guard let exportPassword else { throw Failure.needsPassword }
            return try VaultExport.open(data, password: exportPassword)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["items"] != nil {
            return bitwarden(json)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw Failure.unreadable }
        let items = csv(text)
        guard !items.isEmpty else { throw Failure.unknownFormat }
        return items
    }

    // MARK: CSV

    /// Matches columns by name, so one reader covers every app's CSV.
    static func csv(_ text: String) -> [VaultItem] {
        let rows = parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return [] }
        func col(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        let title = col(["title", "name"]), url = col(["url", "website", "login_uri", "web site", "urls"])
        let user = col(["username", "login_username", "login name", "user", "email"])
        let pass = col(["password", "login_password"]), notes = col(["notes", "note", "extra", "comments"])
        let otp = col(["otpauth", "otp", "totp", "login_totp", "one-time password"]), fav = col(["favorite"])
        let tags = col(["tags", "folder", "grouping"])
        guard pass != nil || notes != nil else { return [] }
        return rows.dropFirst().compactMap { row -> VaultItem? in
            func v(_ i: Int?) -> String { i.flatMap { row.indices.contains($0) ? row[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? "" }
            let password = v(pass), username = v(user), site = v(url)
            guard !(password.isEmpty && username.isEmpty && v(notes).isEmpty) else { return nil }
            var item = VaultItem(kind: password.isEmpty && username.isEmpty ? .note : .login,
                                 title: v(title).isEmpty ? VaultItem.host(site) : v(title))
            item.username = username
            item.password = password
            item.urls = site.isEmpty ? [] : site.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            item.totp = v(otp)
            item.notes = v(notes)
            item.favorite = ["1", "true", "yes"].contains(v(fav).lowercased())
            item.tags = v(tags).split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            item.passwordChanged = password.isEmpty ? nil : Date()
            return item
        }
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")).makeIterator()
        var pending: Character?
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    // MARK: Bitwarden JSON

    static func bitwarden(_ json: [String: Any]) -> [VaultItem] {
        let folders = Dictionary(((json["folders"] as? [[String: Any]]) ?? []).compactMap { f -> (String, String)? in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            return (id, name)
        }, uniquingKeysWith: { a, _ in a })
        return ((json["items"] as? [[String: Any]]) ?? []).compactMap { e in
            let type = e["type"] as? Int ?? 1
            let kind: VaultItem.Kind = switch type { case 2: .note; case 3: .card; case 4: .identity; default: .login }
            var item = VaultItem(kind: kind, title: e["name"] as? String ?? "")
            item.notes = e["notes"] as? String ?? ""
            item.favorite = e["favorite"] as? Bool ?? false
            if let folder = e["folderId"] as? String, let name = folders[folder] { item.tags = [name] }
            if let login = e["login"] as? [String: Any] {
                item.username = login["username"] as? String ?? ""
                item.password = login["password"] as? String ?? ""
                item.totp = login["totp"] as? String ?? ""
                item.urls = ((login["uris"] as? [[String: Any]]) ?? []).compactMap { $0["uri"] as? String }
                item.passwordChanged = (login["passwordRevisionDate"] as? String).flatMap(isoDate) ?? Date()
            }
            if let card = e["card"] as? [String: Any] {
                item.cardholder = card["cardholderName"] as? String ?? ""
                item.cardNumber = card["number"] as? String ?? ""
                item.cardCode = card["code"] as? String ?? ""
                let m = card["expMonth"] as? String ?? "", y = card["expYear"] as? String ?? ""
                item.cardExpiry = m.isEmpty ? y : "\(m)/\(y.suffix(2))"
            }
            if let id = e["identity"] as? [String: Any] {
                item.firstName = id["firstName"] as? String ?? ""
                item.lastName = id["lastName"] as? String ?? ""
                item.email = id["email"] as? String ?? ""
                item.phone = id["phone"] as? String ?? ""
                item.company = id["company"] as? String ?? ""
                item.address = ["address1", "address2", "city", "state", "postalCode", "country"]
                    .compactMap { id[$0] as? String }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            for f in (e["fields"] as? [[String: Any]]) ?? [] {
                item.fields.append(.init(label: f["name"] as? String ?? "", value: f["value"] as? String ?? "",
                                         concealed: (f["type"] as? Int) == 1))
            }
            return item
        }
    }

    // MARK: 1Password .1pux

    /// A .1pux is a zip with `export.data` (JSON) inside; it's read straight out of the zip into memory.
    static func onePUX(_ url: URL) throws -> [VaultItem] {
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", url.path, "export.data"]
        let out = Pipe()
        unzip.standardOutput = out
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        var data = out.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        defer { VaultCrypto.wipe(&data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unknownFormat }
        var items: [VaultItem] = []
        for account in (json["accounts"] as? [[String: Any]]) ?? [] {
            for vault in (account["vaults"] as? [[String: Any]]) ?? [] {
                let vaultName = ((vault["attrs"] as? [String: Any])?["name"] as? String) ?? ""
                for e in (vault["items"] as? [[String: Any]]) ?? [] where (e["state"] as? String) != "archived" {
                    if let item = onePUXItem(e, vaultName: vaultName) { items.append(item) }
                }
            }
        }
        return items
    }

    private static func onePUXItem(_ e: [String: Any], vaultName: String) -> VaultItem? {
        let overview = e["overview"] as? [String: Any] ?? [:]
        let details = e["details"] as? [String: Any] ?? [:]
        let category = e["categoryUuid"] as? String ?? "001"
        let kind: VaultItem.Kind = switch category { case "002": .card; case "003": .note; case "004": .identity; default: .login }
        var item = VaultItem(kind: kind, title: overview["title"] as? String ?? "")
        item.favorite = (e["favIndex"] as? Int ?? 0) > 0
        item.tags = (overview["tags"] as? [String]) ?? []
        if !vaultName.isEmpty, vaultName != "Personal", vaultName != "Private" { item.tags.append(vaultName) }
        var urls = ((overview["urls"] as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }
        if urls.isEmpty, let u = overview["url"] as? String, !u.isEmpty { urls = [u] }
        item.urls = urls
        item.notes = details["notesPlain"] as? String ?? ""
        if let created = e["createdAt"] as? Double { item.created = Date(timeIntervalSince1970: created) }
        for f in (details["loginFields"] as? [[String: Any]]) ?? [] {
            let value = f["value"] as? String ?? ""
            switch f["designation"] as? String {
            case "username": item.username = value
            case "password": item.password = value
            default: break
            }
        }
        if item.password.isEmpty, let p = details["password"] as? String { item.password = p }
        if !item.password.isEmpty { item.passwordChanged = (e["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date() }
        for section in (details["sections"] as? [[String: Any]]) ?? [] {
            for f in (section["fields"] as? [[String: Any]]) ?? [] {
                let title = f["title"] as? String ?? ""
                let value = f["value"] as? [String: Any] ?? [:]
                if let otp = value["totp"] as? String { item.totp = otp; continue }
                if let s = value["string"] as? String { assign(&item, title: title, value: s, concealed: false); continue }
                if let s = value["concealed"] as? String { assign(&item, title: title, value: s, concealed: true); continue }
                if let s = value["creditCardNumber"] as? String { item.cardNumber = s; continue }
                if let s = value["email"] as? [String: Any], let addr = s["email_address"] as? String { item.email = addr; continue }
                if let s = value["phone"] as? String { item.phone = s; continue }
                if let m = value["monthYear"] as? Int { item.cardExpiry = "\(m % 100)/\(String(m / 100).suffix(2))"; continue }
                if let s = value["url"] as? String { item.urls.append(s); continue }
            }
        }
        return item
    }

    /// Card and identity fields arrive as titled strings.
    private static func assign(_ item: inout VaultItem, title: String, value: String, concealed: Bool) {
        switch title.lowercased() {
        case "cardholder name": item.cardholder = value
        case "verification number", "cvv": item.cardCode = value
        case "pin": item.cardPIN = value
        case "first name": item.firstName = value
        case "last name": item.lastName = value
        case "company": item.company = value
        default: item.fields.append(.init(label: title, value: value, concealed: concealed))
        }
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
