import Foundation

/// The system's libarchive (the engine behind `bsdtar` and Archive Utility), used in-process so
/// Orbit gets real progress, cancelling and passwords that never appear on a command line.
/// The SDK ships the library but not its headers, so the few functions used are looked up by name.
/// Shared with the Quick Look extension.
final class LibArchive: @unchecked Sendable {
    static let shared = LibArchive()

    typealias A = OpaquePointer // struct archive *
    typealias E = OpaquePointer // struct archive_entry *

    static let ok: Int32 = 0, eof: Int32 = 1, retry: Int32 = -10, warn: Int32 = -20, failed: Int32 = -25, fatal: Int32 = -30
    static let ifDir: UInt32 = 0o040000, ifReg: UInt32 = 0o100000, ifLnk: UInt32 = 0o120000

    // archive_write_disk flags
    static let extractTime: Int32 = 0x0004, extractPerm: Int32 = 0x0002, extractACL: Int32 = 0x0020,
               extractFFlags: Int32 = 0x0040, extractXattr: Int32 = 0x0080, secureSymlinks: Int32 = 0x0100,
               secureNoDotDot: Int32 = 0x0200, extractMacMetadata: Int32 = 0x2000

    private let handle: UnsafeMutableRawPointer?

    private init() {
        handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW)
    }

    var available: Bool { handle != nil }

    private func sym<T>(_ name: String, _: T.Type = T.self) -> T {
        guard let handle, let p = dlsym(handle, name) else { fatalError("libarchive: missing \(name)") }
        return unsafeBitCast(p, to: T.self)
    }

    // MARK: Reading

    lazy var readNew: @convention(c) () -> A? = sym("archive_read_new")
    lazy var readSupportFilterAll: @convention(c) (A?) -> Int32 = sym("archive_read_support_filter_all")
    lazy var readSupportFormatAll: @convention(c) (A?) -> Int32 = sym("archive_read_support_format_all")
    lazy var readSupportFormatRaw: @convention(c) (A?) -> Int32 = sym("archive_read_support_format_raw")
    lazy var readSupportFormatEmpty: @convention(c) (A?) -> Int32 = sym("archive_read_support_format_empty")
    lazy var readAddPassphrase: @convention(c) (A?, UnsafePointer<CChar>?) -> Int32 = sym("archive_read_add_passphrase")
    lazy var readOpenFilename: @convention(c) (A?, UnsafePointer<CChar>?, Int) -> Int32 = sym("archive_read_open_filename")
    lazy var readOpenFilenames: @convention(c) (A?, UnsafeMutablePointer<UnsafePointer<CChar>?>?, Int) -> Int32 = sym("archive_read_open_filenames")
    lazy var readNextHeader: @convention(c) (A?, UnsafeMutablePointer<E?>?) -> Int32 = sym("archive_read_next_header")
    lazy var readDataSkip: @convention(c) (A?) -> Int32 = sym("archive_read_data_skip")
    lazy var readDataBlock: @convention(c) (A?, UnsafeMutablePointer<UnsafeRawPointer?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int64>?) -> Int32 = sym("archive_read_data_block")
    lazy var readFree: @convention(c) (A?) -> Int32 = sym("archive_read_free")
    lazy var readHasEncryptedEntries: @convention(c) (A?) -> Int32 = sym("archive_read_has_encrypted_entries")
    lazy var filterBytes: @convention(c) (A?, Int32) -> Int64 = sym("archive_filter_bytes")
    lazy var filterCount: @convention(c) (A?) -> Int32 = sym("archive_filter_count")
    lazy var filterCode: @convention(c) (A?, Int32) -> Int32 = sym("archive_filter_code")
    lazy var formatName: @convention(c) (A?) -> UnsafePointer<CChar>? = sym("archive_format_name")
    lazy var errorString: @convention(c) (A?) -> UnsafePointer<CChar>? = sym("archive_error_string")

    // MARK: Entries

    lazy var entryNew: @convention(c) () -> E? = sym("archive_entry_new")
    lazy var entryFree: @convention(c) (E?) -> Void = sym("archive_entry_free")
    lazy var entryPathname: @convention(c) (E?) -> UnsafePointer<CChar>? = sym("archive_entry_pathname")
    lazy var entryPathnameUTF8: @convention(c) (E?) -> UnsafePointer<CChar>? = sym("archive_entry_pathname_utf8")
    lazy var entryCopyPathname: @convention(c) (E?, UnsafePointer<CChar>?) -> Void = sym("archive_entry_copy_pathname")
    lazy var entryHardlink: @convention(c) (E?) -> UnsafePointer<CChar>? = sym("archive_entry_hardlink")
    lazy var entryCopyHardlink: @convention(c) (E?, UnsafePointer<CChar>?) -> Void = sym("archive_entry_copy_hardlink")
    lazy var entryCopySourcepath: @convention(c) (E?, UnsafePointer<CChar>?) -> Void = sym("archive_entry_copy_sourcepath")
    lazy var entrySize: @convention(c) (E?) -> Int64 = sym("archive_entry_size")
    lazy var entrySizeIsSet: @convention(c) (E?) -> Int32 = sym("archive_entry_size_is_set")
    /// mode_t is 16 bits on Darwin.
    lazy var entryFiletype: @convention(c) (E?) -> UInt16 = sym("archive_entry_filetype")
    lazy var entryIsEncrypted: @convention(c) (E?) -> Int32 = sym("archive_entry_is_encrypted")
    lazy var entryMtime: @convention(c) (E?) -> Int = sym("archive_entry_mtime")

    // MARK: Writing

    lazy var writeNew: @convention(c) () -> A? = sym("archive_write_new")
    lazy var writeSetFormatZip: @convention(c) (A?) -> Int32 = sym("archive_write_set_format_zip")
    lazy var writeSetFormat7zip: @convention(c) (A?) -> Int32 = sym("archive_write_set_format_7zip")
    lazy var writeSetFormatPaxRestricted: @convention(c) (A?) -> Int32 = sym("archive_write_set_format_pax_restricted")
    lazy var writeAddFilterGzip: @convention(c) (A?) -> Int32 = sym("archive_write_add_filter_gzip")
    lazy var writeAddFilterBzip2: @convention(c) (A?) -> Int32 = sym("archive_write_add_filter_bzip2")
    lazy var writeAddFilterXz: @convention(c) (A?) -> Int32 = sym("archive_write_add_filter_xz")
    lazy var writeSetOptions: @convention(c) (A?, UnsafePointer<CChar>?) -> Int32 = sym("archive_write_set_options")
    lazy var writeSetPassphrase: @convention(c) (A?, UnsafePointer<CChar>?) -> Int32 = sym("archive_write_set_passphrase")
    lazy var writeOpenFilename: @convention(c) (A?, UnsafePointer<CChar>?) -> Int32 = sym("archive_write_open_filename")
    lazy var writeHeader: @convention(c) (A?, E?) -> Int32 = sym("archive_write_header")
    lazy var writeData: @convention(c) (A?, UnsafeRawPointer?, Int) -> Int = sym("archive_write_data")
    lazy var writeDataBlock: @convention(c) (A?, UnsafeRawPointer?, Int, Int64) -> Int = sym("archive_write_data_block")
    lazy var writeFinishEntry: @convention(c) (A?) -> Int32 = sym("archive_write_finish_entry")
    lazy var writeClose: @convention(c) (A?) -> Int32 = sym("archive_write_close")
    lazy var writeFree: @convention(c) (A?) -> Int32 = sym("archive_write_free")

    lazy var writeDiskNew: @convention(c) () -> A? = sym("archive_write_disk_new")
    lazy var writeDiskSetOptions: @convention(c) (A?, Int32) -> Int32 = sym("archive_write_disk_set_options")
    lazy var writeDiskSetStandardLookup: @convention(c) (A?) -> Int32 = sym("archive_write_disk_set_standard_lookup")

    lazy var readDiskNew: @convention(c) () -> A? = sym("archive_read_disk_new")
    lazy var readDiskSetStandardLookup: @convention(c) (A?) -> Int32 = sym("archive_read_disk_set_standard_lookup")
    lazy var readDiskSetBehavior: @convention(c) (A?, Int32) -> Int32 = sym("archive_read_disk_set_behavior")
    lazy var entrySetPerm: @convention(c) (E?, UInt16) -> Void = sym("archive_entry_set_perm")
    lazy var entrySetUid: @convention(c) (E?, Int64) -> Void = sym("archive_entry_set_uid")
    lazy var entrySetGid: @convention(c) (E?, Int64) -> Void = sym("archive_entry_set_gid")
    lazy var entryCopyUname: @convention(c) (E?, UnsafePointer<CChar>?) -> Void = sym("archive_entry_copy_uname")
    lazy var entryCopyGname: @convention(c) (E?, UnsafePointer<CChar>?) -> Void = sym("archive_entry_copy_gname")
    lazy var readDiskEntryFromFile: @convention(c) (A?, E?, Int32, UnsafeRawPointer?) -> Int32 = sym("archive_read_disk_entry_from_file")

    // archive_read_disk behaviours: keep xattrs (quarantine…), ACLs and BSD flags out of archives.
    static let diskNoXattr: Int32 = 0x0010, diskNoACL: Int32 = 0x0020, diskNoFFlags: Int32 = 0x0040

    /// libarchive converts names through the C locale, which is plain "C" (ASCII) in an app — Korean
    /// names would fail or come out mangled. Runs `body` with this thread in UTF-8; the jobs are
    /// synchronous, so they stay on the one thread for their whole run.
    static func inUTF8<T>(_ body: () throws -> T) rethrows -> T {
        guard let loc = newlocale(LC_CTYPE_MASK, "UTF-8", nil) ?? newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { return try body() }
        let old = uselocale(loc)
        defer { uselocale(old); freelocale(loc) }
        return try body()
    }

    /// The bytes of an entry's name as stored — unconverted for ZIPs without the UTF-8 flag.
    func rawName(_ e: E?) -> Data {
        guard let p = entryPathname(e) else { return Data() }
        return Data(bytes: p, count: strlen(p))
    }

    func error(_ a: A?) -> String {
        errorString(a).map { String(cString: $0) } ?? "Unknown error"
    }
}

