import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A character the user brought: frames from a GIF or a handful of PNGs.
struct CustomRunner: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// One color like the rest of the menu bar, or the frames' own colors.
    var template = true
    var frameCount = 0
}

/// Custom runners live in Application Support/Orbit/Runners/<id>/ as frame-000.png … plus runner.json.
/// Frames are kept in color; the one-color look is made when they're loaded, so it can be switched later.
enum RunnerStore {
    static let maxFrames = 60
    /// Stored at 4× the menu bar height so previews stay sharp.
    private static let pixelHeight = 72

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Orbit/Runners", isDirectory: true)
    }

    private static func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func load() -> [CustomRunner] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return dirs.compactMap { dir -> (CustomRunner, Date)? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("runner.json")),
                  let runner = try? JSONDecoder().decode(CustomRunner.self, from: data) else { return nil }
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (runner, created)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    static func save(_ runner: CustomRunner) {
        let dir = folder(runner.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(runner) { try? data.write(to: dir.appendingPathComponent("runner.json")) }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    enum ImportError: LocalizedError {
        case noFrames
        var errorDescription: String? { "Couldn’t read any frames from those files.".loc }
    }

    /// Every frame of every file, in order: an animated GIF or PNG gives all its frames, still images one each.
    static func importFiles(_ urls: [URL]) throws -> CustomRunner {
        var frames: [CGImage] = []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            for i in 0..<CGImageSourceGetCount(source) where frames.count < maxFrames {
                if let image = CGImageSourceCreateImageAtIndex(source, i, nil) { frames.append(image) }
            }
        }
        guard !frames.isEmpty else { throw ImportError.noFrames }

        var runner = CustomRunner(name: urls.first?.deletingPathExtension().lastPathComponent ?? "Runner".loc)
        let dir = folder(runner.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Same size for every frame (the first one's proportions), so the menu bar doesn't jitter.
        let aspect = min(4, max(0.5, CGFloat(frames[0].width) / CGFloat(max(1, frames[0].height))))
        let size = (width: Int((CGFloat(pixelHeight) * aspect).rounded()), height: pixelHeight)
        for (i, frame) in frames.enumerated() {
            guard let scaled = fit(frame, width: size.width, height: size.height),
                  let out = CGImageDestinationCreateWithURL(dir.appendingPathComponent(String(format: "frame-%03d.png", i)) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(out, scaled, nil)
            CGImageDestinationFinalize(out)
        }
        runner.frameCount = frames.count
        save(runner)
        return runner
    }

    /// Frames ready for the menu bar: 18 pt tall.
    static func frames(for runner: CustomRunner) -> [NSImage] {
        (0..<runner.frameCount).compactMap { i in
            let url = folder(runner.id).appendingPathComponent(String(format: "frame-%03d.png", i))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            if runner.template, let mask = silhouette(image) { image = mask }
            let height = (RunnerArt.height * RunnerArt.scale).rounded()
            let ns = NSImage(cgImage: image, size: NSSize(width: height * CGFloat(image.width) / CGFloat(image.height), height: height))
            ns.isTemplate = runner.template
            return ns
        }
    }

    private static func fit(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// One-color version for the menu bar. Transparent art keeps its shape; art on a solid
    /// background (most GIFs) loses the background, judged by the corner color.
    private static func silhouette(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let corners = [0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + w - 1) * 4]
        let opaque = corners.allSatisfy { px[$0 + 3] > 240 }
        let bg = (0..<3).map { c in corners.map { Double(px[$0 + c]) }.reduce(0, +) / 4 }
        for i in stride(from: 0, to: px.count, by: 4) {
            var alpha = Double(px[i + 3]) / 255
            if opaque {
                let d = sqrt((0..<3).map { pow(Double(px[i + $0]) - bg[$0], 2) }.reduce(0, +)) / 255
                alpha = min(1, max(0, (d - 0.08) * 2.5))
            }
            px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
            px[i + 3] = UInt8(alpha * 255)
        }
        return ctx.makeImage()
    }
}
