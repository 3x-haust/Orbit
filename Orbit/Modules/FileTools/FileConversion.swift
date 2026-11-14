import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Where results go: always a new file (or folder) beside the original. Nothing is ever replaced.
enum FileOutput {
    /// "Photo" + "%@ Cropped" → "Photo Cropped" (localized), then the extension.
    static func name(_ source: URL, _ pattern: String?) -> String {
        let stem = source.deletingPathExtension().lastPathComponent
        return pattern.map { $0.loc(stem) } ?? stem
    }

    /// A name that's free right now: "Photo.jpg", "Photo 2.jpg", …
    static func free(in folder: URL, stem: String, ext: String) -> URL {
        var number = 1
        while true {
            let name = stem + (number == 1 ? "" : " \(number)") + (ext.isEmpty ? "" : "." + ext)
            let url = folder.appendingPathComponent(name)
            // attributesOfItem doesn't follow a final symlink, so a broken link still counts as taken.
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil { return url }
            number += 1
        }
    }

    /// Where a writer that can't write exclusively (AVFoundation, PDFKit, GIF) works: a private folder
    /// on the same volume. `place` then moves the finished file in under a free name.
    static func scratch(for source: URL, ext: String) throws -> URL {
        let folder = (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                   appropriateFor: source, create: true))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString + "." + ext)
    }

    /// Moving never replaces: if the name was taken meanwhile, the next one is used.
    static func place(_ temp: URL, beside source: URL, _ pattern: String? = nil, ext: String) throws -> URL {
        defer { discard(temp) }
        let folder = source.deletingLastPathComponent(), stem = name(source, pattern)
        while true {
            let url = free(in: folder, stem: stem, ext: ext)
            do {
                try FileManager.default.moveItem(at: temp, to: url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
    }

    /// Removes a scratch file and its private folder.
    static func discard(_ temp: URL) {
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
    }

    /// Exclusive creation also covers a file appearing between choosing the name and writing it.
    static func write(_ data: Data, beside source: URL, _ pattern: String? = nil, ext: String) throws -> URL {
        try write(data, in: source.deletingLastPathComponent(), stem: name(source, pattern), ext: ext)
    }

    static func write(_ data: Data, in folder: URL, stem: String, ext: String) throws -> URL {
        while true {
            let url = free(in: folder, stem: stem, ext: ext)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
    }

    /// A new folder for many results (PDF pages, split pages).
    static func folder(beside source: URL, _ pattern: String? = nil) throws -> URL {
        while true {
            let url = free(in: source.deletingLastPathComponent(), stem: name(source, pattern), ext: "")
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue // another job took the name first
            }
        }
    }

    /// "Page 07" for a 12-page document, so the files sort in page order.
    static func pageName(_ index: Int, of count: Int) -> String {
        let digits = String(count).count
        return "Page %@".loc(String(format: "%0\(digits)d", index))
    }
}

enum FileToolError: LocalizedError, Equatable {
    case unreadable, locked, tooLarge, encoding, noText, noSound, noVideo, unsupported, exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is damaged or couldn’t be read.".loc
        case .locked: "This PDF is password-protected.".loc
        case .tooLarge: "This page is too large to convert.".loc
        case .encoding: "The result couldn’t be saved.".loc
        case .noText: "There’s no text to take out — it may be a scan.".loc
        case .noSound: "This video has no sound.".loc
        case .noVideo: "This file has no picture.".loc
        case .unsupported: "macOS can’t convert this file.".loc
        case .exportFailed(let reason): reason
        }
    }
}

/// What a finished run reports besides its files ("2.4 MB → 610 KB").
struct FileRunNote: Sendable {
    var text: String
}

/// The conversions and one-step tools. Each call writes new files beside its input and reports each
/// one through `saved` as soon as it exists, so a failure or cancellation part-way keeps what's done.
enum FileEngine {
    typealias Saved = @Sendable (URL) -> Void
    typealias Progress = @Sendable (Double) -> Void

