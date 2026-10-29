import Foundation

/// Lets a running job be stopped from another thread.
final class ArchiveCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var process: Process?
    var isCancelled: Bool { lock.withLock { flag } }
    func cancel() {
        lock.withLock {
            flag = true
            process?.terminate()
        }
    }
    func attach(_ p: Process?) { lock.withLock { process = p } }
}

enum ArchiveFormat: String, CaseIterable, Codable, Sendable {
    case zip, sevenZip = "7z", tarGz = "tar.gz", tarXz = "tar.xz", tarBz2 = "tar.bz2", dmg

    var fileExtension: String { rawValue }
    var title: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7Z"
        case .tarGz: "TAR.GZ"
        case .tarXz: "TAR.XZ"
        case .tarBz2: "TAR.BZ2"
        case .dmg: "DMG"
        }
    }
    /// libarchive can't encrypt 7z or tar; ZIP uses AES-256, DMG the disk image's own AES-256.
    var supportsPassword: Bool { self == .zip || self == .dmg }
}

enum ArchiveLevel: String, CaseIterable, Codable, Sendable {
    case fast, normal, best
    var number: Int { switch self { case .fast: 1; case .normal: 6; case .best: 9 } }
}

enum ZipEncryption: String, CaseIterable, Codable, Sendable {
    /// Strong; Windows needs 7-Zip (or similar) to open it.
    case aes256
    /// Weak, but Windows' own File Explorer opens it.
    case zipCrypto
}

struct CompressOptions: Sendable {
    var format: ArchiveFormat = .zip
    var level: ArchiveLevel = .normal
    var password: String?
    /// Bytes per part; nil keeps one file.
    var splitSize: Int64?
    /// Leaves out .DS_Store, ._ files, __MACOSX, Thumbs.db — system clutter nobody else wants.
    var skipMacFiles = true
    /// Names any Windows PC can make: no \ : * ? " < > |, no trailing dots or spaces, no CON/NUL….
    var windowsCompatible = true
    var zipEncryption: ZipEncryption = .aes256
}

struct CompressResult: Sendable {
    let url: URL
    /// Paths longer than Windows' classic 260-character limit.
    let longPaths: Int
    /// Names changed so Windows can make them.
    let renamed: Int
}

/// Compresses and extracts. Pure Foundation + libarchive (+ hdiutil for disk images), off the main thread.
enum ArchiveEngine {
    private static let la = LibArchive.shared
    private static let fm = FileManager.default

    // MARK: Extract

    /// Unpacks `archive` next to itself. One top-level item comes out as itself; several land in a
    /// folder named after the archive. Returns what was made.
    static func extract(_ archive: URL, password: String?, encoding: NameEncoding = .auto, into parent: URL? = nil, cancel: ArchiveCancel,
                        progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        try LibArchive.inUTF8 {
            try extractInLocale(archive, password: password, encoding: encoding, into: parent, cancel: cancel, progress: progress)
        }
    }

    private static func extractInLocale(_ archive: URL, password: String?, encoding: NameEncoding, into parent: URL?, cancel: ArchiveCancel,
                                        progress: @escaping @Sendable (Double) -> Void) throws -> URL {
        let parent = parent ?? archive.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".orbit-extract-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let ext = archive.pathExtension.lowercased()
        if ext == "dmg" || ext == "sparseimage" || ext == "sparsebundle" {
            try extractDiskImage(archive, password: password, into: staging, cancel: cancel, progress: progress)
        } else {
            try extractWithLibArchive(archive, password: password, encoding: encoding, into: staging, cancel: cancel, progress: progress)
        }
        if cancel.isCancelled { throw ArchiveError.cancelled }

        let items = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !items.isEmpty else { throw ArchiveError.failed("The archive is empty.") }
        let result: URL
        if items.count == 1 {
            result = unique(parent.appendingPathComponent(items[0].lastPathComponent))
            try fm.moveItem(at: items[0], to: result)
        } else {
            result = unique(parent.appendingPathComponent(LibArchive.baseName(of: archive), isDirectory: true))
            try fm.moveItem(at: staging, to: result)
        }
        progress(1)
        return result
    }