/// One file or folder inside an archive, as listed without unpacking it.
struct ArchiveEntryInfo: Sendable {
    let path: String
    let size: Int64
    let isDirectory: Bool
    let isEncrypted: Bool
    let modified: Date?
}

enum ArchiveError: LocalizedError, Equatable {
    case unavailable
    case notAnArchive
    case needsPassword
    case wrongPassword
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The archive engine isn’t available on this Mac."
        case .notAnArchive: "This file isn’t an archive Orbit can open."
        case .needsPassword: "This archive needs a password."
        case .wrongPassword: "That password didn’t work."
        case .cancelled: "Cancelled"
        case .failed(let m): m
        }
    }

    /// libarchive reports password trouble only in its message text.
    static func from(_ message: String, hadPassword: Bool) -> ArchiveError {
        let m = message.lowercased()
        if m.contains("passphrase") || m.contains("password") || m.contains("encrypt") {
            return hadPassword ? .wrongPassword : .needsPassword
        }
        if m.contains("unrecognized archive format") { return .notAnArchive }
        return .failed(message)
    }
}

extension LibArchive {
    /// Every part of a split or multi-volume set, in order, starting from whichever part was opened.
    static func volumes(for url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let fm = FileManager.default
        // name.zip.001, name.7z.002 …
        if let r = name.range(of: #"\.\d{3}$"#, options: .regularExpression) {
            let stem = String(name[..<r.lowerBound])
            var parts: [URL] = []
            for i in 1...9999 {
                let u = dir.appendingPathComponent(String(format: "%@.%03d", stem, i))
                guard fm.fileExists(atPath: u.path) else { break }
                parts.append(u)
            }
            return parts.isEmpty ? [url] : parts
        }
        // name.part1.rar, name.part01.rar …
        if let r = name.range(of: #"\.part(\d+)\.rar$"#, options: [.regularExpression, .caseInsensitive]) {
            let stem = String(name[..<r.lowerBound])
            let digits = name[r].filter(\.isNumber).count
            var parts: [URL] = []
            for i in 1...9999 {
                let n = String(format: "%0\(digits)d", i)
                let u = dir.appendingPathComponent("\(stem).part\(n).rar")
                guard fm.fileExists(atPath: u.path) else { break }
                parts.append(u)
            }
            return parts.isEmpty ? [url] : parts
        }
        return [url]
    }

