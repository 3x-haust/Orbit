import Foundation

@main
struct ArchiveRegressionTests {
    static func check(_ ok: Bool, _ label: String) {
        guard ok else { fatalError("FAIL \(label)") }
        print("PASS \(label)")
    }

    static func compress(_ items: [URL], _ options: CompressOptions = CompressOptions()) throws -> URL {
        try ArchiveEngine.compress(items, options: options, cancel: ArchiveCancel()) { _ in }.url
    }

    static func extract(_ url: URL) throws -> URL {
        try ArchiveEngine.extract(url, password: nil, cancel: ArchiveCancel()) { _ in }
    }

    static func file(_ root: URL, _ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    static func snapshot(_ first: URL) throws -> [URL: Data] {
        try Dictionary(uniqueKeysWithValues: LibArchive.volumes(for: first).map { ($0, try Data(contentsOf: $0)) })
    }

    static func noise(_ count: Int) -> Data {
        var seed: UInt64 = 0x123456789abcdef
        return Data((0..<count).map { _ -> UInt8 in
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return UInt8(truncatingIfNeeded: seed)
        })
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orbit-regressions-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try splitTests(root)
        try nameTests(root)
        if CommandLine.arguments.contains("--large") { try largeSplitTest(root) }
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".orbit-") }
        check(leftovers.isEmpty, "temporary files cleaned up")
    }
}
