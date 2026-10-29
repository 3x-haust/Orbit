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

    var title: String {
        switch kind {
        case .text, .link, .color: (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false).count
            return lines > 1 ? "%ld characters · %ld lines".loc(t.count, lines) : "%ld characters".loc(t.count)
        case .link: return URL(string: text ?? "")?.host() ?? "Link"
        case .image: return "\(Int(imageSize?.width ?? 0)) × \(Int(imageSize?.height ?? 0)) px"
        case .file: return filePaths.map { $0.count == 1 ? "1 file".loc : "%ld files".loc($0.count) } ?? ""
        case .color: return text ?? ""
        }
    }

    /// Heuristic used to render text previews in a monospaced face.
    var looksLikeCode: Bool {
        guard kind == .text, let t = text else { return false }
        let markers = ["{", "}", ";", "=>", "func ", "const ", "import ", "</", "def ", "let "]
        return markers.filter { t.contains($0) }.count >= 2
    }

    var color: NSColor? {
        guard kind == .color, var hex = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 3 {
            let r = (v >> 8) & 0xF, g = (v >> 4) & 0xF, b = v & 0xF
            return NSColor(srgbRed: CGFloat(r * 17) / 255, green: CGFloat(g * 17) / 255, blue: CGFloat(b * 17) / 255, alpha: 1)
        }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