    /// Opens `urls` (one archive, or the parts of one) for reading. `raw` reads a lone compressed
    /// file (a .gz that isn't a tarball) as a single stream.
    func openReader(_ urls: [URL], password: String?, raw: Bool) -> (A?, Int32) {
        let a = readNew()
        _ = readSupportFilterAll(a)
        if raw { _ = readSupportFormatRaw(a) } else { _ = readSupportFormatAll(a); _ = readSupportFormatEmpty(a) }
        if let password { _ = password.withCString { readAddPassphrase(a, $0) } }
        let result: Int32
        if urls.count == 1 {
            result = urls[0].path.withCString { readOpenFilename(a, $0, 1 << 16) }
        } else {
            let cs = urls.map { strdup($0.path) }
            defer { cs.forEach { free($0) } }
            var arr: [UnsafePointer<CChar>?] = cs.map { UnsafePointer($0) } + [nil]
            result = arr.withUnsafeMutableBufferPointer { readOpenFilenames(a, $0.baseAddress, 1 << 16) }
        }
        return (a, result)
    }

    /// Lists what's inside without unpacking anything.
    func list(_ url: URL, password: String? = nil, encoding: NameEncoding = .auto, limit: Int = 50_000) throws -> [ArchiveEntryInfo] {
        try Self.inUTF8 { try listInLocale(url, password: password, encoding: encoding, limit: limit) }
    }

