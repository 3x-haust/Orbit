import Foundation

extension ArchiveRegressionTests {
    static func splitTests(_ root: URL) throws {
        let fm = FileManager.default
        var options = CompressOptions()
        options.splitSize = 96
        let source = try file(root, "backup.txt", "first backup")
        let first = try compress([source], options)
        let original = try snapshot(first)
        check(original.count > 1, "#14 fixture creates multiple volumes")
        try Data("second backup".utf8).write(to: source)
        let second = try compress([source], options)
        check(try first != second && snapshot(first) == original, "#14 repeat split preserves old volumes")
        check(try String(contentsOf: extract(first)) == "first backup", "#14 old backup round-trips")
        check(try String(contentsOf: extract(second)) == "second backup", "#14 new backup round-trips")
        let orphan = try file(root, "orphan.zip.002", "orphan")
        check(ArchiveEngine.unique(root.appendingPathComponent("orphan.zip"), includingSplitParts: true).lastPathComponent == "orphan 2.zip", "#14 orphan reserves base")
        check(try String(contentsOf: orphan) == "orphan", "#14 orphan unchanged")
        _ = try file(root, "CASE.ZIP.1000", "orphan")
        check(ArchiveEngine.unique(root.appendingPathComponent("case.zip"), includingSplitParts: true).lastPathComponent == "case 2.zip", "#14 case-equivalent orphan reserves base")
        let volume = try file(root, "volumes.zip.001", "part")
        check(LibArchive.volumes(for: root.appendingPathComponent("volumes.zip.1000")) == [volume], "#14 four-digit selected volume")
        check(LibArchive.baseName(of: root.appendingPathComponent("volumes.zip.1000")) == "volumes", "#14 four-digit base name")
        // Force late collisions at the progress boundary, without sleeps or another thread.
        let race = try file(root, "race.txt", "complete archive must survive a split failure")
        let blocker = root.appendingPathComponent("race.zip.002")
        do {
            _ = try ArchiveEngine.compress([race], options: options, cancel: ArchiveCancel()) { _ in
                try? Data("existing part".utf8).write(to: blocker, options: .withoutOverwriting)
            }
            fatalError("FAIL #14 late collision must fail")
        } catch {
            check(try String(contentsOf: blocker) == "existing part", "#14 raced part preserved")
            check(!fm.fileExists(atPath: root.appendingPathComponent("race.zip.001").path), "#14 own parts rolled back")
            check(fm.fileExists(atPath: root.appendingPathComponent("race.zip").path), "#14 complete archive retained")
        }
        let single = try file(root, "single-race.txt", "source")
        let existing = root.appendingPathComponent("single-race.zip")
        do {
            _ = try ArchiveEngine.compress([single], options: CompressOptions(), cancel: ArchiveCancel()) { _ in
                try? Data("existing archive".utf8).write(to: existing, options: .withoutOverwriting)
            }
            fatalError("FAIL #14 late whole-archive collision must fail")
        } catch {
            check(try String(contentsOf: existing) == "existing archive", "#14 raced whole archive preserved")
        }
        let tooMany = root.appendingPathComponent("limit.txt")
        try noise(12_000).write(to: tooMany)
        options.splitSize = 1
        do {
            _ = try compress([tooMany], options)
            fatalError("FAIL #14 unsupported volume count must fail")
        } catch ArchiveError.failed {
            check(fm.fileExists(atPath: root.appendingPathComponent("limit.zip").path), "#14 limit retains complete archive")
            check(!fm.fileExists(atPath: root.appendingPathComponent("limit.zip.001").path), "#14 limit publishes no parts")
        }
        let cancelled = ArchiveCancel()
        cancelled.cancel()
        do {
            _ = try ArchiveEngine.compress([source], options: options, cancel: cancelled) { _ in }
            fatalError("FAIL cancelled compression must fail")
        } catch ArchiveError.cancelled { print("PASS cancelled compression fails") }
    }

    static func largeSplitTest(_ root: URL) throws {
        var options = CompressOptions()
        options.splitSize = 25_000_000
        let bytes = noise(27_000_000)
        let source = root.appendingPathComponent("large.bin")
        try bytes.write(to: source)
        let first = try compress([source], options)
        let saved = try snapshot(first)
        var changed = bytes
        changed[0] ^= 0xff
        try changed.write(to: source)
        let second = try compress([source], options)
        check(try first != second && saved[first]?.count == 25_000_000 && saved.count > 1 && saved == snapshot(first), "#14 UI-sized split preserves old volumes")
        check(try Data(contentsOf: extract(first)) == bytes, "#14 UI-sized old backup round-trips")
        check(try Data(contentsOf: extract(second)) == changed, "#14 UI-sized new backup round-trips")
    }
}
