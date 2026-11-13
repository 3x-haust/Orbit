import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Orbit

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private struct Skipped: Error {
    let reason: String
}

@MainActor
private final class Suite {
    let root: URL
    var passed = 0
    var failed = 0
    var skipped = 0

    init(scratch: URL) throws {
        root = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func run(_ name: String, _ body: @MainActor (URL) async throws -> Void) async {
        if let filter = ProcessInfo.processInfo.environment["ORBIT_FILE_TEST_FILTER"],
           name.range(of: filter, options: .regularExpression) == nil { return }
        do {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await body(folder)
            passed += 1
            print("PASS \(name)")
        } catch let skip as Skipped {
            skipped += 1
            print("SKIP \(name): \(skip.reason)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
        fflush(stdout)
    }
}

@main @MainActor
struct FileToolsTests {
    private struct Page {
        var width = 80
        var height = 60
        var rotation = 0
        var blank = false
    }

    private static let red: [CGFloat] = [1, 0, 0]
    private static let green: [CGFloat] = [0, 1, 0]
    private static let blue: [CGFloat] = [0, 0, 1]
    private static let yellow: [CGFloat] = [1, 1, 0]
    private static let white: [CGFloat] = [1, 1, 1]

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(description: message) }
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CheckFailure(description: message) }
        return value
    }