    private func listInLocale(_ url: URL, password: String?, encoding: NameEncoding, limit: Int) throws -> [ArchiveEntryInfo] {
        guard available else { throw ArchiveError.unavailable }
        let urls = Self.volumes(for: url)
        for raw in [false, true] {
            let (a, r) = openReader(urls, password: password, raw: raw)
            defer { _ = readFree(a) }
            guard r == Self.ok else {
                let e = ArchiveError.from(error(a), hadPassword: password != nil)
                if e == .notAnArchive, !raw { continue }
                throw e
            }
            var entries: [ArchiveEntryInfo] = []
            var entry: E?
            var failure: String?
            var raws: [Data] = []
            while entries.count < limit {
                let h = readNextHeader(a, &entry)
                if h == Self.eof { break }
                if h < Self.warn { failure = error(a); break }
                let rawPath = rawName(entry)
                raws.append(rawPath)
                let path = String(decoding: rawPath, as: UTF8.self)
                if raw {
                    // A lone stream has no name of its own.
                    let name = Self.baseName(of: url)
                    entries.append(ArchiveEntryInfo(path: name, size: entrySizeIsSet(entry) != 0 ? entrySize(entry) : -1, isDirectory: false, isEncrypted: false, modified: nil))
                    break
                }
                let type = UInt32(entryFiletype(entry))
                let mtime = entryMtime(entry)
                entries.append(ArchiveEntryInfo(
                    path: path, size: entrySize(entry), isDirectory: type == Self.ifDir || path.hasSuffix("/"),
                    isEncrypted: entryIsEncrypted(entry) != 0, modified: mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil))
                _ = readDataSkip(a)
            }
            if let failure {
                let e = ArchiveError.from(failure, hadPassword: password != nil)
                if e == .notAnArchive, !raw { continue }
                // Encrypted headers (7z with hidden names) can't even be listed.
                if entries.isEmpty || e == .needsPassword || e == .wrongPassword { throw e }
            }
            if raw, filterCount(a) <= 1 { throw ArchiveError.notAnArchive } // "raw" with no compression = not an archive
            if raw { return entries }
            // Names from Windows ZIPs are often in the PC's own code page, not UTF-8.
            let enc = NameEncoding.detect(raws, preferred: encoding)
            return zip(entries, raws).map { e, data in
                ArchiveEntryInfo(path: NameEncoding.decode(data, enc), size: e.size, isDirectory: e.isDirectory, isEncrypted: e.isEncrypted, modified: e.modified)
            }
        }
        throw ArchiveError.notAnArchive
    }

