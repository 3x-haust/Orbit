import AppKit

struct ClipItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case text, link, image, file, color

        var title: String {
            switch self {
            case .text: "Text"
            case .link: "Link"
            case .image: "Image"
            case .file: "File"
            case .color: "Color"
            }
        }

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .file: "doc"
            case .color: "paintpalette"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var text: String?
    /// File name inside Storage "Clips" for image PNGs or RTF payloads.
    var imageFile: String?
    var rtfFile: String?
    var filePaths: [String]?
    var imageSize: CGSize?
    var ocrText: String?
    var appBundleID: String?
    var appName: String?
    var date = Date()
    var pinned = false
    var signature: String

    var imageURL: URL? { imageFile.map { ClipboardStore.dir.appendingPathComponent($0) } }
    var rtfURL: URL? { rtfFile.map { ClipboardStore.dir.appendingPathComponent($0) } }

    /// Bound work before grapheme segmentation: one Character can contain millions of scalars.
    /// Only presentation is shortened; persistence, search and copying keep the original text.
    static func preview(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars.prefix(2_049))
        guard scalars.count > 2_048 else { return text }
        scalars.removeLast()
        var result = String(String.UnicodeScalarView(scalars))
        // Drop the possibly incomplete final grapheme from the already bounded copy.
        result.removeLast()
        return result + "…"
    }

    var previewText: String { Self.preview(text ?? "") }

    var linkHost: String? {
        guard let text, text.utf8.count <= 8_192 else { return nil }
        return URL(string: text)?.host()
    }

    var title: String {
        switch kind {
        case .text, .link, .color: previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image: "Image %ld × %ld".loc(Int(imageSize?.width ?? 0), Int(imageSize?.height ?? 0))
        case .file: filePaths?.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") ?? "Files"
        }
    }

    var searchable: String {
        [text, ocrText, appName, filePaths?.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
    }

    var footnote: String {
        switch kind {
        case .text:
            let t = text ?? ""
            if t.utf8.count > 8_192 {
                return ByteCountFormatter.string(fromByteCount: Int64(t.utf8.count), countStyle: .file)
            }
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false).count
            return lines > 1 ? "%ld characters · %ld lines".loc(t.count, lines) : "%ld characters".loc(t.count)
        case .link: return linkHost ?? "Link"
        case .image: return "\(Int(imageSize?.width ?? 0)) × \(Int(imageSize?.height ?? 0)) px"
        case .file: return filePaths.map { $0.count == 1 ? "1 file".loc : "%ld files".loc($0.count) } ?? ""
        case .color: return previewText
        }
    }

    /// Heuristic used to render text previews in a monospaced face.
    var looksLikeCode: Bool {
        guard kind == .text else { return false }
        let t = previewText
        let markers = ["{", "}", ";", "=>", "func ", "const ", "import ", "</", "def ", "let "]
        return markers.filter { t.contains($0) }.count >= 2
    }

    var color: NSColor? {
        guard kind == .color, let text, text.utf8.count <= 64 else { return nil }
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 3 {
            let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
            return NSColor(srgbRed: CGFloat(r * 17) / 255, green: CGFloat(g * 17) / 255, blue: CGFloat(b * 17) / 255, alpha: 1)
        }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
