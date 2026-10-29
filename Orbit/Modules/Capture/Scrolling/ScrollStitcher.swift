import CoreGraphics
import Foundation

/// Joins frames of a region the user is scrolling through into one tall picture.
///
/// Each new frame is matched against the previous one: rows that didn't move at the top and bottom
/// (a sticky header or toolbar) are left out of the match, and the vertical shift whose overlapping
/// rows differ least wins. Only what scrolled into view is appended, so the header shows once at the
/// top and the footer once at the bottom.
struct ScrollStitcher {
    enum Outcome: Equatable {
        case started, appended(Int), unchanged, lost
    }

    private(set) var width = 0
    private(set) var height = 0
    /// RGBA, `height` rows of `width` pixels.
    private(set) var pixels: [UInt8] = []
    private var previous: [UInt8] = []
    private var previousSignature: [Float] = []
    private var frameHeight = 0
    /// The tallest the result may grow, in pixel rows.
    var maxHeight = 40_000

    private static let samples = 96

    var isEmpty: Bool { height == 0 }

    @discardableResult
    mutating func add(_ image: CGImage) -> Outcome {
        guard let frame = Self.rgba(image, width: width == 0 ? image.width : width, height: image.height) else { return .lost }
        let h = image.height
        if height == 0 {
            width = width == 0 ? image.width : width
            frameHeight = h
            pixels = frame
            height = h
            previous = frame
            previousSignature = Self.signature(frame, width: width, height: h)
            return .started
        }
        guard h == frameHeight else { return .lost }
        let signature = Self.signature(frame, width: width, height: h)
        // Can't tell where we are (scrolled a whole screen between frames, or the page changed):
        // keep the old frame as the reference so the next one gets another try.
        guard let match = Self.match(previous: previousSignature, current: signature, rows: h) else { return .lost }
        previous = frame
        previousSignature = signature
        guard match.shift > 0 else { return .unchanged }
        guard height + match.shift <= maxHeight else { return .unchanged }

        let rowBytes = width * 4
        // Drop the old copy of the footer, add what scrolled in, then the footer again.
        let footer = match.bottom
        pixels.removeLast(footer * rowBytes)
        height -= footer
        let bodyEnd = h - footer
        let newRows = (bodyEnd - match.shift)..<bodyEnd
        pixels.append(contentsOf: frame[(newRows.lowerBound * rowBytes)..<(newRows.upperBound * rowBytes)])
        pixels.append(contentsOf: frame[(bodyEnd * rowBytes)..<(h * rowBytes)])
        height += match.shift + footer
        return .appended(match.shift)
    }

    func image() -> CGImage? {
        guard height > 0 else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Matching

    struct Match { let shift: Int; let top: Int; let bottom: Int }

    /// Signatures are `rows × samples` luminance values.
    static func match(previous p: [Float], current c: [Float], rows h: Int) -> Match? {
        let s = samples
        func rowDiff(_ a: Int, _ b: Int) -> Float {
            var sum: Float = 0
            let ai = a * s, bi = b * s
            for i in 0..<s { sum += abs(p[ai + i] - c[bi + i]) }
            return sum / Float(s)
        }
        let still: Float = 0.5
        // Identical frames: nothing scrolled.
        var same = true
        for r in stride(from: 0, to: h, by: 3) where rowDiff(r, r) > still { same = false; break }
        if same { return Match(shift: 0, top: 0, bottom: 0) }

        var top = 0
        while top < h / 3, rowDiff(top, top) <= still { top += 1 }
        var bottom = 0
        while bottom < h / 3, rowDiff(h - 1 - bottom, h - 1 - bottom) <= still { bottom += 1 }
        let band = top..<(h - bottom)
        let minOverlap = max(16, band.count / 6)
        guard band.count > minOverlap + 1 else { return nil }

        func cost(_ dy: Int, step: Int, limit: Float) -> Float {
            // previous[r + dy] should equal current[r] over the overlap.
            var sum: Float = 0, n: Float = 0
            var r = band.lowerBound
            while r + dy < band.upperBound {
                sum += rowDiff(r + dy, r)
                n += 1
                if n > 8, sum / n > limit { return .infinity }
                r += step
            }
            return n > 0 ? sum / n : .infinity
        }

        let maxShift = band.count - minOverlap
        var best = (dy: 0, cost: cost(0, step: 4, limit: .infinity))
        var dy = 1
        while dy <= maxShift {
            let value = cost(dy, step: 4, limit: best.cost)
            if value < best.cost { best = (dy, value) }
            dy += 1
        }
        // Refine with every row near the winner.
        var refined = best
        refined.cost = cost(best.dy, step: 1, limit: .infinity)
        for d in max(0, best.dy - 3)...min(maxShift, best.dy + 3) where d != best.dy {
            let value = cost(d, step: 1, limit: refined.cost)
            if value < refined.cost { refined = (d, value) }
        }
        guard refined.cost < 6 else { return nil }
        return Match(shift: refined.dy, top: top, bottom: bottom)
    }

    static func signature(_ rgba: [UInt8], width: Int, height: Int) -> [Float] {
        let s = samples
        var out = [Float](repeating: 0, count: height * s)
        rgba.withUnsafeBufferPointer { px in
            for r in 0..<height {
                let row = r * width * 4
                for i in 0..<s {
                    let x = min(width - 1, (i * width + width / 2) / s)
                    let o = row + x * 4
                    out[r * s + i] = 0.299 * Float(px[o]) + 0.587 * Float(px[o + 1]) + 0.114 * Float(px[o + 2])
                }
            }
        }
        return out
    }

    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? bytes : nil
    }
}