    /// "Photos.tar.gz" → "Photos", "Movie.7z.001" → "Movie", "Set.part1.rar" → "Set".
    static func baseName(of url: URL) -> String {
        var name = url.lastPathComponent
        if let r = name.range(of: #"\.\d{3}$"#, options: .regularExpression) { name.removeSubrange(r) }
        if let r = name.range(of: #"\.part\d+\.rar$"#, options: [.regularExpression, .caseInsensitive]) { name.replaceSubrange(r, with: ".rar") }
        let lower = name.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"] where lower.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }
}

/// How file names inside an archive are spelled in bytes. ZIPs made on Windows without the UTF-8
/// flag use the PC's code page — CP949 on Korean Windows, Shift_JIS on Japanese, and so on — and
/// macOS's own tools show those as gibberish. Orbit guesses from all the names at once, like Keka.
enum NameEncoding: String, CaseIterable, Sendable {
    case auto, utf8, cp949, shiftJIS, gbk, big5, cp437

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .utf8: "Unicode (UTF-8)"
        case .cp949: "Korean (CP949)"
        case .shiftJIS: "Japanese (Shift_JIS)"
        case .gbk: "Simplified Chinese (GBK)"
        case .big5: "Traditional Chinese (Big5)"
        case .cp437: "Western (DOS)"
        }
    }

    var stringEncoding: String.Encoding? {
        let cf: CFStringEncodings
        switch self {
        case .auto: return nil
        case .utf8: return .utf8
        case .cp949: cf = .dosKorean
        case .shiftJIS: cf = .dosJapanese
        case .gbk: cf = .GBK_95
        case .big5: cf = .dosChineseTrad
        case .cp437: cf = .dosLatinUS
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }

    static func decode(_ data: Data, _ enc: NameEncoding) -> String {
        if let s = String(data: data, encoding: .utf8) { return s } // ASCII, or flagged UTF-8 entries
        if let e = enc.stringEncoding, let s = String(data: data, encoding: e) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Picks the encoding that reads every name cleanly and most plausibly.
    static func detect(_ names: [Data], preferred: NameEncoding = .auto) -> NameEncoding {
        if preferred != .auto { return preferred }
        let foreign = names.filter { String(data: $0, encoding: .utf8) == nil }
        guard !foreign.isEmpty else { return .utf8 }
        var best: (NameEncoding, Double)?
        // Korean first: it wins ties for Orbit's Korean users.
        for candidate in candidates {
            guard let e = candidate.stringEncoding else { continue }
            var score = 0.0
            var ok = true
            for data in foreign {
                guard let s = String(data: data, encoding: e) else { ok = false; break }
                score += plausibility(s, candidate)
            }
            guard ok else { continue }
            if best == nil || score > best!.1 { best = (candidate, score) }
        }
        return best?.0 ?? .cp437
    }

    private static var candidates: [NameEncoding] {
        let lang = Locale.preferredLanguages.first ?? ""
        let first: NameEncoding = lang.hasPrefix("ja") ? .shiftJIS : lang.hasPrefix("zh-Hant") ? .big5 : lang.hasPrefix("zh") ? .gbk : .cp949
        return [first] + [.cp949, .shiftJIS, .gbk, .big5, .cp437].filter { $0 != first }
    }

    private static let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
    private static let gb2312 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_CN.rawValue)))
    private static let jis = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_JP.rawValue)))

    /// Per character: common letters of that language score up, rare or odd ones down. Wrong
    /// guesses decode into rare Hangul, half-width katakana or box-drawing symbols.
    private static func plausibility(_ s: String, _ enc: NameEncoding) -> Double {
        var score = 0.0
        for ch in s.unicodeScalars where ch.value >= 0x80 {
            let v = ch.value
            let str = String(ch)
            let hangul = (0xAC00...0xD7A3).contains(v)
            let kana = (0x3040...0x30FF).contains(v)
            let han = (0x4E00...0x9FFF).contains(v)
            let halfKana = (0xFF61...0xFF9F).contains(v)
            switch enc {
            case .cp949:
                if hangul { score += str.data(using: eucKR) != nil ? 2 : -1.5 } // KS X 1001's 2,350 everyday syllables
                else if han { score += 0.5 } else { score -= 1 }
            case .shiftJIS:
                if kana { score += 2 } else if han { score += str.data(using: jis) != nil ? 1.2 : -0.5 }
                else if halfKana { score -= 2 } else { score -= 1 }
            case .gbk:
                if han { score += str.data(using: gb2312) != nil ? 1.5 : -0.5 } else { score -= 1.5 }
            case .big5:
                if han { score += 1 } else { score -= 1.5 }
            case .cp437:
                score -= 0.5
            default:
                break
            }
        }
        return score
    }
}
