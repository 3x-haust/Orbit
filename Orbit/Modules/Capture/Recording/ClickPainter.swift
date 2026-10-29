import AppKit
import CoreImage
import CoreMedia

/// Paints Orbit's click rings into a window recording's frames. A window capture holds only that
/// window, so the overlay the area and screen recordings use can't be in it; instead each click is
/// remembered (where in the window, when) and drawn over the frames it falls in — even while the
/// window is behind others, since the capture is of the window itself.
///
/// Used only on the writer's queue.
final class ClickPainter {
    private struct Click {
        let time: CMTime
        /// Where in the window, as a fraction of its size (0…1, top-left origin).
        let spot: CGPoint
        /// Window width in points at the time, to size the ring like the overlay's.
        let windowWidth: CGFloat
        let secondary: Bool
    }

    /// The same timing as the overlay's pulse.
    static let duration = 0.55
    private static let side: CGFloat = 46

    private var clicks: [Click] = []
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var loggedGeometry = false

    func add(at point: CGPoint, in window: CGRect, secondary: Bool, time: CMTime) {
        guard window.width > 1, window.height > 1, window.insetBy(dx: -2, dy: -2).contains(point) else { return }
        let spot = CGPoint(x: (point.x - window.minX) / window.width, y: (point.y - window.minY) / window.height)
        clicks.append(Click(time: time, spot: spot, windowWidth: window.width, secondary: secondary))
    }

    /// Rings still to draw at or after `time`.
    func hasRings(at time: CMTime) -> Bool {
        clicks.removeAll { CMTimeGetSeconds(CMTimeSubtract(time, $0.time)) > Self.duration }
        return !clicks.isEmpty
    }

    /// `source` with the rings showing at `time` drawn over it, or nil if none are (use the source as is).
    /// `content` is where the window sits in the frame, in frame points; `scale` is pixels per point.
    func paint(_ source: CVPixelBuffer, at time: CMTime, content: CGRect, scale: CGFloat) -> CVPixelBuffer? {
        let live = clicks.filter {
            let t = CMTimeGetSeconds(CMTimeSubtract(time, $0.time))
            return t >= 0 && t <= Self.duration
        }
        guard !live.isEmpty else { return nil }
        let width = CGFloat(CVPixelBufferGetWidth(source)), height = CGFloat(CVPixelBufferGetHeight(source))
        // Where the window is in pixels. If the reported rect doesn't fit at this scale, it was in
        // content points: fit it to the frame instead.
        var k = scale
        if content.width * k > width * 1.02 || content.height * k > height * 1.02 {
            k = min(width / max(content.width, 1), height / max(content.height, 1))
        }
        let rect = content.width > 1 ? CGRect(x: content.minX * k, y: content.minY * k, width: content.width * k, height: content.height * k)
                                     : CGRect(x: 0, y: 0, width: width, height: height)
        if !loggedGeometry {
            loggedGeometry = true
            RecordingLog.write("window frame \(Int(width))×\(Int(height)), content \(content), scale \(scale) → window in pixels \(rect)")
        }

        var image = CIImage(cvPixelBuffer: source)
        for click in live {
            let t = CMTimeGetSeconds(CMTimeSubtract(time, click.time)) / Self.duration
            let pixelsPerPoint = rect.width / max(click.windowWidth, 1)
            guard let ring = Self.ring(progress: t, secondary: click.secondary, pointSize: pixelsPerPoint) else { continue }
            let x = rect.minX + click.spot.x * rect.width
            let y = rect.minY + click.spot.y * rect.height
            // Core Image's origin is bottom-left; the frame's is top-left.
            let placed = ring.transformed(by: CGAffineTransform(translationX: x - ring.extent.width / 2,
                                                                y: (height - y) - ring.extent.height / 2))
            image = placed.composited(over: image)
        }

        guard let out = buffer(like: source) else { return nil }
        CVBufferPropagateAttachments(source, out)
        context.render(image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: out,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }

    private func buffer(like source: CVPixelBuffer) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if pool == nil || size != poolSize {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &created)
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// One ring at `progress` (0…1) of its pulse: a soft disc with a bright edge and a white halo that
    /// grows and fades — drawn like ClickHighlighter's layers.
    private static func ring(progress t: Double, secondary: Bool, pointSize: CGFloat) -> CIImage? {
        let eased = 1 - pow(1 - t, 2)
        let grow = 0.45 + (1.15 - 0.45) * eased
        let opacity = t < 0.45 ? 1 : max(0, 1 - (t - 0.45) / 0.55)
        guard opacity > 0.01 else { return nil }
        let diameter = side * CGFloat(grow) * pointSize
        let pad = 6 * pointSize
        let canvas = Int((diameter + pad * 2).rounded(.up))
        guard canvas > 2,
              let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let tint = secondary ? NSColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue : NSColor(srgbRed: 1, green: 0.42, blue: 0.1, alpha: 1)
        ctx.setAlpha(CGFloat(opacity))
        let rect = CGRect(x: pad, y: pad, width: diameter, height: diameter)
        ctx.setShadow(offset: .zero, blur: 2 * pointSize, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor(tint.withAlphaComponent(0.32).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let line = 2.5 * pointSize * CGFloat(grow)
        ctx.setStrokeColor(tint.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(line)
        ctx.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        let halo = 2.5 * pointSize * CGFloat(grow)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(max(1, pointSize * CGFloat(grow)))
        ctx.strokeEllipse(in: rect.insetBy(dx: -halo, dy: -halo))
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
