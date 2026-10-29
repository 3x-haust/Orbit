import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The vault's cryptography, after 1Password's design: two secrets make the unlock key, so a stolen
/// vault file is useless without both the Master Password *and* this Mac's Secret Key.
///
///     password ─ NFKD ─ PBKDF2-HMAC-SHA256 (650,000 rounds, per-vault salt) ─┐
///                                                                         XOR ─→ unlock key (AUK)
///     Secret Key (128 bits, kept in this Mac's Keychain) ─ HKDF-SHA256 ──────┘
///
/// The unlock key only wraps the vault key; the vault key wraps a fresh key per item; each item is
/// AES-256-GCM sealed with its id and the vault's id bound in as associated data, so items can't be
/// swapped between vaults or slots without the tag check failing.
enum VaultCrypto {
    static let iterations: UInt32 = 650_000
    static let formatVersion = 1

    enum Failure: Error, Equatable {
        case wrongPassword
        case damaged
        case randomFailed
    }

    // MARK: Random

    static func random(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.randomFailed }
        return bytes
    }

    /// Overwrites a buffer in a way the optimizer can't drop.
    static func wipe(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        _ = bytes.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    static func wipe(_ data: inout Data) {
        guard !data.isEmpty else { return }
        _ = data.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    // MARK: Unlock key

    /// The account unlock key: PBKDF2 of the password XOR an HKDF of the Secret Key.
    static func unlockKey(password: String, secretKey: [UInt8], salt: [UInt8], accountID: String,
                          iterations: UInt32 = iterations) throws -> SymmetricKey {
        // Same characters typed differently (composed or not, trailing space) must give the same key.
        var pw = Array(password.trimmingCharacters(in: .whitespacesAndNewlines).decomposedStringWithCompatibilityMapping.utf8)
        defer { wipe(&pw) }
        // The PBKDF2 salt is itself derived, so the stored salt alone never feeds the slow hash.
        let derivedSalt = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: salt), salt: Data(accountID.utf8),
                                                 info: Data("orbit-vault-pbkdf2-salt".utf8), outputByteCount: 32)
        var saltBytes = derivedSalt.withUnsafeBytes { Array($0) }
        defer { wipe(&saltBytes) }
        var slow = [UInt8](repeating: 0, count: 32)
        defer { wipe(&slow) }
        let status = pw.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: max(1, pw.count)) { pwPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count, saltBytes, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &slow, slow.count)
            }
        }
        guard status == kCCSuccess else { throw Failure.damaged }
        let sk = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secretKey), salt: Data(accountID.utf8),
                                        info: Data("orbit-vault-secret-key".utf8), outputByteCount: 32)
        var mixed = sk.withUnsafeBytes { Array($0) }
        defer { wipe(&mixed) }
        for i in 0..<32 { mixed[i] ^= slow[i] }
        return SymmetricKey(data: mixed)
    }

    // MARK: Sealing

    static func seal(_ plaintext: Data, key: SymmetricKey, context: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw Failure.damaged }
        return combined
    }

    static func open(_ sealed: Data, key: SymmetricKey, context: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch {
            throw Failure.damaged
        }
    }

    static func wrap(_ key: SymmetricKey, with wrapping: SymmetricKey, context: String) throws -> Data {
        var raw = key.withUnsafeBytes { Data($0) }
        defer { wipe(&raw) }
        return try seal(raw, key: wrapping, context: context)
    }

    static func unwrap(_ wrapped: Data, with wrapping: SymmetricKey, context: String) throws -> SymmetricKey {
        var raw = try open(wrapped, key: wrapping, context: context)
        defer { wipe(&raw) }
        return SymmetricKey(data: raw)
    }

    // MARK: Secret Key

    /// 1Password-style Secret Key text: a version tag, then 26 base-32 characters in groups.
    /// e.g. `O1-7K3QXM-2HD9R-TZQ8W-4NC6Y-PB5MJ`
    static func formatSecretKey(_ bytes: [UInt8]) -> String {
        let chars = base32(bytes)
        var groups: [String] = ["O1"]
        var i = chars.startIndex
        for size in [6, 5, 5, 5, 5] {
            let end = chars.index(i, offsetBy: size, limitedBy: chars.endIndex) ?? chars.endIndex
            groups.append(String(chars[i..<end]))
            i = end
        }
        return groups.joined(separator: "-")
    }

    static func parseSecretKey(_ text: String) -> [UInt8]? {
        var t = text.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard t.hasPrefix("O1") else { return nil }
        t.removeFirst(2)
        guard let bytes = base32Decode(t), bytes.count == 16 else { return nil }
        return bytes
    }

    /// Crockford's alphabet: no I, L, O or U to misread when copying the key off paper.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static func base32(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    private static func base32Decode(_ s: String) -> [UInt8]? {
        var out: [UInt8] = []
        var buffer = 0, bits = 0
        for c in s {
            let c: Character = c == "O" ? "0" : (c == "I" || c == "L") ? "1" : c
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
