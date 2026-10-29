import CryptoKit
import Foundation
import Security
import Vision

/// The enrolled face: Vision feature prints of aligned face crops — never the photos themselves.
/// Sealed with AES-GCM under a key that lives only in this Mac's Keychain (this device, unlocked).
enum FaceStore {
    private static let service = "com.lyu.orbit.facelock"
    private static let account = "faces-key"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Orbit/FaceLock", isDirectory: true)
    }

    private static var file: URL { directory.appendingPathComponent("faces.bin") }

    static var isEnrolled: Bool { FileManager.default.fileExists(atPath: file.path) }

    static func save(_ prints: [VNFeaturePrintObservation]) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: prints as NSArray, requiringSecureCoding: true)
        let sealed = try AES.GCM.seal(data, using: try key(create: true))
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try combined.write(to: file, options: [.atomic, .completeFileProtection])
    }

    static func load() -> [VNFeaturePrintObservation] {
        guard let combined = try? Data(contentsOf: file), let key = try? key(create: false),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let data = try? AES.GCM.open(box, using: key) else { return [] }
        return unarchive(data) ?? []
    }

    /// A feature print archives its time range as nested dictionaries, which macOS 27's secure
    /// decoding refuses when only the print's own class is allowed — every check then found no
    /// enrolled face and gave up before the camera came on. The data is sealed with Orbit's own
    /// key, so the plain property-list classes are safe to allow.
    private static func unarchive(_ data: Data) -> [VNFeaturePrintObservation]? {
        let classes: [AnyClass] = [NSArray.self, NSDictionary.self, NSNumber.self, NSString.self, NSValue.self,
                                   NSData.self, VNFeaturePrintObservation.self]
        if let prints = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [VNFeaturePrintObservation] {
            return prints
        }
        guard let reader = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        reader.requiresSecureCoding = false
        defer { reader.finishDecoding() }
        return reader.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [VNFeaturePrintObservation]
    }

    /// Which step of reading the face fails, for the log.
    static func diagnose() -> String {
        guard let combined = try? Data(contentsOf: file) else { return "file unreadable" }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let keyData = item as? Data else { return "file \(combined.count)B, key status \(status)" }
        guard let box = try? AES.GCM.SealedBox(combined: combined) else { return "bad box" }
        let data: Data
        do { data = try AES.GCM.open(box, using: SymmetricKey(data: keyData)) } catch { return "decrypt: \(error)" }
        return unarchive(data).map { "ok \($0.count)" } ?? "unarchive failed"
    }

    /// Removes the face and its key.
    static func delete() {
        try? FileManager.default.removeItem(at: file)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }

    private static func key(create: Bool) throws -> SymmetricKey {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        guard create else { throw CocoaError(.fileReadNoPermission) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                    kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecValueData: data]
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return key
    }

    /// How far apart the enrolled samples are from each other: the yardstick for "this is the same face".
    /// A new face matches when it's about as close to the samples as they are to one another.
    static func threshold(for prints: [VNFeaturePrintObservation], strictness: Strictness) -> Float {
        var distances: [Float] = []
        for i in prints.indices {
            for j in prints.indices where j > i {
                var d: Float = 0
                if (try? prints[i].computeDistance(&d, to: prints[j])) != nil { distances.append(d) }
            }
        }
        guard !distances.isEmpty else { return 0.5 }
        distances.sort()
        let p = distances[min(distances.count - 1, Int(Double(distances.count - 1) * strictness.percentile))]
        return p * strictness.slack
    }

    enum Strictness: String, CaseIterable {
        case strict, normal, relaxed
        var title: String {
            switch self {
            case .strict: "Strict"
            case .normal: "Normal"
            case .relaxed: "Relaxed"
            }
        }
        fileprivate var percentile: Double {
            switch self {
            case .strict: 0.5
            case .normal: 0.8
            case .relaxed: 0.95
            }
        }
        fileprivate var slack: Float {
            switch self {
            case .strict: 1.0
            case .normal: 1.08
            case .relaxed: 1.2
            }
        }
    }
}