    private static func extractWithLibArchive(_ archive: URL, password: String?, encoding: NameEncoding, into dest: URL, cancel: ArchiveCancel,
                                              progress: @escaping @Sendable (Double) -> Void) throws {
        guard la.available else { throw ArchiveError.unavailable }
        let volumes = LibArchive.volumes(for: archive)
        // ZIPs keep a directory of names at the end, so reading them all first is cheap; other
        // formats are guessed name by name.
        var zipEncoding: NameEncoding?
        if encoding != .auto {
            zipEncoding = encoding
        } else if ["zip", "jar", "apk"].contains(archive.pathExtension.lowercased()) || archive.lastPathComponent.lowercased().contains(".zip.") {
            zipEncoding = NameEncoding.detect(rawNames(volumes, password: password))
        }
        let total = volumes.reduce(Int64(0)) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0) }

        for raw in [false, true] {
            let (a, r) = la.openReader(volumes, password: password, raw: raw)
            defer { _ = la.readFree(a) }
            guard r == LibArchive.ok else {
                let e = ArchiveError.from(la.error(a), hadPassword: password != nil)
                if e == .notAnArchive, !raw { continue } // maybe a lone compressed file
                throw e
            }
            let disk = la.writeDiskNew()
            defer { _ = la.writeFree(disk) }
            _ = la.writeDiskSetOptions(disk, LibArchive.extractTime | LibArchive.extractPerm | LibArchive.extractACL
                                       | LibArchive.extractFFlags | LibArchive.extractXattr | LibArchive.extractMacMetadata
                                       | LibArchive.secureSymlinks | LibArchive.secureNoDotDot)
            _ = la.writeDiskSetStandardLookup(disk)

            var entry: LibArchive.E?
            var count = 0
            var lastReport = Date.distantPast
            while true {
                if cancel.isCancelled { throw ArchiveError.cancelled }
                let h = la.readNextHeader(a, &entry)
                if h == LibArchive.eof { break }
                if h < LibArchive.warn {
                    let e = ArchiveError.from(la.error(a), hadPassword: password != nil)
                    if e == .notAnArchive, !raw, count == 0 { break } // try again as a lone compressed file
                    throw e
                }
                count += 1
                var path: String
                if raw {
                    guard la.filterCount(a) > 1 else { throw ArchiveError.notAnArchive }
                    path = LibArchive.baseName(of: archive)
                } else {
                    let rawPath = la.rawName(entry)
                    path = NameEncoding.decode(rawPath, zipEncoding ?? NameEncoding.detect([rawPath]))
                }
                guard let safe = sanitize(path) else { _ = la.readDataSkip(a); continue }
                if safe.hasPrefix("__MACOSX") { _ = la.readDataSkip(a); continue }
                if password == nil, la.entryIsEncrypted(entry) != 0 { throw ArchiveError.needsPassword }
                dest.appendingPathComponent(safe).path.withCString { la.entryCopyPathname(entry, $0) }
                if let link = la.entryHardlink(entry).map({ p in
                    NameEncoding.decode(Data(bytes: p, count: strlen(p)), zipEncoding ?? .auto)
                }), let safeLink = sanitize(link) {
                    dest.appendingPathComponent(safeLink).path.withCString { la.entryCopyHardlink(entry, $0) }
                }
                if la.writeHeader(disk, entry) < LibArchive.warn { throw ArchiveError.failed(la.error(disk)) }
                var buffer: UnsafeRawPointer?
                var size = 0
                var offset: Int64 = 0
                while true {
                    if cancel.isCancelled { throw ArchiveError.cancelled }
                    let d = la.readDataBlock(a, &buffer, &size, &offset)
                    if d == LibArchive.eof { break }
                    if d < LibArchive.warn { throw ArchiveError.from(la.error(a), hadPassword: password != nil) }
                    if la.writeDataBlock(disk, buffer, size, offset) < 0 { throw ArchiveError.failed(la.error(disk)) }
                    if total > 0, Date().timeIntervalSince(lastReport) > 0.05 {
                        lastReport = Date()
                        progress(min(0.99, Double(la.filterBytes(a, -1)) / Double(total)))
                    }
                }
                _ = la.writeFinishEntry(disk)
            }
            if count > 0 { return }
            if raw { throw ArchiveError.notAnArchive }
        }
    }

    private static func rawNames(_ volumes: [URL], password: String?) -> [Data] {
        let (a, r) = la.openReader(volumes, password: password, raw: false)
        defer { _ = la.readFree(a) }
        guard r == LibArchive.ok else { return [] }
        var names: [Data] = []
        var entry: LibArchive.E?
        while names.count < 50_000, la.readNextHeader(a, &entry) >= LibArchive.warn {
            names.append(la.rawName(entry))
            _ = la.readDataSkip(a)
        }
        return names
    }

    /// Mounts the image privately, copies everything out, and ejects it.
    private static func extractDiskImage(_ image: URL, password: String?, into dest: URL, cancel: ArchiveCancel,
                                         progress: @escaping @Sendable (Double) -> Void) throws {
        let encrypted = (try? run("/usr/bin/hdiutil", ["isencrypted", image.path]).output.contains("encrypted: YES")) ?? false
        if encrypted, password == nil { throw ArchiveError.needsPassword }
        let mountRoot = fm.temporaryDirectory.appendingPathComponent("orbit-mount-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mountRoot) }
        var args = ["attach", image.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-mountrandom", mountRoot.path, "-plist"]
        if encrypted { args.append("-stdinpass") }
        let attach = try run("/usr/bin/hdiutil", args, stdin: encrypted ? password : nil, cancel: cancel)
        guard attach.status == 0, let data = attach.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            if cancel.isCancelled { throw ArchiveError.cancelled }
            throw encrypted ? ArchiveError.wrongPassword : ArchiveError.failed("Couldn’t open the disk image.")
        }
        let mounts = entities.compactMap { $0["mount-point"] as? String }
        defer { for m in mounts { _ = try? run("/usr/bin/hdiutil", ["detach", m, "-force", "-quiet"]) } }
        progress(0.1)
        for (i, m) in mounts.enumerated() {
            let root = URL(fileURLWithPath: m)
            let skip: Set<String> = [".Trashes", ".fseventsd", ".Spotlight-V100", ".DS_Store", ".TemporaryItems", ".DocumentRevisions-V100"]
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            let target = mounts.count == 1 ? dest : dest.appendingPathComponent(root.lastPathComponent)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for item in items where !skip.contains(item.lastPathComponent) {
                if cancel.isCancelled { throw ArchiveError.cancelled }
                let r = try run("/usr/bin/ditto", [item.path, target.appendingPathComponent(item.lastPathComponent).path], cancel: cancel)
                if r.status != 0 { throw ArchiveError.failed("Couldn’t copy \(item.lastPathComponent) out of the disk image.") }
            }
            progress(0.1 + 0.9 * Double(i + 1) / Double(mounts.count))
        }
    }

    /// Keeps entries inside the destination: no absolute paths, no "..".
    private static func sanitize(_ path: String) -> String? {
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }

    // MARK: Compress

    /// Packs `items` into one archive next to the first of them. Returns the archive (or its first part).
    static func compress(_ items: [URL], options: CompressOptions, cancel: ArchiveCancel,
                         progress: @escaping @Sendable (Double) -> Void) throws -> CompressResult {
        try LibArchive.inUTF8 { try compressInLocale(items, options: options, cancel: cancel, progress: progress) }
    }

    private static func compressInLocale(_ items: [URL], options: CompressOptions, cancel: ArchiveCancel,
                                         progress: @escaping @Sendable (Double) -> Void) throws -> CompressResult {
        guard let first = items.first else { throw ArchiveError.failed("Nothing to compress.") }
        let parent = first.deletingLastPathComponent()
        let base = items.count == 1 ? (isDirectory(first) ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent)
                                    : String(localized: "Archive")
        let output = unique(parent.appendingPathComponent("\(base).\(options.format.fileExtension)"))
        var stats = (long: 0, renamed: 0)
        let partial = parent.appendingPathComponent(".\(output.lastPathComponent).orbit-partial")
        try? fm.removeItem(at: partial)
        do {
            if options.format == .dmg {
                try makeDiskImage(items, name: base, at: partial, options: options, cancel: cancel, progress: progress)
            } else {
                stats = try writeArchive(items, to: partial, options: options, cancel: cancel, progress: progress)
            }
            if cancel.isCancelled { throw ArchiveError.cancelled }
            try fm.moveItem(at: partial, to: output)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        var url = output
        if let size = options.splitSize, size > 0 { url = try split(output, every: size) }
        progress(1)
        return CompressResult(url: url, longPaths: stats.long, renamed: stats.renamed)
    }

    private struct Source { let url: URL; let name: String }

    private static func walk(_ items: [URL], skipMac: Bool) -> [Source] {
        var out: [Source] = []
        let clutter: Set<String> = [".DS_Store", "__MACOSX", ".localized", "Thumbs.db", "desktop.ini", "Icon\r",
                                    ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100"]
        func skipped(_ name: String) -> Bool {
            skipMac && (clutter.contains(name) || name.hasPrefix("._"))
        }
        for item in items {
            let rootName = item.lastPathComponent
            if skipped(rootName) { continue }
            out.append(Source(url: item, name: rootName))
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue,
                  (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let e = fm.enumerator(at: item, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: { _, _ in true })
            else { continue }
            for case let u as URL in e {
                if skipped(u.lastPathComponent) {
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }
                    continue
                }
                let rel = u.path.dropFirst(item.path.count).drop { $0 == "/" }
                out.append(Source(url: u, name: rootName + "/" + rel))
            }
        }
        return out
    }

    @discardableResult
    private static func writeArchive(_ items: [URL], to output: URL, options: CompressOptions, cancel: ArchiveCancel,
                                     progress: @escaping @Sendable (Double) -> Void) throws -> (long: Int, renamed: Int) {
        guard la.available else { throw ArchiveError.unavailable }
        let sources = walk(items, skipMac: options.skipMacFiles)
        let total = sources.reduce(Int64(0)) { sum, s in
            let v = try? s.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return sum + (v?.isRegularFile == true ? Int64(v?.fileSize ?? 0) : 0)
        }
        let a = la.writeNew()
        defer { _ = la.writeFree(a) }
        let level = options.level.number
        switch options.format {
        case .zip:
            _ = la.writeSetFormatZip(a)
            // Names as UTF-8 with the "language encoding" flag (bit 11) set, so Windows reads Korean right.
            guard la.writeSetOptions(a, "zip:hdrcharset=UTF-8") == LibArchive.ok else { throw ArchiveError.failed(la.error(a)) }
            _ = la.writeSetOptions(a, "zip:compression-level=\(level)")
            if let p = options.password, !p.isEmpty {
                let method = options.zipEncryption == .aes256 ? "aes256" : "zipcrypt"
                guard la.writeSetOptions(a, "zip:encryption=\(method)") == LibArchive.ok else { throw ArchiveError.failed(la.error(a)) }
                _ = p.withCString { la.writeSetPassphrase(a, $0) }
            }
        case .sevenZip:
            _ = la.writeSetFormat7zip(a)
            _ = la.writeSetOptions(a, "7zip:compression=lzma2,7zip:compression-level=\(level)")
        case .tarGz:
            _ = la.writeSetFormatPaxRestricted(a); _ = la.writeAddFilterGzip(a)
            _ = la.writeSetOptions(a, "gzip:compression-level=\(level)")
        case .tarXz:
            _ = la.writeSetFormatPaxRestricted(a); _ = la.writeAddFilterXz(a)
            _ = la.writeSetOptions(a, "xz:compression-level=\(level)")
        case .tarBz2:
            _ = la.writeSetFormatPaxRestricted(a); _ = la.writeAddFilterBzip2(a)
            _ = la.writeSetOptions(a, "bzip2:compression-level=\(level)")
        case .dmg: break
        }
        guard output.path.withCString({ la.writeOpenFilename(a, $0) }) == LibArchive.ok else { throw ArchiveError.failed(la.error(a)) }

        let disk = la.readDiskNew()
        defer { _ = la.writeFree(disk) } // archive_read_disk is freed like any archive; free() dispatches on its vtable
        _ = la.readDiskSetStandardLookup(disk)
        // No xattrs (quarantine, Finder tags), ACLs or BSD flags; AppleDouble is never asked for.
        _ = la.readDiskSetBehavior(disk, LibArchive.diskNoXattr | LibArchive.diskNoACL | LibArchive.diskNoFFlags)
        let forWindows = options.windowsCompatible && options.format == .zip
        var long = 0, renamed = 0
        var done: Int64 = 0
        var lastReport = Date.distantPast
        let chunk = 1 << 20
        for s in sources {
            if cancel.isCancelled { throw ArchiveError.cancelled }
            guard let entry = la.entryNew() else { continue }
            defer { la.entryFree(entry) }
            s.url.path.withCString { la.entryCopySourcepath(entry, $0) }
            guard la.readDiskEntryFromFile(disk, entry, -1, nil) >= LibArchive.warn else { continue }
            // macOS spells names decomposed (NFD: ㅎ+ㅏ+ㄴ); everyone else expects composed (NFC: 한).
            var name = s.name.precomposedStringWithCanonicalMapping
            if forWindows {
                let safe = windowsSafe(name)
                if safe != name { renamed += 1 }
                name = safe
            }
            if name.utf16.count > 260 { long += 1 }
            name.withCString { la.entryCopyPathname(entry, $0) }
            if options.format == .zip {
                // Plain permissions and no owner: nothing Windows (or another Mac) trips over.
                let type = UInt32(la.entryFiletype(entry))
                let exec = (try? s.url.resourceValues(forKeys: [.isExecutableKey]).isExecutable) == true
                la.entrySetPerm(entry, type == LibArchive.ifDir || (type == LibArchive.ifReg && exec) ? 0o755 : 0o644)
                la.entrySetUid(entry, 0)
                la.entrySetGid(entry, 0)
                la.entryCopyUname(entry, nil)
                la.entryCopyGname(entry, nil)
            }
            if la.writeHeader(a, entry) < LibArchive.warn { throw ArchiveError.failed(la.error(a)) }
            if UInt32(la.entryFiletype(entry)) == LibArchive.ifReg, let h = try? FileHandle(forReadingFrom: s.url) {
                defer { try? h.close() }
                while let data = try? h.read(upToCount: chunk), !data.isEmpty {
                    if cancel.isCancelled { throw ArchiveError.cancelled }
                    let w = data.withUnsafeBytes { la.writeData(a, $0.baseAddress, data.count) }
                    if w < 0 { throw ArchiveError.failed(la.error(a)) }
                    done += Int64(data.count)
                    if total > 0, Date().timeIntervalSince(lastReport) > 0.05 {
                        lastReport = Date()
                        progress(min(0.99, Double(done) / Double(total)))
                    }
                }
            }
            _ = la.writeFinishEntry(a)
        }
        if la.writeClose(a) != LibArchive.ok { throw ArchiveError.failed(la.error(a)) }
        return (long, renamed)
    }

    /// Each part of a path made legal on Windows. macOS stores a "/" typed in Finder as ":".
    static func windowsSafe(_ path: String) -> String {
        let map: [Character: Character] = ["\\": "＼", ":": "／", "*": "＊", "?": "？", "\"": "＂", "<": "＜", ">": "＞", "|": "｜"]
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        return path.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            var p = String(part.map { map[$0] ?? $0 }).filter { ($0.unicodeScalars.first?.value ?? 32) >= 32 }
            while let last = p.last, last == "." || last == " " { p.removeLast() }
            if p.isEmpty, !part.isEmpty { p = "_" }
            let stem = p.split(separator: ".", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
            if reserved.contains(stem) { p = "_" + p }
            return p
        }.joined(separator: "/")
    }

    private static func makeDiskImage(_ items: [URL], name: String, at output: URL, options: CompressOptions, cancel: ArchiveCancel,
                                      progress: @escaping @Sendable (Double) -> Void) throws {
        var source = items[0]
        var staging: URL?
        if items.count > 1 || !isDirectory(items[0]) {
            // hdiutil wants one folder; clones are instant and take no space on APFS.
            let s = fm.temporaryDirectory.appendingPathComponent("orbit-dmg-\(UUID().uuidString.prefix(8))").appendingPathComponent(name)
            try fm.createDirectory(at: s, withIntermediateDirectories: true)
            for item in items { try fm.copyItem(at: item, to: s.appendingPathComponent(item.lastPathComponent)) }
            source = s
            staging = s.deletingLastPathComponent()
        }
        defer { if let staging { try? fm.removeItem(at: staging) } }
        var args = ["create", "-volname", name, "-srcfolder", source.path, "-ov", "-puppetstrings"]
        switch options.level {
        case .fast: args += ["-format", "UDZO", "-imagekey", "zlib-level=1"]
        case .normal: args += ["-format", "UDZO"]
        case .best: args += ["-format", "ULMO"]
        }
        let password = options.password.flatMap { $0.isEmpty ? nil : $0 }
        if password != nil { args += ["-encryption", "AES-256", "-stdinpass"] }
        // hdiutil adds .dmg to names without it.
        let target = output.appendingPathExtension("dmg")
        args.append(target.path)
        let r = try run("/usr/bin/hdiutil", args, stdin: password, cancel: cancel) { line in
            if line.hasPrefix("PERCENT:"), let p = Double(line.dropFirst(8).trimmingCharacters(in: .whitespaces)), p >= 0 {
                progress(min(0.99, p / 100))
            }
        }
        if cancel.isCancelled { try? fm.removeItem(at: target); throw ArchiveError.cancelled }
        guard r.status == 0 else { try? fm.removeItem(at: target); throw ArchiveError.failed("hdiutil: \(r.output.suffix(200))") }
        try fm.moveItem(at: target, to: output)
    }

    /// name.zip → name.zip.001, .002 … (the 7-Zip/Keka convention; Orbit and Keka join them back).
    private static func split(_ file: URL, every size: Int64) throws -> URL {
        let total = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard total > size else { return file }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var index = 1
        var first: URL?
        while true {
            let part = file.deletingLastPathComponent().appendingPathComponent(String(format: "%@.%03d", file.lastPathComponent, index))
            fm.createFile(atPath: part.path, contents: nil)
            let out = try FileHandle(forWritingTo: part)
            var written: Int64 = 0
            while written < size, let data = try h.read(upToCount: Int(min(Int64(1 << 22), size - written))), !data.isEmpty {
                try out.write(contentsOf: data)
                written += Int64(data.count)
            }
            try out.close()
            if written == 0 { try? fm.removeItem(at: part); break }
            if first == nil { first = part }
            index += 1
        }
        try fm.removeItem(at: file)
        return first ?? file
    }

    // MARK: Helpers

    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
            && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    static func unique(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for i in 2...9999 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], stdin: String? = nil, cancel: ArchiveCancel? = nil,
                    line: ((String) -> Void)? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = input
        cancel?.attach(p)
        defer { cancel?.attach(nil) }
        try p.run()
        if var bytes = stdin.map({ Array($0.utf8) }) {
            input.fileHandleForWriting.write(Data(bytes))
            for i in bytes.indices { bytes[i] = 0 }
        }
        try? input.fileHandleForWriting.close()
        var collected = Data()
        var pending = ""
        while true {
            let d = out.fileHandleForReading.availableData
            if d.isEmpty { break }
            collected.append(d)
            if let line {
                pending += String(decoding: d, as: UTF8.self)
                while let r = pending.firstIndex(of: "\n") {
                    line(String(pending[..<r]))
                    pending.removeSubrange(...r)
                }
            }
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: collected, as: UTF8.self))
    }
}