    static func run(_ action: FileAction, files: [URL], progress: @escaping Progress, saved: @escaping Saved) async throws -> FileRunNote? {
        switch action {
        case .convert(let format):
            guard let kind = files.first.flatMap(FileKind.of) else { throw FileToolError.unsupported }
            if kind == .image, format == .pdf {
                try imagesToPDF(files, saved: saved)
                return nil
            }
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                let part: Progress = { progress((Double(i) + $0) / Double(files.count)) }
                switch kind {
                case .image: saved(try convertImage(file, to: format))
                case .pdf: try await convertPDF(file, to: format, progress: part, saved: saved)
                case .document: saved(try await convertDocument(file, to: format))
                case .video, .audio: saved(try await convertMedia(file, kind: kind, to: format, progress: part))
                }
                progress(Double(i + 1) / Double(files.count))
            }
            return nil
        case .compress:
            var before: Int64 = 0, after: Int64 = 0
            var skipped = 0
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                let part: Progress = { progress((Double(i) + $0) / Double(files.count)) }
                let output: URL
                switch FileKind.of(file) {
                case .image: output = try compressImage(file)
                case .pdf: output = try compressPDF(file)
                case .video: output = try await compressVideo(file, progress: part)
                default: throw FileToolError.unsupported
                }
                let inSize = size(of: file), outSize = size(of: output)
                if outSize >= inSize {
                    // Not smaller: a bigger "compressed" copy is worse than none.
                    try? FileManager.default.removeItem(at: output)
                    skipped += 1
                } else {
                    before += inSize
                    after += outSize
                    saved(output)
                }
                progress(Double(i + 1) / Double(files.count))
            }
            var parts: [String] = []
            if after > 0 {
                let f = ByteCountFormatter()
                parts.append("%@ → %@".loc(f.string(fromByteCount: before), f.string(fromByteCount: after)))
            }
            if skipped > 0 {
                parts.append(files.count == 1 ? "Already as small as it gets.".loc : "%ld were already as small as they get.".loc(skipped))
            }
            return parts.isEmpty ? nil : FileRunNote(text: parts.joined(separator: " "))
        case .stripMetadata:
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                saved(try stripMetadata(file))
                progress(Double(i + 1) / Double(files.count))
            }
            return nil
        case .split:
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                try splitPDF(file, saved: saved)
                progress(Double(i + 1) / Double(files.count))
            }
            return nil
        case .merge:
            saved(try mergePDFs(files))
            return nil
        case .mute:
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                saved(try await muteVideo(file, progress: { progress((Double(i) + $0) / Double(files.count)) }))
            }
            return nil
        case .crop, .background, .annotate, .redact:
            throw FileToolError.unsupported // these open a window
        }
    }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    // MARK: Images

    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw FileToolError.unreadable }
        return source
    }

    /// The full-size picture turned upright (EXIF orientation applied).
    static func uprightImage(_ source: CGImageSource) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { throw FileToolError.unreadable }
        guard w * h <= 200_000_000 else { throw FileToolError.tooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw FileToolError.unreadable }
        return image
    }

    static func uprightImage(at url: URL) throws -> CGImage { try uprightImage(try source(url)) }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// For formats without transparency: transparent areas turn white, not black.
    static func flattened(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                ?? CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw FileToolError.encoding }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw FileToolError.encoding }
        return flat
    }

    static func encode(_ image: CGImage, as format: FileFormat, quality: Double = 0.92, dpi: CGFloat? = nil) throws -> Data {
        let data = NSMutableData()
        guard format.canWriteImage,
              let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw FileToolError.unsupported
        }
        let image = (format == .jpg || format == .bmp) && hasAlpha(image) ? try flattened(image) : image
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let dpi { options[kCGImagePropertyDPIWidth] = dpi; options[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FileToolError.encoding }
        return data as Data
    }

    static func dpi(of source: CGImageSource) -> CGFloat {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return dpi > 0 ? dpi : 72
    }

    static func convertImage(_ url: URL, to format: FileFormat) throws -> URL {
        let src = try source(url)
        // Drawn upright, so the result looks right even where the format has no orientation tag.
        let data = try encode(try uprightImage(src), as: format, dpi: dpi(of: src))
        return try FileOutput.write(data, beside: url, ext: format.ext)
    }

    /// One page per picture, in the order they were dragged; each page is the picture's own size.
    static func imagesToPDF(_ files: [URL], saved: Saved) throws {
        guard let first = files.first else { return }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw FileToolError.encoding }
        for file in files {
            try Task.checkCancellation()
            try autoreleasepool {
                let src = try source(file)
                let image = try uprightImage(src)
                let scale = 72 / dpi(of: src)
                var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                context.beginPage(mediaBox: &box)
                context.interpolationQuality = .high
                context.draw(image, in: box)
                context.endPage()
            }
        }
        context.closePDF()
        saved(try FileOutput.write(data as Data, beside: first, files.count > 1 ? "%@ and More" : nil, ext: "pdf"))
    }

    static func compressImage(_ url: URL) throws -> URL {
        let image = try uprightImage(at: url)
        // Transparency survives only in HEIC; everything else becomes a JPEG.
        let format: FileFormat = hasAlpha(image) && FileFormat.heic.canWriteImage ? .heic : .jpg
        let data = try encode(image, as: format, quality: 0.7)
        return try FileOutput.write(data, beside: url, "%@ Compressed", ext: format.ext)
    }

    /// Location, camera, dates and the rest go; the picture's pixels and orientation stay as they were.
    static func stripMetadata(_ url: URL) throws -> URL {
        let src = try source(url)
        guard let type = CGImageSourceGetType(src) else { throw FileToolError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation]
        let ext = url.pathExtension.isEmpty ? (UTType(type as String)?.preferredFilenameExtension ?? "img") : url.pathExtension

        // JPEG and HEIC: copy the compressed data as it is (no quality loss) with empty metadata, then
        // check — ImageIO doesn't clear every block for every format, so anything left falls through.
        if let utType = UTType(type as String), utType.conforms(to: .jpeg) || utType.conforms(to: .heic) {
            let data = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(data, type, 1, nil) {
                let metadata = CGImageMetadataCreateMutable()
                if let orientation {
                    CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFTypeRef)
                }
                let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
                if CGImageDestinationCopyImageSource(destination, src, options as CFDictionary, nil), isClean(data as Data) {
                    return try FileOutput.write(data as Data, beside: url, "%@ No Metadata", ext: ext)
                }
            }
        }
        // Everything else: re-encode the pixels (lossless for PNG/TIFF), every frame of an animation,
        // carrying only orientation and frame timing.
        let count = CGImageSourceGetCount(src)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, count, nil) else { throw FileToolError.unsupported }
        if let loop = (CGImageSourceCopyProperties(src, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loops = loop[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loops]] as CFDictionary)
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(src, index, nil) else { throw FileToolError.unreadable }
            let frame = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any] ?? [:]
            var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
            if let orientation { options[kCGImagePropertyOrientation] = orientation }
            for timing in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary] {
                guard let dict = frame[timing] as? [CFString: Any] else { continue }
                let keep = [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime,
                            kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime]
                let kept = dict.filter { keep.contains($0.key) }
                if !kept.isEmpty { options[timing] = kept }
            }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw FileToolError.encoding }
        guard isClean(data as Data) else { throw FileToolError.encoding }
        return try FileOutput.write(data as Data, beside: url, "%@ No Metadata", ext: ext)
    }

    /// No location, camera, lens, date or IPTC data left in the first frame.
    static func isClean(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        if props[kCGImagePropertyGPSDictionary] != nil || props[kCGImagePropertyIPTCDictionary] != nil { return false }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let telling: [CFString] = [kCGImagePropertyExifLensModel, kCGImagePropertyExifLensMake, kCGImagePropertyExifDateTimeOriginal,
                                   kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifUserComment]
        if telling.contains(where: { exif[$0] != nil }) { return false }
        return [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist]
            .allSatisfy { tiff[$0] == nil }
    }

    // MARK: PDF

    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw FileToolError.unreadable }
        guard !document.isLocked else { throw FileToolError.locked }
        guard document.pageCount > 0 else { throw FileToolError.unreadable }
        return document
    }

    static func convertPDF(_ url: URL, to format: FileFormat, progress: Progress, saved: Saved) async throws {
        switch format {
        case .jpg, .png:
            guard let pdf = CGPDFDocument(url as CFURL) else { throw FileToolError.unreadable }
            guard !pdf.isEncrypted || pdf.isUnlocked else { throw FileToolError.locked }
            let count = pdf.numberOfPages
            guard count > 0 else { throw FileToolError.unreadable }
            // One page sits beside the PDF; more go together in a folder named after it.
            let folder = count == 1 ? nil : try FileOutput.folder(beside: url)
            defer {
                // Nothing saved (cancelled or failed on page 1): don't leave an empty folder behind.
                if let folder, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            for index in 1...count {
                try Task.checkCancellation()
                let data = try autoreleasepool { () throws -> Data in
                    guard let page = pdf.page(at: index) else { throw FileToolError.unreadable }
                    return try encode(try render(page), as: format, dpi: 144)
                }
                try Task.checkCancellation()
                if let folder {
                    saved(try FileOutput.write(data, in: folder, stem: FileOutput.pageName(index, of: count), ext: format.ext))
                } else {
                    saved(try FileOutput.write(data, beside: url, ext: format.ext))
                }
                progress(Double(index) / Double(count))
            }
        case .txt:
            let pdf = try document(url)
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileToolError.noText }
            saved(try FileOutput.write(Data(text.utf8), beside: url, ext: "txt"))
        case .docx, .rtf:
            let pdf = try document(url)
            let text = NSMutableAttributedString()
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index)?.attributedString, page.length > 0 else { continue }
                if text.length > 0 { text.append(NSAttributedString(string: "\n\n")) }
                text.append(page)
            }
            guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FileToolError.noText }
            saved(try FileOutput.write(try data(of: text, as: format), beside: url, ext: format.ext))
        default:
            throw FileToolError.unsupported
        }
    }

    /// A page at 144 dpi (2×), white behind it, crop box and rotation applied.
    static func render(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        let scale: CGFloat = 2
        let width = ceil((rotated ? box.height : box.width) * scale)
        let height = ceil((rotated ? box.width : box.height) * scale)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw FileToolError.unreadable }
        guard width * height <= 60_000_000 else { throw FileToolError.tooLarge }
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw FileToolError.encoding }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // getDrawingTransform never enlarges, so scale first and fit in page points.
        context.scaleBy(x: scale, y: scale)
        let pageRect = CGRect(x: 0, y: 0, width: width / scale, height: height / scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: pageRect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw FileToolError.encoding }
        return image
    }

    static func compressPDF(_ url: URL) throws -> URL {
        let pdf = try document(url)
        let temp = try FileOutput.scratch(for: url, ext: "pdf")
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard pdf.write(to: temp, withOptions: options) else { FileOutput.discard(temp); throw FileToolError.encoding }
        return try FileOutput.place(temp, beside: url, "%@ Compressed", ext: "pdf")
    }

    static func splitPDF(_ url: URL, saved: Saved) throws {
        let pdf = try document(url)
        let folder = try FileOutput.folder(beside: url, "%@ Pages")
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index)?.copy() as? PDFPage else { throw FileToolError.unreadable }
            let single = PDFDocument()
            single.insert(page, at: 0)
            guard let data = single.dataRepresentation() else { throw FileToolError.encoding }
            saved(try FileOutput.write(data, in: folder, stem: FileOutput.pageName(index + 1, of: pdf.pageCount), ext: "pdf"))
        }
    }

    /// Pages in the order the files were dragged.
    static func mergePDFs(_ files: [URL]) throws -> URL {
        guard let first = files.first else { throw FileToolError.unsupported }
        let merged = PDFDocument()
        for file in files {
            try Task.checkCancellation()
            let pdf = try document(file)
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index)?.copy() as? PDFPage else { throw FileToolError.unreadable }
                merged.insert(page, at: merged.pageCount)
            }
        }
        guard let data = merged.dataRepresentation() else { throw FileToolError.encoding }
        return try FileOutput.write(data, beside: first, "%@ Merged", ext: "pdf")
    }

    // MARK: Documents

    static func data(of text: NSAttributedString, as format: FileFormat) throws -> Data {
        let range = NSRange(location: 0, length: text.length)
        let type: NSAttributedString.DocumentType
        switch format {
        case .txt: return Data(text.string.utf8)
        case .rtf: type = .rtf
        case .docx: type = .officeOpenXML
        case .odt: type = .openDocument
        case .html: type = .html
        default: throw FileToolError.unsupported
        }
        return try text.data(from: range, documentAttributes: [.documentType: type])
    }

    /// Word, Pages-free formats: AppKit's own text system reads and writes them. HTML needs the main thread.
    @MainActor
    static func convertDocument(_ url: URL, to format: FileFormat) async throws -> URL {
        let text: NSAttributedString
        do {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw FileToolError.unreadable
        }
        if format == .pdf {
            return try FileOutput.write(try pdf(of: text), beside: url, ext: "pdf")
        }
        return try FileOutput.write(try data(of: text, as: format), beside: url, ext: format.ext)
    }

    /// Paginated like printing: the paper size and margins of the default printer settings.
    @MainActor
    static func pdf(of text: NSAttributedString) throws -> Data {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        for edge in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: edge] = 56 }
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()

        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), let data = try? Data(contentsOf: output) else { throw FileToolError.encoding }
        return data
    }

    // MARK: Video and audio

    static func convertMedia(_ url: URL, kind: FileKind, to format: FileFormat, progress: @escaping Progress) async throws -> URL {
        switch format {
        case .gif: return try await videoToGIF(url, progress: progress)
        case .wav, .aiff: return try audioToPCM(url, as: format, progress: progress)
        case .m4a:
            let asset = AVURLAsset(url: url)
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw kind == .video ? FileToolError.noSound : FileToolError.unreadable }
            return try await export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, beside: url, ext: "m4a", progress: progress)
        case .mp4, .mov:
            let asset = AVURLAsset(url: url)
            guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw FileToolError.noVideo }
            let type: AVFileType = format == .mp4 ? .mp4 : .mov
            // Rewrap without re-encoding when the codecs fit the new container; re-encode otherwise.
            do {
                return try await export(asset, preset: AVAssetExportPresetPassthrough, type: type, beside: url, ext: format.ext, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await export(asset, preset: AVAssetExportPresetHighestQuality, type: type, beside: url, ext: format.ext, progress: progress)
            }
        default:
            throw FileToolError.unsupported
        }
    }

    static func export(_ asset: AVAsset, preset: String, type: AVFileType, beside source: URL, _ pattern: String? = nil,
                       ext: String, progress: @escaping Progress) async throws -> URL {
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw FileToolError.unsupported }
        let temp = try FileOutput.scratch(for: source, ext: ext)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: temp, as: type)
            try Task.checkCancellation()
        } catch {
            FileOutput.discard(temp)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw FileToolError.exportFailed(error.localizedDescription)
        }
        return try FileOutput.place(temp, beside: source, pattern, ext: ext)
    }

    static func videoToGIF(_ url: URL, progress: @escaping Progress) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw FileToolError.noVideo }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FileToolError.unreadable }
        // Smooth for short clips; long ones get fewer frames (at most 240) so memory and size stay sane.
        let count = max(1, min(240, Int(duration * 15)))
        let fps = Double(count) / duration
        let times = (0..<count).map { NSValue(time: CMTime(seconds: Double($0) / fps, preferredTimescale: 600)) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let temp = try FileOutput.scratch(for: url, ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            FileOutput.discard(temp)
            throw FileToolError.encoding
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var done = 0
        do {
            for await result in generator.images(for: times.map(\.timeValue)) {
                try Task.checkCancellation()
                if let image = try? result.image {
                    CGImageDestinationAddImage(destination, image, frame)
                    done += 1
                }
                progress(Double(done) / Double(count))
            }
            // The frame sequence may just end when cancelled: never save that as a finished GIF.
            try Task.checkCancellation()
            guard done > count / 2, CGImageDestinationFinalize(destination) else { throw FileToolError.encoding }
        } catch {
            FileOutput.discard(temp)
            throw error
        }
        return try FileOutput.place(temp, beside: url, ext: "gif")
    }

    /// WAV and AIFF: 16-bit PCM at the source's own rate and channels.
    static func audioToPCM(_ url: URL, as format: FileFormat, progress: Progress) throws -> URL {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url) } catch { throw FileToolError.unreadable }
        let source = input.processingFormat
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                       AVSampleRateKey: source.sampleRate,
                                       AVNumberOfChannelsKey: source.channelCount,
                                       AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false,
                                       AVLinearPCMIsBigEndianKey: format == .aiff,
                                       AVLinearPCMIsNonInterleaved: false]
        let ext = format == .aiff ? "aiff" : "wav"
        let temp = try FileOutput.scratch(for: url, ext: ext)
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: source.commonFormat, interleaved: source.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 32_768) else { throw FileToolError.encoding }
            let total = max(1, Double(input.length))
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try file.write(from: buffer)
                progress(Double(input.framePosition) / total)
            }
        } catch {
            FileOutput.discard(temp)
            if error is CancellationError || error is FileToolError { throw error }
            throw FileToolError.exportFailed(error.localizedDescription)
        }
        return try FileOutput.place(temp, beside: url, ext: ext)
    }

    /// HEVC at up to 1080p, in the same container.
    static func compressVideo(_ url: URL, progress: @escaping Progress) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw FileToolError.noVideo }
        let isMov = url.pathExtension.lowercased() == "mov"
        let type: AVFileType = isMov ? .mov : .mp4
        for preset in [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080] {
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type) else { continue }
            return try await export(asset, preset: preset, type: type, beside: url, "%@ Compressed", ext: isMov ? "mov" : "mp4", progress: progress)
        }
        throw FileToolError.unsupported
    }

    /// The picture as it was (no re-encoding), without any sound track.
    static func muteVideo(_ url: URL, progress: @escaping Progress) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw FileToolError.noVideo }
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in tracks {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        let isMov = url.pathExtension.lowercased() == "mov"
        let type: AVFileType = isMov ? .mov : .mp4
        let ext = isMov ? "mov" : "mp4"
        do {
            return try await export(composition, preset: AVAssetExportPresetPassthrough, type: type, beside: url, "%@ Muted", ext: ext, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await export(composition, preset: AVAssetExportPresetHighestQuality, type: type, beside: url, "%@ Muted", ext: ext, progress: progress)
        }
    }
}