    // A small vector PDF allows oversized page boxes without allocating oversized bitmaps.
    private static func pdf(_ pages: [Page], at url: URL) throws {
        let kids = pages.indices.map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count \(pages.count) /Kids [\(kids)] >>"]
        for (index, page) in pages.enumerated() {
            let w = page.width, h = page.height
            let stream = page.blank ? "" : """
            1 0 0 rg 0 \(h / 2) \(w / 2) \(h / 2) re f
            0 1 0 rg \(w / 2) \(h / 2) \(w / 2) \(h / 2) re f
            0 0 1 rg 0 0 \(w / 2) \(h / 2) re f
            1 1 0 rg \(w / 2) 0 \(w / 2) \(h / 2) re f
            """
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(w) \(h)] /Rotate \(page.rotation) /Resources << >> /Contents \(4 + index * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        try data.write(to: url)
        let document = try unwrap(CGPDFDocument(url as CFURL), "PDF fixture must decode")
        try expect(document.numberOfPages == pages.count, "PDF fixture must contain every requested page")
    }

    private static func decode(_ url: URL, type: UTType, width: Int, height: Int) throws -> NSBitmapImageRep {
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "Cannot decode \(url.lastPathComponent)")
        try expect(CGImageSourceGetType(source) as String? == type.identifier, "\(url.lastPathComponent) must encode \(type.identifier), not merely use its extension")
        try expect(CGImageSourceGetCount(source) == 1, "Each output must contain one image")
        let image = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Missing encoded pixels")
        try expect(image.width == width && image.height == height,
                   "\(url.lastPathComponent): expected \(width)x\(height), got \(image.width)x\(image.height)")
        let context = try unwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                           bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Cannot normalize decoded pixels")
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: try unwrap(context.makeImage(), "Cannot read normalized pixels"))
    }

    private static func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int, equals expected: [CGFloat], tolerance: CGFloat = 0.08) throws {
        // decode already normalizes to sRGB. colorAt labels these channel values as calibrated RGB;
        // converting that label again would apply a second, incorrect color transform.
        let sample = try unwrap(bitmap.colorAt(x: x, y: y), "Missing pixel at \(x),\(y)")
        let actual = [sample.redComponent, sample.greenComponent, sample.blueComponent]
        try expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance } && sample.alphaComponent > 0.98,
                   "Pixel \(x),\(y): expected opaque \(expected), got \(actual), alpha \(sample.alphaComponent)")
    }

    private static func quadrants(_ bitmap: NSBitmapImageRep, _ colors: [[CGFloat]]) throws {
        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        for (index, point) in [(w / 4, h / 4), (w * 3 / 4, h / 4), (w / 4, h * 3 / 4), (w * 3 / 4, h * 3 / 4)].enumerated() {
            try color(bitmap, x: point.0, y: point.1, equals: colors[index])
        }
    }

    private static func png(at url: URL) throws -> Data {
        let context = try unwrap(CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
                                           bytesPerRow: 480, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "Cannot allocate PNG fixture")
        for (index, rgb) in [red, green, blue, yellow].enumerated() {
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: rgb + [1])!)
            context.fill(CGRect(x: index % 2 * 60, y: index < 2 ? 40 : 0, width: 60, height: 40))
        }
        let image = try unwrap(context.makeImage(), "Cannot render PNG fixture")
        let buffer = NSMutableData()
        let destination = try unwrap(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil), "Cannot encode PNG fixture")
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "Cannot finish PNG fixture")
        let data = buffer as Data
        try data.write(to: url)
        // Verify the source independently before asking the editor to transform it.
        try quadrants(decode(url, type: .png, width: 120, height: 80), [red, green, blue, yellow])
        return data
    }

    private static func export(_ model: EditorModel, beside source: URL, suffix: String) throws -> URL {
        let image = model.render()
        let cg = try unwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil), "Editor render has no pixels")
        let data = try unwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]), "Cannot encode rendered PNG")
        return try FileConversion.save(data, beside: source, suffix: suffix, extension: "png")
    }

    private static func contents(_ folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: file-tools-tests <scratch directory>\n", stderr)
            exit(2)
        }
        let suite = try Suite(scratch: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        print("Fixtures and outputs: \(suite.root.path)")

        await suite.run("single Korean PDF preserves source and existing same-stem JPGs") { folder in
            let source = folder.appendingPathComponent("한글 문서.pdf")
            try pdf([Page()], at: source)
            let original = try Data(contentsOf: source)
            let existing = folder.appendingPathComponent("한글 문서.jpg")
            let numbered = folder.appendingPathComponent("한글 문서 (2).jpg")
            let sentinel = Data("Existing image bytes must survive".utf8)
            try sentinel.write(to: existing)
            try sentinel.write(to: numbered)
            for number in [3, 4] {
                let result = FileConversion.convertPDF(source)
                let expected = folder.appendingPathComponent("한글 문서 (\(number)).jpg")
                try expect(result.files == [expected] && result.failure == nil && !result.cancelled,
                           "Single-page conversion must select the next collision-free adjacent JPG: \(result)")
                try quadrants(decode(expected, type: .jpeg, width: 160, height: 120), [red, green, blue, yellow])
            }
            try expect(Data(contentsOf: source) == original, "PDF source bytes changed")
            try expect(Data(contentsOf: existing) == sentinel && Data(contentsOf: numbered) == sentinel, "Existing JPG bytes changed")
        }

        await suite.run("every PDF page becomes a correctly ordered JPG with a white blank page") { folder in
            let source = folder.appendingPathComponent("pages.pdf")
            try pdf([Page(), Page(width: 100, height: 40), Page(width: 30, height: 50, blank: true)], at: source)
            let original = try Data(contentsOf: source)
            let result = FileConversion.convertPDF(source)
            let expected = (1...3).map { folder.appendingPathComponent("pages - \($0).jpg") }
            try expect(result.files == expected && result.failure == nil && !result.cancelled, "Expected three successful ordered outputs: \(result)")
            try quadrants(decode(expected[0], type: .jpeg, width: 160, height: 120), [red, green, blue, yellow])
            try quadrants(decode(expected[1], type: .jpeg, width: 200, height: 80), [red, green, blue, yellow])
            try quadrants(decode(expected[2], type: .jpeg, width: 60, height: 100), [white, white, white, white])
            try expect(Data(contentsOf: source) == original, "Multi-page PDF source bytes changed")
        }

        for (rotation, colors) in [(90, [blue, red, yellow, green]), (180, [yellow, blue, green, red]), (270, [green, yellow, red, blue])] {
            await suite.run("PDF rotation \(rotation) preserves dimensions and quadrant orientation") { folder in
                let source = folder.appendingPathComponent("rotated.pdf")
                try pdf([Page(rotation: rotation)], at: source)
                let original = try Data(contentsOf: source)
                let result = FileConversion.convertPDF(source)
                try expect(result.files.count == 1 && result.failure == nil && !result.cancelled, "Rotated PDF conversion failed: \(result)")
                let sideways = rotation != 180
                try quadrants(decode(result.files[0], type: .jpeg, width: sideways ? 120 : 160, height: sideways ? 160 : 120), colors)
                try expect(Data(contentsOf: source) == original, "Rotated source bytes changed")
            }
        }

        await suite.run("oversized second page retains the completed first page and stops before the third") { folder in
            let source = folder.appendingPathComponent("partial.pdf")
            try pdf([Page(), Page(width: 4000, height: 4000), Page()], at: source)
            let original = try Data(contentsOf: source)
            let result = FileConversion.convertPDF(source)
            let first = folder.appendingPathComponent("partial - 1.jpg")
            try expect(result.files == [first] && result.failure?.isEmpty == false && !result.cancelled,
                       "Expected a page failure with exactly the completed page retained: \(result)")
            try quadrants(decode(first, type: .jpeg, width: 160, height: 120), [red, green, blue, yellow])
            try expect(contents(folder) == ["partial.pdf", "partial - 1.jpg"], "Failure must not create later or incomplete output files")
            try expect(Data(contentsOf: source) == original, "Partial conversion modified the source")
        }

        await suite.run("oversized first page fails without creating an output") { folder in
            let source = folder.appendingPathComponent("large.pdf")
            try pdf([Page(width: 4000, height: 4000), Page()], at: source)
            let original = try Data(contentsOf: source)
            let result = FileConversion.convertPDF(source)
            try expect(result.files.isEmpty && result.failure?.isEmpty == false && !result.cancelled, "Oversized first page must fail: \(result)")
            try expect(contents(folder) == ["large.pdf"], "Oversized page left an output")
            try expect(Data(contentsOf: source) == original, "Oversized source bytes changed")
        }

        await suite.run("damaged and empty PDFs fail without outputs or source changes") { folder in
            for (name, data) in [("damaged.pdf", Data("%PDF-1.4\nnot a document".utf8)), ("empty.pdf", Data())] {
                let source = folder.appendingPathComponent(name)
                try data.write(to: source)
                let before = try contents(folder)
                let result = FileConversion.convertPDF(source)
                try expect(result.files.isEmpty && result.failure?.isEmpty == false && !result.cancelled, "Invalid PDF must report failure: \(name)")
                try expect(contents(folder) == before && Data(contentsOf: source) == data, "Invalid PDF conversion wrote files")
            }
        }

        await suite.run("password-locked PDF is rejected without modifying it") { folder in
            let plain = folder.appendingPathComponent("plain.pdf"), locked = folder.appendingPathComponent("locked.pdf")
            try pdf([Page()], at: plain)
            let plainData = try Data(contentsOf: plain)
            let document = try unwrap(PDFDocument(url: plain), "Cannot load PDF encryption fixture")
            try expect(document.write(to: locked, withOptions: [.userPasswordOption: "fixture-user", .ownerPasswordOption: "fixture-owner"]), "Cannot write encrypted fixture")
            let encrypted = try unwrap(CGPDFDocument(locked as CFURL), "Cannot open encrypted fixture")
            try expect(encrypted.isEncrypted && !encrypted.isUnlocked, "Fixture must actually require a password")
            let original = try Data(contentsOf: locked)
            let result = FileConversion.convertPDF(locked)
            try expect(result.files.isEmpty && result.failure?.isEmpty == false && !result.cancelled, "Locked PDF must report failure")
            try expect(contents(folder) == ["plain.pdf", "locked.pdf"], "Locked PDF produced output")
            try expect(Data(contentsOf: locked) == original && Data(contentsOf: plain) == plainData, "Encryption/conversion changed a source")
        }

        await suite.run("unreadable PDF is rejected without output") { folder in
            let source = folder.appendingPathComponent("unreadable.pdf")
            try pdf([Page()], at: source)
            let original = try Data(contentsOf: source)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
            guard !FileManager.default.isReadableFile(atPath: source.path) else {
                throw Skipped(reason: "This process can read mode-000 files; permission rejection is unverified")
            }
            let result = FileConversion.convertPDF(source)
            try expect(result.files.isEmpty && result.failure?.isEmpty == false && !result.cancelled, "Unreadable PDF must report failure")
            try expect(contents(folder) == ["unreadable.pdf"], "Unreadable PDF created output")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            try expect(Data(contentsOf: source) == original, "Unreadable source bytes changed")
        }

        await suite.run("a task cancelled before conversion deterministically saves no pages") { folder in
            let source = folder.appendingPathComponent("cancelled.pdf")
            try pdf([Page(), Page()], at: source)
            let original = try Data(contentsOf: source)
            let result = await Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return FileConversion.convertPDF(source)
            }.value
            try expect(result.cancelled && result.failure == nil && result.files.isEmpty, "Pre-cancellation must be reported independently of failure: \(result)")
            try expect(contents(folder) == ["cancelled.pdf"] && Data(contentsOf: source) == original, "Cancelled conversion wrote files")
        }

        await suite.run("save creates distinct adjacent files and preserves the original even with an empty suffix") { folder in
            let source = folder.appendingPathComponent("그림.png")
            let original = try png(at: source)
            let replacement = Data("new output".utf8)
            let first = try FileConversion.save(replacement, beside: source, suffix: "", extension: "png")
            let second = try FileConversion.save(replacement, beside: source, suffix: "", extension: "png")
            try expect(first == folder.appendingPathComponent("그림 (2).png") && second == folder.appendingPathComponent("그림 (3).png"), "Same-extension saves must not overwrite the source or previous result")
            try expect(Data(contentsOf: source) == original, "save overwrote source bytes")
            try expect(Data(contentsOf: first) == replacement && Data(contentsOf: second) == replacement, "save changed payload bytes")
            let absent = folder.appendingPathComponent("absent/source.png")
            var failed = false
            do {
                _ = try FileConversion.save(replacement, beside: absent, suffix: " - crop", extension: "png")
            } catch { failed = true }
            try expect(failed, "Saving beside a missing parent must propagate a filesystem error")
            try expect(!FileManager.default.fileExists(atPath: absent.deletingLastPathComponent().path), "Failed save created an unexpected directory")
        }

        await suite.run("file actions reject directories, missing files, unsupported types and remote URLs") { folder in
            let document = folder.appendingPathComponent("document.pdf"), image = folder.appendingPathComponent("image.png")
            let text = folder.appendingPathComponent("text.txt"), directory = folder.appendingPathComponent("directory.pdf", isDirectory: true)
            try pdf([Page()], at: document)
            _ = try png(at: image)
            try Data("text".utf8).write(to: text)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try expect(FileTools.actions(for: document) == [.jpg], "PDF must offer only JPG conversion")
            try expect(FileTools.actions(for: image) == [.crop, .background], "Images must offer crop and background")
            for rejected in [text, directory, folder.appendingPathComponent("missing.pdf"), URL(string: "https://example.invalid/file.pdf")!] {
                try expect(FileTools.actions(for: rejected).isEmpty, "Unsupported input offered actions: \(rejected)")
                let result = FileConversion.convertPDF(rejected)
                try expect(result.files.isEmpty && result.failure != nil && !result.cancelled, "Unsupported conversion must report failure")
            }
            let imageResult = FileConversion.convertPDF(image)
            try expect(imageResult.files.isEmpty && imageResult.failure != nil, "Image cannot enter PDF conversion")
        }

        await suite.run("a private pasteboard accepts exactly one supported file, never multiple files or plain text") { folder in
            let document = folder.appendingPathComponent("one.pdf"), image = folder.appendingPathComponent("two.png")
            let text = folder.appendingPathComponent("text.txt")
            try pdf([Page()], at: document)
            _ = try png(at: image)
            try Data("text".utf8).write(to: text)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            try expect(FileTools.file(from: pasteboard) == nil, "Empty pasteboard must be rejected")
            for accepted in [document, image] {
                pasteboard.clearContents()
                try expect(pasteboard.writeObjects([accepted as NSURL]), "Cannot write private pasteboard fixture")
                try expect(FileTools.file(from: pasteboard) == accepted, "Single supported URL must be accepted")
            }
            for rejected in [[document, image], [document, text], [text], [folder]] {
                pasteboard.clearContents()
                try expect(pasteboard.writeObjects(rejected.map { $0 as NSURL }), "Cannot write rejected pasteboard fixture")
                try expect(FileTools.file(from: pasteboard) == nil, "Unsupported or multi-file pasteboard must be rejected")
            }
            pasteboard.clearContents()
            pasteboard.setString(document.path, forType: .string)
            try expect(FileTools.file(from: pasteboard) == nil, "Plain text that looks like a path is not a file drag")
        }

        await suite.run("ring hit testing excludes its hub and exterior and orders sectors from the top") { _ in
            let c = FileTools.size / 2
            for count in [1, 2, 3, 4] {
                for radius in [CGFloat(0), 47.999, 144.001, 300] {
                    try expect(FileTools.index(at: CGPoint(x: c, y: c + radius), count: count) == nil, "Radius \(radius) must reject a drop for \(count) actions")
                }
                for radius in [CGFloat(48), 96, 144] {
                    try expect(FileTools.index(at: CGPoint(x: c, y: c + radius), count: count) == 0, "Top of accepted annulus must be slot zero")
                }
                for index in 0..<count {
                    let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
                    let point = CGPoint(x: c + sin(angle) * 96, y: c + cos(angle) * 96)
                    try expect(FileTools.index(at: point, count: count) == index, "Sector \(index) of \(count) must map clockwise from the top")
                }
            }
            for count in [0, -1] {
                try expect(FileTools.index(at: CGPoint(x: c, y: c + 96), count: count) == nil, "No actions means no target")
            }
            try expect(FileTools.index(at: CGPoint(x: c + 96, y: c + 0.01), count: 2) == 0, "Upper side of two-sector boundary must select top")
            try expect(FileTools.index(at: CGPoint(x: c + 96, y: c - 0.01), count: 2) == 1, "Lower side of two-sector boundary must select bottom")
        }

        await suite.run("entering background editing commits the crop preview for every ratio") { folder in
            let source = folder.appendingPathComponent("crop-background.png")
            _ = try png(at: source)
            let image = try unwrap(NSImage(contentsOf: source), "Cannot load image")
            let model = EditorModel(image: image, fileURL: source)
            model.tool = .crop
            model.dragChanged(from: CGPoint(x: 10, y: 8), to: CGPoint(x: 90, y: 68))
            model.dragEnded(at: CGPoint(x: 90, y: 68), start: CGPoint(x: 10, y: 8))
            let crop = CGRect(x: 10, y: 8, width: 80, height: 60)
            try expect(model.crop == crop, "Crop gesture must commit the selected rectangle")
            for aspect in Backdrop.Aspect.allCases {
                model.tool = .crop
                var background = Backdrop()
                background.padding = 6
                background.aspect = aspect
                model.setBackdrop(background)
                try expect(model.tool == .select && model.crop == crop, "Background editing must leave crop mode without losing the crop")
                let previewSize = background.canvasSize(for: model.tool == .crop ? model.size : model.crop!.size)
                let output = model.render()
                try expect(abs(output.size.width - previewSize.width) <= 1 && abs(output.size.height - previewSize.height) <= 1,
                           "Background preview and export must use the same cropped canvas: \(aspect)")
            }
            model.tool = .crop
            model.adjustBackdrop { $0.padding = 8 }
            try expect(model.tool == .select && model.crop == crop, "Backdrop slider must keep the committed crop preview")
        }

        await suite.run("all backdrop ratios expand only the canvas in portrait and landscape") { _ in
            for size in [CGSize(width: 80, height: 60), CGSize(width: 20, height: 80), CGSize(width: 200, height: 20)] {
                for aspect in Backdrop.Aspect.allCases {
                    var backdrop = Backdrop()
                    backdrop.padding = 6
                    backdrop.aspect = aspect
                    let actual = backdrop.canvasSize(for: size)
                    let minimum = CGSize(width: size.width + 12, height: size.height + 12)
                    let ratio: CGFloat? = switch aspect {
                    case .auto: nil
                    case .square: 1
                    case .wide: 16.0 / 9.0
                    case .standard: 4.0 / 3.0
                    }
                    if let ratio {
                        try expect(abs(actual.width / actual.height - ratio) < 0.000001, "Wrong \(aspect) canvas ratio: \(actual)")
                        try expect(abs(actual.width - minimum.width) < 0.000001 || abs(actual.height - minimum.height) < 0.000001, "Ratio must expand only the necessary axis")
                    } else {
                        try expect(actual == minimum, "Auto must use only image dimensions plus padding")
                    }
                    try expect(actual.width >= minimum.width && actual.height >= minimum.height, "Backdrop must not shrink or crop the picture")
                }
            }
        }

        await suite.run("rounded backdrop clips only picture corners and retains its centered content") { folder in
            let source = folder.appendingPathComponent("rounded.png")
            let original = try png(at: source)
            let image = try unwrap(NSImage(contentsOf: source), "Cannot load rounded-corner fixture")
            image.size = CGSize(width: 120, height: 80)
            let model = EditorModel(image: image, fileURL: source)
            model.crop = CGRect(x: 10, y: 8, width: 80, height: 60)
            var backdrop = Backdrop()
            backdrop.padding = 6
            backdrop.radius = 12
            backdrop.shadow = false
            backdrop.style = 6
            model.backdrop = backdrop
            let output = try export(model, beside: source, suffix: " - corners")
            let bitmap = try decode(output, type: .png, width: 92, height: 72)
            for point in [(7, 7), (84, 7), (7, 64), (84, 64)] {
                try color(bitmap, x: point.0, y: point.1, equals: white)
            }
            try color(bitmap, x: 26, y: 26, equals: red)
            try color(bitmap, x: 76, y: 26, equals: green)
            try color(bitmap, x: 26, y: 56, equals: blue)
            try color(bitmap, x: 76, y: 56, equals: yellow)
            try expect(Data(contentsOf: source) == original, "Rounded backdrop modified source bytes")
        }

        for scale in [CGFloat(1), 2] {
            await suite.run("crop and every backdrop ratio export real unchanged-shape pixels at scale \(Int(scale))") { folder in
                let source = folder.appendingPathComponent("원본.png")
                let original = try png(at: source)
                let image = try unwrap(NSImage(contentsOf: source), "Cannot load PNG into editor")
                image.size = CGSize(width: 120 / scale, height: 80 / scale)
                let model = EditorModel(image: image, fileURL: source)
                try expect(model.pixelScale == scale, "Fixture must exercise the intended pixel scale")
                model.crop = CGRect(x: 10 / scale, y: 8 / scale, width: 80 / scale, height: 60 / scale)
                let cropped = try export(model, beside: source, suffix: " - crop")
                let croppedPixels = try decode(cropped, type: .png, width: 80, height: 60)
                try color(croppedPixels, x: 10, y: 10, equals: red)
                try color(croppedPixels, x: 70, y: 10, equals: green)
                try color(croppedPixels, x: 10, y: 50, equals: blue)
                try color(croppedPixels, x: 70, y: 50, equals: yellow)
                // These offsets distinguish the requested crop from a resized full source.
                try color(croppedPixels, x: 45, y: 25, equals: red)
                try color(croppedPixels, x: 55, y: 25, equals: green)
                try color(croppedPixels, x: 45, y: 35, equals: blue)
                for (aspect, width, height) in [(Backdrop.Aspect.auto, 92, 72), (.square, 92, 92), (.wide, 128, 72), (.standard, 96, 72)] {
                    var backdrop = Backdrop()
                    backdrop.padding = 6 / scale
                    backdrop.radius = 0
                    backdrop.shadow = false
                    backdrop.style = 6
                    backdrop.aspect = aspect
                    model.backdrop = backdrop
                    let output = try export(model, beside: source, suffix: " - \(aspect.rawValue)")
                    let bitmap = try decode(output, type: .png, width: width, height: height)
                    let left = (width - 80) / 2, top = (height - 60) / 2
                    try color(bitmap, x: 0, y: 0, equals: white)
                    try color(bitmap, x: left - 2, y: height / 2, equals: white)
                    try color(bitmap, x: width / 2, y: top - 2, equals: white)
                    // Match the entire interior to the independently generated crop, including its asymmetric split.
                    for y in 1..<59 where abs(y - 32) > 1 {
                        for x in 1..<79 where abs(x - 50) > 1 {
                            let expected = y < 32 ? (x < 50 ? red : green) : (x < 50 ? blue : yellow)
                            try color(bitmap, x: left + x, y: top + y, equals: expected, tolerance: 0.04)
                        }
                    }
                    try color(bitmap, x: left + 81, y: height / 2, equals: white)
                    try color(bitmap, x: width / 2, y: top + 61, equals: white)
                }
                try expect(model.image === image && model.image.size == CGSize(width: 120 / scale, height: 80 / scale), "Export mutated the source image")
                try expect(Data(contentsOf: source) == original, "Crop/backdrop export modified original PNG bytes")
                model.crop = nil
                model.backdrop = nil
                let restored = try export(model, beside: source, suffix: " - restored")
                try quadrants(decode(restored, type: .png, width: 120, height: 80), [red, green, blue, yellow])
            }
        }

        print("UNVERIFIED cancellation between completed pages: convertPDF exposes no deterministic per-page cancellation seam")
        print("file-tools: \(suite.passed) passed, \(suite.failed) failed, \(suite.skipped) skipped")
        exit(suite.failed == 0 ? 0 : 1)
    }
}
