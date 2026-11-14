import AppKit
import ImageIO
import UniformTypeIdentifiers

/// What a dragged file is, as far as the file ring cares.
enum FileKind: String, Sendable {
    case image, pdf, document, video, audio

    static func of(_ url: URL) -> FileKind? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true, let type = values.contentType else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return FileFormat.readableImages.contains(where: type.conforms) ? .image : nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if FileFormat.documents.contains(where: type.conforms) { return .document }
        return nil
    }
}

/// A format a file can be converted to.
enum FileFormat: String, CaseIterable, Sendable {
    case jpg, png, heic, tiff, bmp, gif, pdf
    case txt, rtf, docx, odt, html
    case mp4, mov, m4a, wav, aiff

    var ext: String { rawValue }
    var title: String { rawValue.uppercased() }

    var type: UTType {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        case .pdf: .pdf
        case .txt: .plainText
        case .rtf: .rtf
        case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .odt: UTType("org.oasis-open.opendocument.text") ?? .data
        case .html: .html
        case .mp4: .mpeg4Movie
        case .mov: .quickTimeMovie
        case .m4a: .mpeg4Audio
        case .wav: .wav
        case .aiff: .aiff
        }
    }

    /// Whether `url` already is this format, so the ring doesn't offer a no-op.
    func matches(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: self.type)
    }

    static let readableImages: [UTType] = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
    private static let writableImages = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    var canWriteImage: Bool { Self.writableImages.contains(type.identifier) }

    static let documents: [UTType] = [.rtf, .rtfd, .flatRTFD, .plainText, .html,
                                      UTType("org.openxmlformats.wordprocessingml.document"),
                                      UTType("com.microsoft.word.doc"),
                                      UTType("org.oasis-open.opendocument.text"),
                                      UTType("com.microsoft.word.wordml")].compactMap { $0 }
}

/// One slot on the file ring.
enum FileAction: Hashable, Sendable {
    case convert(FileFormat)
    case crop, background, annotate, redact, compress, stripMetadata
    case split, merge, mute

    var title: String {
        switch self {
        case .convert(let format): format.title
        case .crop: "Crop"
        case .background: "Background"
        case .annotate: "Annotate"
        case .redact: "Redact"
        case .compress: "Compress"
        case .stripMetadata: "Metadata"
        case .split: "Split"
        case .merge: "Merge"
        case .mute: "Mute"
        }
    }

    var symbol: String? {
        switch self {
        case .convert: nil
        case .crop: "crop"
        case .background: "photo.on.rectangle"
        case .annotate: "pencil.tip.crop.circle"
        case .redact: "eye.slash"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .stripMetadata: "tag.slash"
        case .split: "square.split.2x1"
        case .merge: "square.stack"
        case .mute: "speaker.slash"
        }
    }

    /// Opens a window instead of running straight away.
    var isInteractive: Bool { [.crop, .background, .annotate, .redact].contains(self) }

    /// What the progress card says once it's done.
    var doneTitle: String {
        switch self {
        case .convert(let format): "Converted to %@".loc(format.title)
        case .compress: "Compressed".loc
        case .stripMetadata: "Metadata removed".loc
        case .split: "Pages split".loc
        case .merge: "PDFs merged".loc
        case .mute: "Sound removed".loc
        default: title.loc
        }
    }

    /// What the progress card says while it runs.
    var progressTitle: String {
        switch self {
        case .convert(let format): "Converting to %@".loc(format.title)
        case .compress: "Compressing".loc
        case .stripMetadata: "Removing metadata".loc
        case .split: "Splitting pages".loc
        case .merge: "Merging PDFs".loc
        case .mute: "Removing sound".loc
        default: title.loc
        }
    }
}

/// The two faces of the ring: Shift opens Convert, pressing Shift again flips to Tools.
enum FileRingMode: String, CaseIterable, Sendable {
    case convert, tools
    var title: String { self == .convert ? "Convert" : "Tools" }
}

/// The slots offered for a set of files. The hub is the action in the middle of the ring.
struct FileMenu: Equatable, Sendable {
    var outer: [FileAction] = []
    var hub: FileAction?
    var isEmpty: Bool { outer.isEmpty && hub == nil }

    static func menu(for files: [URL], mode: FileRingMode) -> FileMenu {
        guard let first = files.first, let kind = FileKind.of(first),
              files.allSatisfy({ FileKind.of($0) == kind }) else { return FileMenu() }
        let single = files.count == 1
        /// Formats every file can become (a file is never converted to its own format).
        func formats(_ list: [FileFormat]) -> [FileAction] {
            list.filter { format in !files.allSatisfy(format.matches) }.map { .convert($0) }
        }
        switch (kind, mode) {
        case (.image, .convert):
            let outer = formats([.jpg, .png, .heic, .tiff, .bmp].filter(\.canWriteImage))
            return FileMenu(outer: outer, hub: .convert(.pdf))
        case (.image, .tools):
            return single
                ? FileMenu(outer: [.crop, .background, .compress, .stripMetadata, .redact], hub: .annotate)
                : FileMenu(outer: [.compress, .stripMetadata])
        case (.pdf, .convert):
            return FileMenu(outer: [.convert(.docx), .convert(.jpg), .convert(.png), .convert(.rtf)], hub: .convert(.txt))
        case (.pdf, .tools):
            return FileMenu(outer: single ? [.compress, .split] : [.compress, .split, .merge])
        case (.document, .convert):
            return FileMenu(outer: formats([.docx, .rtf, .txt, .html, .odt]), hub: .convert(.pdf))
        case (.document, .tools):
            return FileMenu()
        case (.video, .convert):
            return FileMenu(outer: formats([.mp4, .mov, .gif, .m4a]))
        case (.video, .tools):
            return FileMenu(outer: [.compress, .mute])
        case (.audio, .convert):
            return FileMenu(outer: formats([.m4a, .wav, .aiff]))
        case (.audio, .tools):
            return FileMenu()
        }
    }
}
