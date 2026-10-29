import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

extension Capture {
    var isVideo: Bool { ["mp4", "mov", "m4v"].contains(fileURL.pathExtension.lowercased()) }
    var isGIF: Bool { fileURL.pathExtension.lowercased() == "gif" }
    /// Opened in its own app instead of Orbit's image editor.
    var opensExternally: Bool { isVideo || isGIF }
}

/// Thumbnails, durations and GIF export for recordings.
@MainActor
enum VideoTools {
    static var durations: [URL: Double] = [:]

    static func durationText(_ url: URL) -> String? {
        durations[url].map(RecordingChrome.clock)
    }

    static func thumbnail(_ url: URL, scale: CGFloat) async -> NSImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1200, height: 1200)
        guard let (cg, _) = try? await generator.image(at: CMTime(seconds: 0.05, preferredTimescale: 600)) else {
            return NSImage(systemSymbolName: "video", accessibilityDescription: nil) ?? NSImage()
        }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    /// Videos in QuickTime Player, everything else in its default app.
    static func open(_ url: URL) {
        let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        if url.pathExtension.lowercased() != "gif", FileManager.default.fileExists(atPath: quickTime.path) {
            NSWorkspace.shared.open([url], withApplicationAt: quickTime, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Writes a looping GIF next to the video: 15 fps (fewer for long clips), at most 800 points wide.
    /// - Parameters:
    ///   - range: seconds to keep (the whole clip when nil).
    ///   - destination: where to write it (next to the video when nil).
    static func exportGIF(_ url: URL, range: ClosedRange<Double>? = nil, to destination: URL? = nil) async -> URL? {
        let out = destination ?? url.deletingPathExtension().appendingPathExtension("gif")
        let ok = await Task.detached(priority: .userInitiated) { await writeGIF(from: url, to: out, range: range) }.value
        return ok ? out : nil
    }

    /// Writes the kept part of a video as MP4, optionally without sound.
    nonisolated static func exportMP4(_ url: URL, range: ClosedRange<Double>, muted: Bool, to out: URL) async throws {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                    end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
        var transform: CGAffineTransform = .identity
        for track in try await asset.loadTracks(withMediaType: .video) {
            let t = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try t?.insertTimeRange(timeRange, of: track, at: .zero)
            transform = try await track.load(.preferredTransform)
            t?.preferredTransform = transform
        }
        if !muted {
            for track in try await asset.loadTracks(withMediaType: .audio) {
                let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(timeRange, of: track, at: .zero)
            }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: out)
        try await session.export(to: out, as: .mp4)
    }

    private nonisolated static func writeGIF(from url: URL, to out: URL, range: ClosedRange<Double>?) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let total = try? await asset.load(.duration).seconds, total > 0 else { return false }
        let start = range.map { max(0, $0.lowerBound) } ?? 0
        let duration = (range.map { min(total, $0.upperBound) } ?? total) - start
        guard duration > 0 else { return false }
        // Keep big clips manageable: never more than ~450 frames.
        let fps = min(15, max(3, 450 / duration))
        let count = max(1, Int(duration * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 4000)
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: start + Double($0) / fps, preferredTimescale: 600) }

        try? FileManager.default.removeItem(at: out)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / fps
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        var last: CGImage?
        var added = 0
        for await result in generator.images(for: times) {
            // A frame that can't be read repeats the previous one, so the timing stays right.
            if let image = try? result.image { last = image }
            guard let image = last else { continue }
            CGImageDestinationAddImage(dest, image, frame)
            added += 1
        }
        guard let last else { return false }
        while added < count { CGImageDestinationAddImage(dest, last, frame); added += 1 }
        return CGImageDestinationFinalize(dest)
    }
}
