import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Small Keychain items for the vault, in this Mac's login keychain only: never synced, and only Orbit
/// (by its code signature) can read them without asking.
enum VaultKeychain {
    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    @discardableResult
    static func save(_ data: Data, service: String, account: String) -> Bool {
        delete(service: service, account: account)
        var item = query(service, account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Orbit Passwords"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(service: String, account: String) -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// The Secret Key lives on this Mac (and on the Emergency Kit), never in the vault file.
enum SecretKeyStore {
    private static let service = "com.lyu.orbit.passwords.secret-key"

    static func save(_ key: [UInt8], account: String) -> Bool {
        VaultKeychain.save(Data(key), service: service, account: account)
    }

    static func read(account: String) -> [UInt8]? {
        guard var data = VaultKeychain.read(service: service, account: account), data.count == 16 else { return nil }
        defer { VaultCrypto.wipe(&data) }
        return Array(data)
    }

    static func delete(account: String) { VaultKeychain.delete(service: service, account: account) }
}

/// Touch ID (or a paired Apple Watch) unlock, enforced by the Secure Enclave rather than by Orbit:
/// the vault key is sealed with a key agreed against a Secure Enclave key that only works after the
/// fingerprint check, and that key never leaves the chip. Adding or removing a fingerprint
/// invalidates it, and the Master Password is needed again.
enum BiometricUnlock {
    private static let service = "com.lyu.orbit.passwords.biometric"

    private struct Stored: Codable {
        var enclaveKey: Data
        var ephemeralPublic: Data
        var sealedVaultKey: Data
    }

    static var isAvailable: Bool {
        SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func isEnabled(account: String) -> Bool { VaultKeychain.read(service: service, account: account) != nil }

    private static func accessControl() -> SecAccessControl? {
        // Fingerprint or the watch; falls back to fingerprint only on Macs that refuse the combination.
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                        [.privateKeyUsage, .biometryCurrentSet, .or, .companion], nil)
            ?? SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                               [.privateKeyUsage, .biometryCurrentSet], nil)
    }

    static func enable(vaultKey: SymmetricKey, account: String) throws {
        guard let access = accessControl() else { throw VaultCrypto.Failure.damaged }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        // The other half is thrown away: only the enclave key can redo this agreement.
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
        let wrapping = wrappingKey(shared, account)
        let stored = Stored(enclaveKey: enclave.dataRepresentation,
                            ephemeralPublic: ephemeral.publicKey.x963Representation,
                            sealedVaultKey: try VaultCrypto.wrap(vaultKey, with: wrapping, context: "orbit-bio:\(account)"))
        guard VaultKeychain.save(try JSONEncoder().encode(stored), service: service, account: account) else {
            throw VaultCrypto.Failure.damaged
        }
    }

    /// Shows the Touch ID sheet; nil if it was cancelled or failed.
    static func unlock(account: String, reason: String) async -> SymmetricKey? {
        guard let data = VaultKeychain.read(service: service, account: account),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let context = LAContext()
        context.localizedReason = reason
        context.localizedFallbackTitle = ""
        return await Task.detached {
            do {
                let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: stored.enclaveKey,
                                                                              authenticationContext: context)
                let other = try P256.KeyAgreement.PublicKey(x963Representation: stored.ephemeralPublic)
                let shared = try enclave.sharedSecretFromKeyAgreement(with: other)
                return try VaultCrypto.unwrap(stored.sealedVaultKey, with: wrappingKey(shared, account), context: "orbit-bio:\(account)")
            } catch {
                return nil
            }
        }.value
    }

    static func disable(account: String) { VaultKeychain.delete(service: service, account: account) }

    private static func wrappingKey(_ shared: SharedSecret, _ account: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(account.utf8),
                                       sharedInfo: Data("orbit-biometric-unlock".utf8), outputByteCount: 32)
    }
}

/// Orbit's own face check as an extra way in. Weaker than Touch ID — the camera match is checked by
/// Orbit, not by the Secure Enclave — so it's opt-in and says so. The vault key it releases is kept in
/// the Keychain item only Orbit can read, sealed with a key that's also there.
enum FaceVaultKey {
    private static let service = "com.lyu.orbit.passwords.face"

    static func isEnabled(account: String) -> Bool { VaultKeychain.read(service: service, account: account) != nil }

    static func enable(vaultKey: SymmetricKey, account: String) -> Bool {
        var raw = vaultKey.withUnsafeBytes { Data($0) }
        defer { VaultCrypto.wipe(&raw) }
        return VaultKeychain.save(raw, service: service, account: account)
    }

    /// Only call after a successful face match.
    static func release(account: String) -> SymmetricKey? {
        guard var raw = VaultKeychain.read(service: service, account: account), raw.count == 32 else { return nil }
        defer { VaultCrypto.wipe(&raw) }
        return SymmetricKey(data: raw)
    }

    static func disable(account: String) { VaultKeychain.delete(service: service, account: account) }
}
