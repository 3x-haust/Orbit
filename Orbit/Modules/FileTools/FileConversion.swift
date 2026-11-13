import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Outputs stay beside their source. An existing file is never replaced.
enum FileConversion {
    struct Result: Sendable {
        var files: [URL] = []
        var failure: String?
        var cancelled = false
    }

    enum Failure: LocalizedError {
        case unsupported, unreadable, tooLarge, encoding
        var errorDescription: String? {
            switch self {
            case .unsupported: "Choose one PDF or image file.".loc
            case .unreadable: "This file is damaged, locked, or could not be read.".loc
            case .tooLarge: "This page is too large to convert.".loc
            case .encoding: "The image could not be saved.".loc
            }
        }
    }

    enum Kind { case pdf, image }

    static func kind(of url: URL) -> Kind? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true else { return nil }
        if values.contentType?.conforms(to: .pdf) == true { return .pdf }
        if values.contentType?.conforms(to: .image) == true { return .image }
        return nil
    }

    /// Exclusive creation also handles a file appearing after the name was chosen.
    static func save(_ data: Data, beside source: URL, suffix: String, extension ext: String) throws -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent + suffix
        var number = 1
        while true {
            let name = stem + (number == 1 ? "" : " (\(number))") + "." + ext
            let url = folder.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                number += 1
            }
        }
    }

    /// Pages are decoded one at a time off the main thread. On failure/cancellation the completed
    /// pages remain available; no later pages are attempted and nothing is silently discarded.
    static func convertPDF(_ source: URL) -> Result {
        var result = Result()
        guard kind(of: source) == .pdf else {
            result.failure = Failure.unsupported.localizedDescription
            return result
        }
        guard let document = CGPDFDocument(source as CFURL), !document.isEncrypted || document.isUnlocked,
              document.numberOfPages > 0 else {
            result.failure = Failure.unreadable.localizedDescription
            return result
        }
        for index in 1...document.numberOfPages {
            if Task<Never, Never>.isCancelled { result.cancelled = true; break }
            do {
                let output = try autoreleasepool {
                    guard let page = document.page(at: index) else { throw Failure.unreadable }
                    let data = try jpeg(page)
                    try Task<Never, Never>.checkCancellation()
                    let suffix = document.numberOfPages == 1 ? "" : " - \(index)"
                    return try save(data, beside: source, suffix: suffix, extension: "jpg")
                }
                result.files.append(output)
                if Task<Never, Never>.isCancelled { result.cancelled = true; break }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failure = "Page %ld: %@".loc(index, error.localizedDescription)
                break
            }
        }
        return result
    }

    private static func jpeg(_ page: CGPDFPage) throws -> Data {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let width = ceil((rotated ? box.height : box.width) * 2)
        let height = ceil((rotated ? box.width : box.height) * 2)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw Failure.unreadable }
        // A 40-megapixel bitmap already needs 160 MB before encoding.
        guard width * height <= 40_000_000 else { throw Failure.tooLarge }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.encoding }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        // getDrawingTransform fits down but does not enlarge a page. Set the raster resolution
        // explicitly, then use its crop/rotation transform in PDF points.
        context.scaleBy(x: 2, y: 2)
        let pageRect = CGRect(x: 0, y: 0, width: width / 2, height: height / 2)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw Failure.encoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.encoding
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
        return data as Data
    }
}
