import CommonCrypto
import Foundation
import SQLite3
import Security

/// Reads saved logins out of a Chromium-based browser already installed for this user — the same thing
/// 1Password's and Bitwarden's importers do. Everything is local: the login database is this user's own
/// file, and the decryption key comes from this user's login Keychain, which macOS gates with its own
/// allow/deny prompt. Nothing is sent anywhere and nothing decrypted is written to disk.
enum ChromiumImport {
    struct Browser: Identifiable {
        let name: String
        /// Application Support folder that holds the profiles.
        let support: String
        /// Keychain service and account for the "Safe Storage" key.
        let keychainService: String
        let keychainAccount: String
        var id: String { name }
    }

    struct Profile: Identifiable {
        let browser: Browser
        let name: String
        let loginData: URL
        var id: String { loginData.path }
    }

    /// The Chromium browsers Orbit knows, by their Application Support subfolder.
    static let browsers: [Browser] = [
        .init(name: "Chrome", support: "Google/Chrome", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        .init(name: "Chrome Beta", support: "Google/Chrome Beta", keychainService: "Chrome Safe Storage", keychainAccount: "Chrome"),
        .init(name: "Chrome Canary", support: "Google/Chrome Canary", keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
        .init(name: "Chromium", support: "Chromium", keychainService: "Chromium Safe Storage", keychainAccount: "Chromium"),
        .init(name: "Microsoft Edge", support: "Microsoft Edge", keychainService: "Microsoft Edge Safe Storage", keychainAccount: "Microsoft Edge"),
        .init(name: "Brave", support: "BraveSoftware/Brave-Browser", keychainService: "Brave Safe Storage", keychainAccount: "Brave"),
        .init(name: "Arc", support: "Arc/User Data", keychainService: "Arc Safe Storage", keychainAccount: "Arc"),
        .init(name: "Vivaldi", support: "Vivaldi", keychainService: "Vivaldi Safe Storage", keychainAccount: "Vivaldi"),
        .init(name: "Opera", support: "com.operasoftware.Opera", keychainService: "Opera Safe Storage", keychainAccount: "Opera"),
        .init(name: "Aside", support: "Aside", keychainService: "Aside Safe Storage", keychainAccount: "Aside"),
        .init(name: "Dia", support: "Dia/User Data", keychainService: "Dia Safe Storage", keychainAccount: "Dia"),
    ]

    /// Browsers whose login database is present, with their profiles — found without unlocking anything.
    static func installedProfiles() -> [Profile] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        var out: [Profile] = []
        for browser in browsers {
            let root = base.appendingPathComponent(browser.support, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for profileDir in profileDirectories(in: root) {
                let db = profileDir.appendingPathComponent("Login Data")
                guard FileManager.default.fileExists(atPath: db.path) else { continue }
                out.append(Profile(browser: browser, name: profileDir.lastPathComponent, loginData: db))
            }
        }
        return out
    }

    private static func profileDirectories(in root: URL) -> [URL] {
        var dirs = [root.appendingPathComponent("Default")]
        if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            dirs += entries.filter { $0.lastPathComponent.hasPrefix("Profile ") }
        }
        // Some builds keep "Login Data" straight in the root.
        dirs.append(root)
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Login Data").path) }
    }

    enum Failure: LocalizedError {
        case keyDenied, noKey, unreadable
        var errorDescription: String? {
            switch self {
            case .keyDenied: "macOS didn’t allow access to the browser’s key."
            case .noKey: "Couldn’t find this browser’s Safe Storage key in the Keychain."
            case .unreadable: "Couldn’t read the browser’s login database."
            }
        }
    }

    /// Reads and decrypts one profile's logins. Triggers macOS's own Keychain prompt for the key.
    static func read(_ profile: Profile) throws -> [VaultItem] {
        var key = try safeStorageKey(for: profile.browser)
        defer { VaultCrypto.wipe(&key) }
        return try logins(in: profile.loginData, key: key)
    }

    /// The logins in one "Login Data" file, decrypted with an already-derived key.
    static func logins(in loginData: URL, key: [UInt8]) throws -> [VaultItem] {
        // The live database is locked while the browser runs, so work on a copy, deleted right after.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-import-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.copyItem(at: loginData, to: temp)
            // The WAL may hold the newest rows.
            for suffix in ["-wal", "-shm"] {
                let src = URL(fileURLWithPath: loginData.path + suffix)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: URL(fileURLWithPath: temp.path + suffix))
                }
            }
        } catch { throw Failure.unreadable }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); throw Failure.unreadable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT origin_url, username_value, password_value, date_password_modified FROM logins"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.unreadable }
        defer { sqlite3_finalize(statement) }

        var items: [VaultItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let url = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let username = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            var password = ""
            if let blob = sqlite3_column_blob(statement, 2) {
                let count = Int(sqlite3_column_bytes(statement, 2))
                var data = Data(bytes: blob, count: count)
                defer { VaultCrypto.wipe(&data) }
                password = decrypt(data, key: key) ?? ""
            }
            guard !(username.isEmpty && password.isEmpty) else { continue }
            var item = VaultItem(kind: .login, title: VaultItem.host(url).isEmpty ? url : VaultItem.host(url))
            item.username = username
            item.password = password
            item.urls = url.isEmpty ? [] : [url]
            let micros = sqlite3_column_int64(statement, 3)
            // Chromium time: microseconds since 1601-01-01.
            if micros > 0 { item.passwordChanged = Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600) }
            else if !password.isEmpty { item.passwordChanged = Date() }
            items.append(item)
        }
        return items
    }

    // MARK: Decryption

    /// The per-browser key is sealed in the login Keychain; reading it is what macOS prompts to allow.
    private static func safeStorageKey(for browser: Browser) throws -> [UInt8] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data else { throw Failure.noKey }
            var password = Array(data)
            defer { VaultCrypto.wipe(&password) }
            return deriveKey(from: password)
        case errSecItemNotFound:
            throw Failure.noKey
        default:
            // errSecUserCanceled / errSecAuthFailed when the person denies the Keychain prompt.
            throw Failure.keyDenied
        }
    }

    /// Chromium's scheme: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16-byte key.
    static func deriveKey(from password: [UInt8]) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        password.withUnsafeBufferPointer { pw in
            pw.baseAddress!.withMemoryRebound(to: Int8.self, capacity: max(1, password.count)) { pwPtr in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, password.count, salt, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        return key
    }

    /// `v10`/`v11` prefix, then AES-128-CBC with an all-spaces IV.
    static func decrypt(_ blob: Data, key: [UInt8]) -> String? {
        guard blob.count > 3 else {
            // Rarely, older entries are stored as plain text.
            return String(data: blob, encoding: .utf8)
        }
        let prefix = String(decoding: blob.prefix(3), as: UTF8.self)
        guard prefix == "v10" || prefix == "v11" else {
            return String(data: blob, encoding: .utf8)
        }
        let ciphertext = blob.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = ciphertext.withUnsafeBytes { cipherPtr in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, cipherPtr.baseAddress, ciphertext.count, &output, output.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        var plain = Array(output.prefix(moved))
        defer { VaultCrypto.wipe(&plain) }
        // Newer Chrome prepends a 32-byte SHA-256 of the domain before the password.
        if plain.count > 32, !isLikelyText(plain) {
            let trimmed = Array(plain.dropFirst(32))
            if isLikelyText(trimmed) { return String(bytes: trimmed, encoding: .utf8) }
        }
        return String(bytes: plain, encoding: .utf8)
    }

    private static func isLikelyText(_ bytes: [UInt8]) -> Bool {
        guard let s = String(bytes: bytes, encoding: .utf8) else { return false }
        return !s.unicodeScalars.contains { $0.value < 9 }
    }
}
