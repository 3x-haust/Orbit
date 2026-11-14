import AppKit
import AVFoundation
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Orbit

/// File ring regressions against the real Debug module. Every fixture is made here, in a fresh folder;
/// outputs are decoded again with ImageIO, PDFKit, AppKit's text system or AVFoundation, never trusted by name.
private struct Failure: Error, CustomStringConvertible { let description: String }

private func expect(_ condition: Bool, _ message: @autoclosure () throws -> String) throws {
    if !condition { throw Failure(description: (try? message()) ?? "check failed") }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw Failure(description: message) }
    return value
}

@MainActor
private final class Collector: @unchecked Sendable {
    var outputs: [URL] = []
}

/// Stands in for AppKit's dragging session at a point in the ring panel.
private final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let point: CGPoint
    let mask: NSDragOperation
    init(_ pasteboard: NSPasteboard, at point: CGPoint, mask: NSDragOperation = [.copy, .move, .generic]) {
        self.pasteboard = pasteboard
        self.point = point
        self.mask = mask
    }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { point }
    var draggedImageLocation: NSPoint { point }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 1 } set {} }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@main @MainActor
struct FileToolsTests {
    static var root: URL!
    static var passed = 0, failed = 0

    static func main() async throws {
        _ = NSApplication.shared
        let scratch = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
        root = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        await test("menus offer what each kind can become, never its own format", menus)
        await test("ring geometry maps the hub, slots and tabs", geometry)
        await test("dropping on a slot runs it; Shift flips modes; only copies are accepted", dropPath)
        await test("PNG with transparency → JPG is white where it was clear", pngToJPG)
        await test("rotated JPEG converts upright", orientation)
        await test("pictures → one PDF, a page each at their own size", imagesToPDF)
        await test("PDF → JPG: one page beside it, several in a folder in order", pdfToImages)
        await test("PDF → TXT, DOCX and RTF carry the text", pdfToText)
        await test("PDF without text says so instead of saving an empty file", pdfNoText)
        await test("PDF split, merge and compress keep every page", pdfTools)
        await test("documents convert to Word, text, HTML and paginated PDF", documents)
        await test("compress makes a smaller copy or reports there was nothing to gain", compress)
        await test("metadata removal drops GPS and camera data, keeps pixels and orientation", stripMetadata)
        await test("names never collide and originals are untouched", collisions)
        await test("cancelling stops before writing anything more", cancellation)
        await test("background canvas follows ratio and padding; corners show the backdrop", background)
        await test("redaction covers only the chosen boxes", redact)
        await test("crop keeps the box measured from the top left, in the original's format", crop)
        await test("video → MP4, GIF; mute removes sound; silent video has no M4A", video)
        await test("audio → M4A, WAV, AIFF keep the length", audio)

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    static func test(_ name: String, _ body: @MainActor (URL) async throws -> Void) async {
        if let filter = ProcessInfo.processInfo.environment["ORBIT_FILE_TEST_FILTER"],
           name.range(of: filter, options: .regularExpression) == nil { return }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await body(folder)
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
        fflush(stdout)
    }

    /// Runs one ring action the way the app does and returns what it saved.
    static func run(_ action: FileAction, _ files: [URL]) async throws -> (outputs: [URL], note: String?) {
        let collector = Collector()
        let note = try await FileEngine.run(action, files: files, progress: { _ in }, saved: { url in
            DispatchQueue.main.async { collector.outputs.append(url) }
        })
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        return (collector.outputs, note?.text)
    }

    // MARK: Fixtures

    static func bitmap(_ w: Int, _ h: Int, alpha: Bool = false, noise: Bool = false, draw: ((CGContext) -> Void)? = nil) throws -> CGImage {
        let context = try unwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue), "context")
        if !alpha {
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        if noise, let data = context.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * h)
            var seed: UInt32 = 7
            for i in 0..<(context.bytesPerRow * h) where i % 4 != 3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        draw?(context)
        return try unwrap(context.makeImage(), "image")
    }

    static func write(_ image: CGImage, _ url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        let destination = try unwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil), "destination")
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "fixture \(url.lastPathComponent)")
    }

    static func decode(_ url: URL) throws -> (image: CGImage, type: String, props: [CFString: Any]) {
        let source = try unwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "decode \(url.lastPathComponent)")
        let image = try unwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "pixels \(url.lastPathComponent)")
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, CGImageSourceGetType(source) as String? ?? "", props)
    }

    /// RGBA 0…255 at (x, y) with y from the top.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try unwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), "read context")
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try unwrap(context.data, "read data").bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        let i = (y * image.width + x) * 4 // bitmap rows run top to bottom
        return (0..<4).map { Int(bytes[i + $0]) }
    }

    static func close(_ a: [Int], _ b: [Int], _ tolerance: Int = 12) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    /// A PDF with real, extractable text on each page.
    static func textPDF(_ pages: [String], _ url: URL, size: CGSize = CGSize(width: 300, height: 200)) throws {
        var box = CGRect(origin: .zero, size: size)
        let context = try unwrap(CGContext(url as CFURL, mediaBox: &box, nil), "pdf context")
        for text in pages {
            context.beginPage(mediaBox: &box)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
                context.textPosition = CGPoint(x: 20, y: size.height / 2)
                CTLineDraw(line, context)
            } else {
                context.setFillColor(CGColor(gray: 0.3, alpha: 1))
                context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
            }
            context.endPage()
        }
        context.closePDF()
    }

    static func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    // MARK: Tests

    static func menus(_ dir: URL) throws {
        let png = dir.appendingPathComponent("a.png"), png2 = dir.appendingPathComponent("b.png")
        try write(try bitmap(8, 8), png, type: .png)
        try write(try bitmap(8, 8), png2, type: .png)
        let pdf = dir.appendingPathComponent("c.pdf")
        try textPDF(["x"], pdf)
        let rtf = dir.appendingPathComponent("d.rtf")
        try data(of: "Hi", as: .rtf).write(to: rtf)

        let convert = FileMenu.menu(for: [png], mode: .convert)
        try expect(!convert.outer.contains(.convert(.png)), "PNG must not offer PNG")
        try expect(convert.outer.contains(.convert(.jpg)) && convert.hub == .convert(.pdf), "PNG: JPG around, PDF in the middle")
        let tools = FileMenu.menu(for: [png], mode: .tools)
        try expect(tools.outer == [.crop, .background, .compress, .stripMetadata, .redact] && tools.hub == .annotate, "image tools \(tools)")
        let many = FileMenu.menu(for: [png, png2], mode: .tools)
        try expect(!many.outer.contains(.crop) && many.hub == nil, "windows open for one picture only")
        try expect(FileMenu.menu(for: [pdf], mode: .convert).hub == .convert(.txt), "PDF hub is TXT")
        try expect(!FileMenu.menu(for: [pdf], mode: .tools).outer.contains(.merge), "merge needs two PDFs")
        try expect(FileMenu.menu(for: [pdf, pdf], mode: .tools).outer.contains(.merge), "two PDFs can merge")
        let doc = FileMenu.menu(for: [rtf], mode: .convert)
        try expect(!doc.outer.contains(.convert(.rtf)) && doc.hub == .convert(.pdf), "RTF menu \(doc)")
        try expect(FileMenu.menu(for: [png, pdf], mode: .convert).isEmpty, "mixed kinds offer nothing")
        try expect(FileMenu.menu(for: [dir], mode: .convert).isEmpty, "folders offer nothing")
    }

    static func data(of text: String, as format: FileFormat) throws -> Data {
        try FileEngine.data(of: NSAttributedString(string: text), as: format)
    }

    static func geometry(_ dir: URL) throws {
        let menu = FileMenu(outer: [.convert(.jpg), .convert(.png), .convert(.heic), .convert(.tiff)], hub: .convert(.pdf))
        let c = FileTools.ringSize / 2
        try expect(FileTools.slot(at: CGPoint(x: c, y: c), menu: menu) == .hub, "center is the hub")
        try expect(FileTools.slot(at: CGPoint(x: c, y: c + 100), menu: menu) == .outer(0), "up is slot 0")
        try expect(FileTools.slot(at: CGPoint(x: c + 100, y: c), menu: menu) == .outer(1), "right is slot 1")
        try expect(FileTools.slot(at: CGPoint(x: c, y: c - 100), menu: menu) == .outer(2), "down is slot 2")
        try expect(FileTools.slot(at: CGPoint(x: c, y: c + 48), menu: menu) == nil, "gap between hub and slots")
        try expect(FileTools.slot(at: CGPoint(x: 2, y: 2), menu: menu) == nil, "corner is outside")
        try expect(FileTools.slot(at: CGPoint(x: c, y: c), menu: FileMenu(outer: menu.outer)) == nil, "no hub action, no hub slot")
        try expect(FileTools.tab(at: CGPoint(x: 40, y: FileTools.ringSize + 10)) == .convert, "left tab")
        try expect(FileTools.tab(at: CGPoint(x: FileTools.ringSize - 40, y: FileTools.ringSize + 10)) == .tools, "right tab")
        try expect(FileTools.tab(at: CGPoint(x: c, y: c)) == nil, "ring is not a tab")
    }

    static func dropPath(_ dir: URL) async throws {
        let png = dir.appendingPathComponent("drop.png")
        try write(try bitmap(12, 12), png, type: .png)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.writeObjects([png as NSURL])
        let tools = FileTools.shared
        tools.show([png], dragging: true)
        defer { tools.closeRing() }
        let window = try unwrap(NSApp.windows.first { $0.isVisible && $0.frame.size == FileTools.panelSize }, "ring panel")
        let drop = try unwrap(window.contentView as? FileDropView, "drop view")
        let c = FileTools.ringSize / 2
        try expect(tools.mode == .convert, "opens on Convert")

        // A move-only drag (⌘ in Finder) is refused so Finder can never delete the original.
        let move = FakeDrag(pasteboard, at: CGPoint(x: c, y: c + 100), mask: .move)
        try expect(drop.draggingUpdated(move) == [], "move refused")

        // Hovering the Tools tab switches; Shift does the same.
        _ = drop.draggingUpdated(FakeDrag(pasteboard, at: CGPoint(x: FileTools.ringSize - 40, y: FileTools.ringSize + 12)))
        try expect(tools.mode == .tools, "tab hover → Tools")
        tools.toggleMode()
        try expect(tools.mode == .convert, "Shift → Convert")

        let top = FakeDrag(pasteboard, at: CGPoint(x: c, y: c + 100))
        try expect(drop.draggingUpdated(top) == .copy && tools.selection == .outer(0), "top slot targeted")
        try expect(tools.action(for: .outer(0)) == .convert(.jpg), "top is JPG")
        try expect(drop.performDragOperation(top), "drop accepted")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("drop.jpg").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(try decode(dir.appendingPathComponent("drop.jpg")).type == UTType.jpeg.identifier, "drop made a JPEG")
        let job = try unwrap(tools.jobs.last, "a progress card")
        while job.state == .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try expect(job.state == .done && job.outputs.map(\.lastPathComponent) == ["drop.jpg"], "card shows the result: \(job.state) \(job.outputs)")
        tools.dismiss(job)
    }

    static func pngToJPG(_ dir: URL) async throws {
        let png = dir.appendingPathComponent("clear.png")
        try write(try bitmap(40, 20, alpha: true) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }, png, type: .png)
        let (outputs, _) = try await run(.convert(.jpg), [png])
        try expect(outputs.map(\.lastPathComponent) == ["clear.jpg"], "outputs \(outputs)")
        let out = try decode(outputs[0])
        try expect(out.type == UTType.jpeg.identifier, "really a JPEG: \(out.type)")
        try expect(close(try pixel(out.image, 30, 10), [255, 255, 255, 255]), "clear became white: \(try pixel(out.image, 30, 10))")
        try expect(close(try pixel(out.image, 5, 10), [255, 0, 0, 255], 30), "red stays red")
    }

    static func orientation(_ dir: URL) async throws {
        let jpg = dir.appendingPathComponent("turned.jpg")
        try write(try bitmap(60, 20), jpg, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let (outputs, _) = try await run(.convert(.png), [jpg])
        let out = try decode(try unwrap(outputs.first, "no output"))
        try expect(out.image.width == 20 && out.image.height == 60, "upright size \(out.image.width)x\(out.image.height)")
        try expect((out.props[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "no leftover orientation tag")
    }

    static func imagesToPDF(_ dir: URL) async throws {
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try write(try bitmap(144, 72), a, type: .png, properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        try write(try bitmap(50, 100), b, type: .png)
        let (outputs, _) = try await run(.convert(.pdf), [a, b])
        try expect(outputs.count == 1, "one PDF")
        let pdf = try unwrap(PDFDocument(url: outputs[0]), "PDF decodes")
        try expect(pdf.pageCount == 2, "two pages")
        let first = pdf.page(at: 0)!.bounds(for: .mediaBox).size, second = pdf.page(at: 1)!.bounds(for: .mediaBox).size
        try expect(first == CGSize(width: 72, height: 36) && second == CGSize(width: 50, height: 100), "page sizes \(first) \(second)")
    }

    static func pdfToImages(_ dir: URL) async throws {
        let one = dir.appendingPathComponent("one.pdf"), three = dir.appendingPathComponent("three.pdf")
        try textPDF(["only"], one)
        try textPDF(["", "", ""], three, size: CGSize(width: 100, height: 50))
        let single = try await run(.convert(.jpg), [one]).outputs
        try expect(single.map(\.lastPathComponent) == ["one.jpg"], "single \(single)")
        let pages = try await run(.convert(.png), [three]).outputs
        try expect(pages.map(\.lastPathComponent) == ["Page 1.png", "Page 2.png", "Page 3.png"], "pages \(pages.map(\.lastPathComponent))")
        try expect(pages.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "three" }, "in a folder named after the PDF")
        let image = try decode(pages[0])
        try expect(image.image.width == 200 && image.image.height == 100, "2× page \(image.image.width)x\(image.image.height)")
        // The fixture's square sits 20 pt from the bottom left: at 2× it fills x ≥ 40 and the top 60 rows.
        try expect(close(try pixel(image.image, 20, 90), [255, 255, 255, 255]), "white paper")
        try expect(close(try pixel(image.image, 60, 30), [77, 77, 77, 255], 20), "drawn content \(try pixel(image.image, 60, 30))")
    }

    static func pdfToText(_ dir: URL) async throws {
        let pdf = dir.appendingPathComponent("words.pdf")
        try textPDF(["Hello Orbit", "Second page"], pdf)
        let txt = try await run(.convert(.txt), [pdf]).outputs
        let text = try String(contentsOf: txt[0], encoding: .utf8)
        try expect(text.contains("Hello Orbit") && text.contains("Second page"), "txt \(text)")
        for format in [FileFormat.docx, .rtf] {
            let out = try await run(.convert(format), [pdf]).outputs
            try expect(out.first?.pathExtension == format.ext, "\(format) extension")
            let read = try NSAttributedString(url: out[0], options: [:], documentAttributes: nil).string
            try expect(read.contains("Hello Orbit") && read.contains("Second page"), "\(format) text \(read)")
        }
    }

    static func pdfNoText(_ dir: URL) async throws {
        let pdf = dir.appendingPathComponent("scan.pdf")
        try textPDF([""], pdf)
        do {
            _ = try await run(.convert(.txt), [pdf])
            throw Failure(description: "an empty text file was made")
        } catch let error as FileToolError {
            try expect(error == .noText, "error \(error)")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        try expect(left == ["scan.pdf"], "nothing written: \(left)")
    }

    static func pdfTools(_ dir: URL) async throws {
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        try textPDF(["A1", "A2"], a)
        try textPDF(["B1"], b)
        let split = try await run(.split, [a]).outputs
        try expect(split.count == 2 && split.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 }, "split \(split)")
        try expect(PDFDocument(url: split[1])?.string?.contains("A2") == true, "page order")
        let merged = try await run(.merge, [b, a]).outputs
        let doc = try unwrap(PDFDocument(url: merged[0]), "merged")
        try expect(doc.pageCount == 3 && doc.page(at: 0)?.string?.contains("B1") == true, "merged in drag order")
        try expect(merged[0].lastPathComponent == "b Merged.pdf", "name \(merged[0].lastPathComponent)")
        // A text-only PDF can't shrink: the run reports that and keeps no copy.
        let (compressed, note) = try await run(.compress, [b])
        try expect(compressed.isEmpty || (PDFDocument(url: compressed[0])?.pageCount == 1), "compressed keeps pages")
        try expect(!compressed.isEmpty || note != nil, "an empty result explains itself")
    }

    static func documents(_ dir: URL) async throws {
        let rtf = dir.appendingPathComponent("letter.rtf")
        let long = (1...400).map { "Line \($0) of the letter." }.joined(separator: "\n")
        try FileEngine.data(of: NSAttributedString(string: "Dear Orbit\n" + long, attributes: [.font: NSFont.systemFont(ofSize: 13)]), as: .rtf).write(to: rtf)
        for format in [FileFormat.docx, .txt, .html, .odt] {
            let out = try await run(.convert(format), [rtf]).outputs
            try expect(out.first?.lastPathComponent == "letter.\(format.ext)", "\(format) name")
            let read = try NSAttributedString(url: out[0], options: [:], documentAttributes: nil).string
            try expect(read.contains("Dear Orbit") && read.contains("Line 400"), "\(format) keeps the text")
        }
        let pdf = try await run(.convert(.pdf), [rtf]).outputs
        let doc = try unwrap(PDFDocument(url: pdf[0]), "PDF decodes")
        try expect(doc.pageCount > 3, "paginated: \(doc.pageCount) pages")
        try expect(doc.page(at: 0)?.string?.contains("Dear Orbit") == true, "first page starts the letter")
        try expect(doc.string?.contains("Line 400") == true, "last line made it")
    }

    static func compress(_ dir: URL) async throws {
        let big = dir.appendingPathComponent("noise.png")
        try write(try bitmap(600, 400, noise: true), big, type: .png)
        let (outputs, note) = try await run(.compress, [big])
        try expect(outputs.map(\.lastPathComponent) == ["noise Compressed.jpg"], "outputs \(outputs)")
        try expect(FileEngine.size(of: outputs[0]) < FileEngine.size(of: big), "smaller")
        try expect(note?.contains("→") == true, "reports sizes: \(note ?? "nil")")

        let tiny = dir.appendingPathComponent("tiny.jpg")
        try write(try bitmap(16, 16), tiny, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.1])
        let (none, why) = try await run(.compress, [tiny])
        try expect(none.isEmpty && why != nil, "nothing gained → no file, a note")
        try expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("tiny Compressed.jpg").path), "bigger copy removed")
    }

    static func stripMetadata(_ dir: URL) async throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 127.0, kCGImagePropertyGPSLongitudeRef: "E"]
        // ImageIO clears metadata differently per format; each one must come out clean.
        for (type, ext) in [(UTType.jpeg, "jpg"), (.png, "png"), (.tiff, "tiff"), (.heic, "heic")] {
            let file = dir.appendingPathComponent("trip.\(ext)")
            try write(try bitmap(30, 10), file, type: type, properties: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: gps,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Test Camera"],
            ])
            try expect(!FileEngine.isClean(try data(file)), "\(ext) fixture carries metadata")
            let out = try await run(.stripMetadata, [file]).outputs
            try expect(out.map(\.lastPathComponent) == ["trip No Metadata.\(ext)"], "\(ext) name \(out)")
            let after = try decode(out[0])
            try expect(after.props[kCGImagePropertyGPSDictionary] == nil, "\(ext): GPS gone")
            let exif = after.props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            try expect(exif?[kCGImagePropertyExifLensModel] == nil, "\(ext): lens gone")
            let tiff = after.props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            try expect(tiff?[kCGImagePropertyTIFFModel] == nil, "\(ext): camera gone")
            try expect(after.props[kCGImagePropertyOrientation] as? Int == 6, "\(ext): orientation kept")
            try expect(after.image.width == 30 && after.image.height == 10, "\(ext): same pixels")
        }
        // An animation keeps every frame.
        let gif = dir.appendingPathComponent("loop.gif")
        let destination = try unwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil), "gif")
        for _ in 0..<3 {
            CGImageDestinationAddImage(destination, try bitmap(8, 8), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        try expect(CGImageDestinationFinalize(destination), "gif fixture")
        let cleaned = try await run(.stripMetadata, [gif]).outputs
        let frames = CGImageSourceGetCount(try unwrap(CGImageSourceCreateWithURL(cleaned[0] as CFURL, nil), "gif out"))
        try expect(frames == 3, "all frames kept: \(frames)")
    }

    static func collisions(_ dir: URL) async throws {
        let png = dir.appendingPathComponent("photo.png")
        try write(try bitmap(10, 10), png, type: .png)
        let original = try data(png)
        try Data("taken".utf8).write(to: dir.appendingPathComponent("photo.jpg"))
        let out = try await run(.convert(.jpg), [png]).outputs
        try expect(out.map(\.lastPathComponent) == ["photo 2.jpg"], "free name \(out)")
        try expect(try String(contentsOf: dir.appendingPathComponent("photo.jpg"), encoding: .utf8) == "taken", "existing file untouched")
        try expect(try data(png) == original, "original untouched")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("many"), withIntermediateDirectories: false)
        let pdf = dir.appendingPathComponent("many.pdf")
        try textPDF(["1", "2"], pdf)
        let pages = try await run(.convert(.jpg), [pdf]).outputs
        try expect(pages.first?.deletingLastPathComponent().lastPathComponent == "many 2", "folder name taken → next one")

        // A broken symlink holds its name too (and must not make naming spin forever).
        let link = dir.appendingPathComponent("linked.png")
        try write(try bitmap(10, 10), link, type: .png)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("linked.jpg").path, withDestinationPath: "/nonexistent/x.jpg")
        let viaLink = try await run(.convert(.jpg), [link]).outputs
        try expect(viaLink.map(\.lastPathComponent) == ["linked 2.jpg"], "skips the dangling link: \(viaLink)")

        // Two jobs racing for one name each get their own file (writers that can't write exclusively).
        let clip = dir.appendingPathComponent("race.pdf")
        try textPDF(["x"], clip)
        async let a = run(.split, [clip])
        async let b = run(.split, [clip])
        let (ra, rb) = try await (a, b)
        try expect(Set(ra.outputs + rb.outputs).count == 2, "two separate results")
    }

    static func cancellation(_ dir: URL) async throws {
        let pdf = dir.appendingPathComponent("long.pdf")
        try textPDF(Array(repeating: "", count: 30), pdf)
        let collector = Collector()
        let task = Task {
            try await FileEngine.run(.convert(.jpg), files: [pdf], progress: { _ in }, saved: { url in
                DispatchQueue.main.async { collector.outputs.append(url) }
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            throw Failure(description: "finished despite cancel")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(20))
        let folder = dir.appendingPathComponent("long")
        let written = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        try expect(written.count == collector.outputs.count && written.count < 30, "stopped early: \(written.count) written")
    }

    static func background(_ dir: URL) throws {
        let image = try bitmap(200, 100)
        var backdrop = StudioBackdrop()
        backdrop.padding = 0.1
        try expect(StudioRenderer.canvas(for: CGSize(width: 200, height: 100), backdrop: backdrop) == CGSize(width: 240, height: 140), "padding")
        backdrop.ratio = .square
        try expect(StudioRenderer.canvas(for: CGSize(width: 200, height: 100), backdrop: backdrop) == CGSize(width: 240, height: 240), "1:1 grows")
        backdrop.ratio = .story
        let story = StudioRenderer.canvas(for: CGSize(width: 200, height: 100), backdrop: backdrop)
        try expect(abs(story.width / story.height - 9.0 / 16) < 0.01, "9:16 \(story)")

        backdrop = StudioBackdrop(fill: StudioBackdrop.gradients.count + 8, padding: 0.1, corners: 0.15, shadow: 0, ratio: .auto) // solid black
        let out = try unwrap(StudioRenderer.background(image, backdrop: backdrop, image: nil), "render")
        try expect(out.width == 240 && out.height == 140, "size")
        try expect(close(try pixel(out, 2, 2), [0, 0, 0, 255]), "backdrop at the edge")
        try expect(close(try pixel(out, 21, 21), [0, 0, 0, 255]), "rounded corner shows the backdrop")
        try expect(close(try pixel(out, 120, 70), [51, 128, 230, 255], 16), "picture in the middle \(try pixel(out, 120, 70))")
    }

    static func redact(_ dir: URL) throws {
        let image = try bitmap(100, 100, noise: true)
        let black = try unwrap(StudioRenderer.redact(image, rects: [CGRect(x: 10, y: 10, width: 20, height: 20)], style: .black), "black")
        try expect(close(try pixel(black, 15, 15), [0, 0, 0, 255], 0), "covered")
        try expect(try pixel(black, 60, 60) == (try pixel(image, 60, 60)), "rest untouched")
        let blurred = try unwrap(StudioRenderer.redact(image, rects: [CGRect(x: 50, y: 0, width: 50, height: 100)], style: .blur), "blur")
        try expect(try pixel(blurred, 10, 50) == (try pixel(image, 10, 50)), "outside untouched")
        let a = try pixel(blurred, 70, 50), b = try pixel(blurred, 71, 50)
        try expect(close(a, b, 10), "inside smoothed \(a) \(b)")
    }

    static func crop(_ dir: URL) throws {
        let image = try bitmap(40, 40) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 20, width: 40, height: 20)) // the top half
        }
        let top = try unwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 20)), "crop")
        try expect(close(try pixel(top, 5, 5), [255, 0, 0, 255]), "top half is red")
        let jpeg = dir.appendingPathComponent("shot.jpeg")
        try write(image, jpeg, type: .jpeg)
        let out = try ImageStudio.write(top, like: jpeg, "%@ Cropped")
        try expect(out.lastPathComponent == "shot Cropped.jpeg", "name \(out.lastPathComponent)")
        let decoded = try decode(out)
        try expect(decoded.type == UTType.jpeg.identifier && decoded.image.width == 40 && decoded.image.height == 20, "JPEG 40×20")
        let webp = dir.appendingPathComponent("odd.gif")
        try write(image, webp, type: .gif)
        try expect(try ImageStudio.write(top, like: webp, "%@ Cropped").pathExtension == "gif", "GIF stays GIF")
    }

    static func makeVideo(_ url: URL, seconds: Double = 1) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                            AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        try expect(writer.startWriting(), "writer")
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try unwrap(buffer, "pixel buffer")
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try expect(writer.status == .completed, "video fixture: \(String(describing: writer.error))")
    }

    static func makeTone(_ url: URL, seconds: Double = 1) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = sin(Float(i) * 0.06) * 0.3 }
        }
        try file.write(from: buffer)
    }

    static func video(_ dir: URL) async throws {
        let clip = dir.appendingPathComponent("clip.mov")
        try await makeVideo(clip)
        let mp4 = try await run(.convert(.mp4), [clip]).outputs
        let asset = AVURLAsset(url: mp4[0])
        try expect(try await !asset.loadTracks(withMediaType: .video).isEmpty, "MP4 has video")
        try expect(abs(try await asset.load(.duration).seconds - 1) < 0.15, "MP4 length")

        let gif = try await run(.convert(.gif), [clip]).outputs
        let source = try unwrap(CGImageSourceCreateWithURL(gif[0] as CFURL, nil), "GIF decodes")
        try expect(CGImageSourceGetType(source) as String? == UTType.gif.identifier && CGImageSourceGetCount(source) > 5, "animated GIF")

        do {
            _ = try await run(.convert(.m4a), [clip])
            throw Failure(description: "silent video made an M4A")
        } catch let error as FileToolError {
            try expect(error == .noSound, "error \(error)")
        }

        let muted = try await run(.mute, [clip]).outputs
        let mutedAsset = AVURLAsset(url: muted[0])
        try expect(try await mutedAsset.loadTracks(withMediaType: .audio).isEmpty, "no sound")
        try expect(try await !mutedAsset.loadTracks(withMediaType: .video).isEmpty, "picture kept")
        try expect(muted[0].lastPathComponent == "clip Muted.mov", "name \(muted[0].lastPathComponent)")
    }

    static func audio(_ dir: URL) async throws {
        let tone = dir.appendingPathComponent("tone.caf")
        try makeTone(tone)
        for format in [FileFormat.m4a, .wav, .aiff] {
            let out = try await run(.convert(format), [tone]).outputs
            try expect(out.first?.pathExtension == format.ext, "\(format) extension")
            let file = try AVAudioFile(forReading: out[0])
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            try expect(abs(seconds - 1) < 0.1, "\(format) length \(seconds)")
            try expect(file.fileFormat.channelCount == 2, "\(format) stereo")
        }
    }
}
