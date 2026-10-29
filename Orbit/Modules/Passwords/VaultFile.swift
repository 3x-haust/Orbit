import CryptoKit
import Foundation

/// The vault on disk. Only salts, ids and ciphertext — no titles, no URLs, nothing readable.
struct VaultFile: Codable {
    struct Sealed: Codable {
        var id: UUID
        /// The item's own key, sealed with the vault key.
        var key: Data
        /// The item as JSON, sealed with its own key.
        var blob: Data
    }

    var version = VaultCrypto.formatVersion
    var accountID: String
    var salt: Data
    var iterations: UInt32
    /// The vault key, sealed with the unlock key. Opening it is the password check.
    var vaultKey: Data
    var items: [Sealed] = []
    var created = Date()

    private var keyContext: String { "orbit-vault-key:\(accountID)" }
    private func itemKeyContext(_ id: UUID) -> String { "orbit-item-key:\(accountID):\(id.uuidString)" }
    private func itemContext(_ id: UUID) -> String { "orbit-item:\(accountID):\(id.uuidString)" }

    // MARK: Create & unlock

    /// A new, empty vault and its freshly made vault key.
    static func create(password: String, secretKey: [UInt8], accountID: String = UUID().uuidString) throws -> (VaultFile, SymmetricKey) {
        let salt = try VaultCrypto.random(16)
        let auk = try VaultCrypto.unlockKey(password: password, secretKey: secretKey, salt: salt, accountID: accountID)
        let vaultKey = SymmetricKey(size: .bits256)
        var file = VaultFile(accountID: accountID, salt: Data(salt), iterations: VaultCrypto.iterations, vaultKey: Data())
        file.vaultKey = try VaultCrypto.wrap(vaultKey, with: auk, context: file.keyContext)
        return (file, vaultKey)
    }

    func unlock(password: String, secretKey: [UInt8]) throws -> SymmetricKey {
        let auk = try VaultCrypto.unlockKey(password: password, secretKey: secretKey, salt: Array(salt),
                                            accountID: accountID, iterations: iterations)
        do {
            return try VaultCrypto.unwrap(vaultKey, with: auk, context: keyContext)
        } catch {
            throw VaultCrypto.Failure.wrongPassword
        }
    }

    /// Re-wraps the same vault key under a new password; items stay as they are.
    mutating func changePassword(to password: String, secretKey: [UInt8], vaultKey key: SymmetricKey) throws {
        let newSalt = try VaultCrypto.random(16)
        let auk = try VaultCrypto.unlockKey(password: password, secretKey: secretKey, salt: newSalt, accountID: accountID)
        salt = Data(newSalt)
        iterations = VaultCrypto.iterations
        vaultKey = try VaultCrypto.wrap(key, with: auk, context: keyContext)
    }

    // MARK: Items

    func seal(_ item: VaultItem, vaultKey key: SymmetricKey) throws -> Sealed {
        let itemKey = SymmetricKey(size: .bits256)
        var json = try JSONEncoder().encode(item)
        defer { VaultCrypto.wipe(&json) }
        return Sealed(id: item.id,
                      key: try VaultCrypto.wrap(itemKey, with: key, context: itemKeyContext(item.id)),
                      blob: try VaultCrypto.seal(json, key: itemKey, context: itemContext(item.id)))
    }

    func open(_ sealed: Sealed, vaultKey key: SymmetricKey) throws -> VaultItem {
        let itemKey = try VaultCrypto.unwrap(sealed.key, with: key, context: itemKeyContext(sealed.id))
        var json = try VaultCrypto.open(sealed.blob, key: itemKey, context: itemContext(sealed.id))
        defer { VaultCrypto.wipe(&json) }
        let item = try JSONDecoder().decode(VaultItem.self, from: json)
        // The id inside must be the slot it was found in.
        guard item.id == sealed.id else { throw VaultCrypto.Failure.damaged }
        return item
    }

    // MARK: Disk

    static func read(_ url: URL) throws -> VaultFile {
        try JSONDecoder().decode(VaultFile.self, from: Data(contentsOf: url))
    }

    func write(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A vault export that travels on its own: sealed with an export password only (no Secret Key),
/// so it can be opened on another Mac.
enum VaultExport {
    struct Envelope: Codable {
        var format = "orbit-passwords-export"
        var version = 1
        var salt: Data
        var iterations: UInt32
        var sealed: Data
    }

    private static let context = "orbit-passwords-export-v1"

    static func make(_ items: [VaultItem], password: String) throws -> Data {
        let salt = try VaultCrypto.random(16)
        // No Secret Key here: zeros stand in, so the export password alone opens it.
        let key = try VaultCrypto.unlockKey(password: password, secretKey: [UInt8](repeating: 0, count: 16), salt: salt,
                                            accountID: "export")
        var json = try JSONEncoder().encode(items)
        defer { VaultCrypto.wipe(&json) }
        let envelope = Envelope(salt: Data(salt), iterations: VaultCrypto.iterations,
                                sealed: try VaultCrypto.seal(json, key: key, context: context))
        return try JSONEncoder().encode(envelope)
    }

    static func isExport(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.format == "orbit-passwords-export"
    }

    static func open(_ data: Data, password: String) throws -> [VaultItem] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try VaultCrypto.unlockKey(password: password, secretKey: [UInt8](repeating: 0, count: 16),
                                            salt: Array(envelope.salt), accountID: "export", iterations: envelope.iterations)
        do {
            var json = try VaultCrypto.open(envelope.sealed, key: key, context: context)
            defer { VaultCrypto.wipe(&json) }
            return try JSONDecoder().decode([VaultItem].self, from: json)
        } catch {
            throw VaultCrypto.Failure.wrongPassword
        }
    }
}
