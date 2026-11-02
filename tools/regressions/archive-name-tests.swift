import Foundation

extension ArchiveRegressionTests {
    static func nameTests(_ root: URL) throws {
        let fm = FileManager.default
        var options = CompressOptions()
        let reserved = try file(root, "CON.txt", "reserved")
        let ordinary = try file(root, "_CON.txt", "ordinary")
        func collision(_ items: [URL], _ label: String) throws {
            do {
                _ = try compress(items, options)
                fatalError("FAIL \(label) must fail explicitly")
            } catch ArchiveError.failed(let message) {
                check(message == String(localized: "File names collide after normalization. Rename the conflicting files and try again."), label)
            }
        }
        try collision([reserved, ordinary], "#15 converted collision rejected")
        let conDir = root.appendingPathComponent("CON")
        let safeDir = root.appendingPathComponent("_CON")
        try fm.createDirectory(at: conDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: safeDir, withIntermediateDirectories: true)
        _ = try file(conDir, "one.txt", "one")
        _ = try file(safeDir, "two.txt", "two")
        try collision([conDir, safeDir], "#15 directory collision rejected")
        let colon = try file(root, "a:b.txt", "colon")
        let slash = try file(root, "a／b.txt", "full-width slash")
        try collision([colon, slash], "#15 punctuation collision rejected")
        // Different parents also work on case-insensitive volumes.
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        let upper = try file(left, "Case.txt", "upper"), lower = try file(right, "case.txt", "lower")
        try collision([upper, lower], "#15 case collision rejected")
        let composed = try file(left, "é.txt", "composed"), decomposed = try file(right, "e\u{301}.txt", "decomposed")
        options.windowsCompatible = false
        try collision([composed, decomposed], "#15 NFC collision rejected without Windows conversion")
        let zip = try compress([reserved, ordinary], options)
        let extracted = try extract(zip)
        check(try String(contentsOf: extracted.appendingPathComponent("CON.txt")) == "reserved", "#15 opt-out keeps CON")
        check(try String(contentsOf: extracted.appendingPathComponent("_CON.txt")) == "ordinary", "#15 opt-out keeps _CON")
        options.windowsCompatible = true
        let notes = try file(root, "__MACOSX_notes.txt", "ordinary user content")
        check(try String(contentsOf: extract(compress([notes], options))) == "ordinary user content", "#17 prefix-only file extracted")
        let clutter = root.appendingPathComponent("__MACOSX")
        try fm.createDirectory(at: clutter, withIntermediateDirectories: true)
        _ = try file(clutter, "._notes", "metadata")
        options.skipMacFiles = false
        let mixed = try extract(compress([notes, clutter], options))
        check(try String(contentsOf: mixed) == "ordinary user content", "#17 metadata directory excluded")
        let ordinaryDir = root.appendingPathComponent("ordinary-macosx")
        try fm.createDirectory(at: ordinaryDir, withIntermediateDirectories: true)
        let exact = try file(ordinaryDir, "__MACOSX", "ordinary exact-name file")
        options.skipMacFiles = true
        check(try String(contentsOf: extract(compress([exact], options))) == "ordinary exact-name file", "#17 exact metadata name preserved when a file")
        let first = try file(root, "readable.txt", "first source")
        let missing = try file(root, "vanishing.txt", "second source")
        let before = Set(try fm.contentsOfDirectory(atPath: root.path))
        do {
            _ = try ArchiveEngine.compress([first, missing], options: options, cancel: ArchiveCancel()) { _ in
                try? fm.removeItem(at: missing)
            }
            fatalError("FAIL unreadable source must not publish an incomplete archive")
        } catch {
            check(!fm.fileExists(atPath: missing.path), "unreadable source fixture reached read boundary")
            let after = Set(try fm.contentsOfDirectory(atPath: root.path))
            check(after.subtracting(before).isEmpty, "unreadable source publishes no archive")
        }
    }
}
