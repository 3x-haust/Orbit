import CoreGraphics
import Foundation

/// A frame to stitch: 32-bit BGRA rows (what ScreenCaptureKit hands over), read in place.
struct StitchFrame {
    let base: UnsafeRawPointer
    let bytesPerRow: Int
    let width: Int
    let height: Int
}

/// Joins frames of a region the user is scrolling through into one tall picture.
///
/// Not tied to the main thread: the capture feeds it from its own frame queue, one frame at a time.
///
/// Each frame is boiled down once to a hash and a few band sums per row, read straight from the
/// frame's pixels. Rows that didn't move at the top and bottom (a sticky header or toolbar) are left
/// out; the rest of the frame is placed against the picture built so far, at the offset where its rows
/// match. Only what scrolled into view is appended, so the header shows once at the top and the
/// footer once at the bottom.
///
/// Where to look: first around where the scroll wheel says the page went (once its direction and
/// speed are learned from earlier matches), then anywhere within a frame of the last placed one or
/// in the last few frame heights of the picture, so after a frame it couldn't place it locks on
/// again as soon as a frame overlaps what's already there.
final class ScrollStitcher: @unchecked Sendable {
    enum Outcome: Equatable {
        /// The first frame.
        case started
        /// New rows at the bottom.
        case appended(Int)
        /// Same picture as before.
        case unchanged
        /// Placed, but nothing new (scrolled back up, or a little animation).
        case moved
        /// Couldn't tell where this frame belongs.
        case lost
        /// Reached `maxHeight`.
        case full
    }

    private(set) var width = 0
    private(set) var height = 0
    private(set) var frameHeight = 0
    /// The tallest the result may grow, in pixel rows.
    var maxHeight = 60_000
    /// How far the page moved between the last placed frame and this one, when this one was placed.
    private(set) var lastShift: Int?
    /// Rows between the sticky header and footer in the latest frame.
    private(set) var bodyRows = 0
    /// What the latest frame came to, in a few words (for the log).
    private(set) var note = ""

    // The picture: `height` rows of `width` BGRA pixels, tightly packed.
    private var store: UnsafeMutableRawPointer?
    private var capacityRows = 0
    private var rowBytes: Int { width * 4 }

    // Row features of the picture, kept alongside it.
    private var resHash: [UInt64] = []
    private var resBands: [UInt32] = []
    private var resInfo: [Bool] = []

    /// Band sums per row.
    private var k = 16
    /// UInt64 words (two pixels) per band; the rightmost few percent of the frame (where an overlay
    /// scroll bar shows up while scrolling) are left out of the features.
    private var bandWords = 0
    /// Two rows count as the same when their band sums differ by at most this much in all.
    private var tolerance: UInt32 = 0
    /// Half a level per pixel: for frames that come through bit for bit.
    private var strictTolerance: UInt32 = 0
    /// How many of the rows that lined up were identical to the bit, lately (nil: no idea yet).
    /// Screen frames normally are; video, or a stream that converts colours, isn't.
    private var exactness: Double?
    private var maybeNoisy: Bool { (exactness ?? 0) < 0.8 }

    private var prev: Features?
    /// Where the previous frame sat in the picture, if it was placed.
    private var prevY0: Int?
    private var lastGoodY0: Int?
    private var lastDy: Int?
    private var footerRows = 0
    private var stillFrames = 0
    private var wheelMisses = 0

    // The scroll wheel, as a guess: raw units since the last placed frame, and pixels per unit.
    private var pendingRaw: Double? = 0
    private var gain = 0.0
    private var gainVotes = 0
    var calibrated: Bool { gainVotes >= 2 }
    /// Pixels the page moves per raw scroll unit, once learned.
    var pixelsPerRaw: Double? { calibrated ? abs(gain) : nil }

    var isEmpty: Bool { height == 0 }

    init() {}

    deinit { free(store) }

    // MARK: Adding

    /// - Parameter motion: scroll-wheel movement since the previous call, in whatever units the
    ///   caller has (nil: unknown, e.g. scrolls outside the area); the stitcher learns the scale.
    @discardableResult
    func add(_ frame: StitchFrame, motion: Double? = nil) -> Outcome {
        lastShift = nil
        note = ""
        if height == 0 { return start(frame) }
        guard frame.width == width, frame.height == frameHeight else {
            note = "size \(frame.width)x\(frame.height) != \(width)x\(frameHeight)"
            return .lost
        }
        if let m = motion, let p = pendingRaw { pendingRaw = p + m } else { pendingRaw = nil }

        let cur = extract(frame)
        guard let prev else { self.prev = cur; return .lost }
        self.prev = cur
        let h = frameHeight

        // Rows unchanged from the last frame, from the top and from the bottom.
        let stillTolerance = maybeNoisy ? tolerance : strictTolerance
        var top = 0
        while top < h, distance(cur, top, prev, top) <= stillTolerance { top += 1 }
        if top == h {
            guard let y0 = prevY0 else { return .lost }
            lastShift = 0
            lastGoodY0 = y0
            stillFrames += 1
            // Wheel movement that never showed up (the end of the page): forget it.
            if stillFrames > 3 { pendingRaw = 0 }
            return .unchanged
        }
        top = sticky(cur, prev, from: 0, step: 1, limit: min(top, h / 3))
        let bottom = sticky(cur, prev, from: h - 1, step: -1, limit: h / 3)
        let r0 = top, r1 = h - bottom
        // The picture ends with the last placed frame's bottom rows; only those still unmoved in this frame
        // (the real footer) are left out of the match.
        let bodyEnd = height - min(footerRows, bottom)
        let minOverlap = max(24, (r1 - r0) / 16)
        note = "top \(top) bottom \(bottom) info \(cur.infoRows.count)"
        guard r1 - r0 > minOverlap, bodyEnd > minOverlap else { prevY0 = nil; note += " band too small"; return .lost }

        var placed = place(cur, r0: r0, r1: r1, bodyEnd: bodyEnd, minOverlap: minOverlap, loose: false)
        if placed == nil, maybeNoisy {
            note += " | loose"
            placed = place(cur, r0: r0, r1: r1, bodyEnd: bodyEnd, minOverlap: minOverlap, loose: true)
        }
        guard let placed else {
            prevY0 = nil
            return .lost
        }
        let y0 = placed.y0
        // Only frames that moved say whether frames come through bit for bit (still areas of a
        // video do, its moving ones don't).
        if let g = lastGoodY0, y0 != g { noteExactness(Double(placed.exact) / Double(max(1, placed.overlap))) }
        let dy = lastGoodY0.map { y0 - $0 }
        learn(dy)
        // Wheel movement counted but not on screen yet (the frame was taken a moment before its
        // events were read) carries over, half of it, so it isn't lost from the next guess.
        if calibrated, let p = pendingRaw, let dy {
            let left = (p - Double(dy) / gain) * 0.5
            pendingRaw = abs(left * gain) <= Double(frameHeight) / 4 ? left : 0
        } else {
            pendingRaw = 0
        }
        lastShift = dy
        lastDy = dy
        lastGoodY0 = y0
        prevY0 = y0
        stillFrames = 0
        bodyRows = r1 - r0

        // The picture and the frame both end with the same footer, so the frame has something new
        // exactly when it reaches further down. Then the picture is cut where its own rows can be
        // trusted (above whatever might be footer) and continues with the frame from that row.
        let grow = y0 + h - height
        guard grow > 0 else { return .moved }
        let room = maxHeight - height
        guard room > 0 else { return .full }
        let newStart = bodyEnd - y0
        let cut = max(0, grow - room)
        truncate(to: bodyEnd)
        append(frame, cur, newStart..<(h - cut))
        footerRows = h - r1
        return cut > 0 ? .full : .appended(grow)
    }

    private func start(_ frame: StitchFrame) -> Outcome {
        width = frame.width
        frameHeight = frame.height
        let usableWords = max(1, (frame.width - max(24, frame.width * 3 / 100)) / 2)
        k = max(8, min(32, usableWords / 24))
        bandWords = max(1, usableWords / k)
        // About 1.7 levels per pixel, all channels together: frames aren't always bit-exact (colour
        // conversion, video in the page), while a row one pixel off differs by far more.
        tolerance = UInt32(bandWords * k * 2 * 17 / 10)
        strictTolerance = UInt32(bandWords * k)
        reserve(frame.height * 8)
        let f = extract(frame)
        append(frame, f, 0..<frame.height)
        prev = f
        prevY0 = 0
        lastGoodY0 = 0
        footerRows = frame.height // not known yet: whatever stays put in the next frame
        bodyRows = frame.height
        return .started
    }

    // MARK: Placing

    private struct Candidate {
        let y0: Int; let bad: Int; let info: Int; let overlap: Int; let exact: Int
        var badShare: Double { Double(bad) / Double(max(1, overlap)) }
    }

    /// The offset into the picture where the frame's rows `r0..<r1` sit, or nil.
    private func noteExactness(_ share: Double) {
        exactness = exactness.map { $0 * 0.7 + share * 0.3 } ?? share
    }

    private func place(_ cur: Features, r0: Int, r1: Int, bodyEnd: Int, minOverlap: Int, loose: Bool) -> Candidate? {
        let h = frameHeight
        let infoRows = cur.infoRows
        let predicted: Double? = {
            guard calibrated, let p = pendingRaw, let g = lastGoodY0 else { return nil }
            return Double(g) + p * gain
        }()
        let velocity: Double? = lastGoodY0.map { Double($0 + (lastDy ?? 0)) }

        // Around where the wheel says the page went.
        if let c = predicted, let g = lastGoodY0 {
            let margin = max(48, 0.35 * abs(c - Double(g)))
            let range = Int((c - margin).rounded(.down))...Int((c + margin).rounded(.up))
            // Taken as it is only if it fits cleanly; a rough fit may be a near-copy (a list whose rows
            // differ in a word), so then the wider search decides.
            if let pick = best(of: [range], cur, infoRows, r0, r1, bodyEnd, minOverlap, wheel: c, velocity: velocity, loose: loose),
               pick.badShare <= 0.01 { return pick }
        }
        // Anywhere within a frame of the last placed one, or along the end of the picture.
        let maxShift = r1 - r0 - minOverlap
        var ranges: [ClosedRange<Int>] = []
        if let g = lastGoodY0 { ranges.append((g - maxShift)...(g + maxShift)) }
        let tailLow = bodyEnd - 3 * h
        let tailHigh = bodyEnd - r0 - minOverlap
        if tailLow <= tailHigh { ranges.append(tailLow...tailHigh) }
        return best(of: Self.merged(ranges), cur, infoRows, r0, r1, bodyEnd, minOverlap, wheel: predicted, velocity: velocity, loose: loose)
    }

    private func best(of ranges: [ClosedRange<Int>], _ cur: Features, _ infoRows: [Int32], _ r0: Int, _ r1: Int,
                      _ bodyEnd: Int, _ minOverlap: Int, wheel: Double?, velocity: Double?, loose: Bool) -> Candidate? {
        var passing: [Candidate] = []
        cur.hash.withUnsafeBufferPointer { ch in
            cur.bands.withUnsafeBufferPointer { cb in
                cur.isInfo.withUnsafeBufferPointer { ci in
                    resInfo.withUnsafeBufferPointer { ri in
                    resHash.withUnsafeBufferPointer { rh in
                        resBands.withUnsafeBufferPointer { rb in
                            infoRows.withUnsafeBufferPointer { info in
                                let m = Matcher(ch: ch, cb: cb, ci: ci, rh: rh, rb: rb, ri: ri, k: k,
                                                tolerance: loose ? tolerance : strictTolerance, loose: loose)
                                for range in ranges {
                                    for y0 in range {
                                        if let c = m.evaluate(y0: y0, r0: r0, r1: r1, bodyEnd: bodyEnd, minOverlap: minOverlap, info: info) {
                                            passing.append(c)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    }
                }
            }
        }
        if passing.isEmpty {
            note += " tried \(ranges.reduce(0) { $0 + $1.count }) none fit"
            return nil
        }
        note += " fits \(passing.count)"
        // The cleanest fits first: repeating content (a list of identical rows) can line up at several
        // offsets, but the wrong ones usually run into a row or two that doesn't repeat.
        let minShare = passing.map(\.badShare).min() ?? 0
        let clean = passing.filter { $0.badShare <= minShare + 0.015 + 3 / Double(max(1, $0.overlap)) }
        let maxInfo = clean.map(\.info).max() ?? 0
        func nearest(_ pool: [Candidate], _ c: Double) -> Candidate? {
            pool.min { a, b in
                let da = abs(Double(a.y0) - c), db = abs(Double(b.y0) - c)
                return da != db ? da < db : a.info > b.info
            }
        }
        guard maxInfo > 0 else {
            // Nothing but blank rows overlap: only the wheel can say where it went.
            guard let c = wheel, let pick = nearest(clean, c), abs(Double(pick.y0) - c) <= 48 else { return nil }
            return pick
        }
        // Still several: the wheel says which, or else the speed so far, among the ones that line up
        // about as much.
        let pool = clean.filter { $0.info * 4 >= maxInfo }
        if let c = wheel {
            guard let pick = nearest(pool, c) else { return nil }
            // Far from where the wheel says: more likely the same content further up the page (another
            // copy of a repeating list) than this frame. Give up on the wheel if that keeps happening.
            let g = Double(lastGoodY0 ?? 0)
            if abs(Double(pick.y0) - c) > max(Double(frameHeight) / 2, 0.6 * abs(c - g)), wheelMisses < 4 {
                wheelMisses += 1
                return nil
            }
            wheelMisses = 0
            return pick
        }
        if let c = velocity { return nearest(pool, c) }
        return pool.min { a, b in a.info != b.info ? a.info > b.info : a.badShare < b.badShare }
    }

    private static func merged(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    private struct Matcher {
        let ch: UnsafeBufferPointer<UInt64>
        let cb: UnsafeBufferPointer<UInt32>
        let ci: UnsafeBufferPointer<Bool>
        let rh: UnsafeBufferPointer<UInt64>
        let rb: UnsafeBufferPointer<UInt32>
        let ri: UnsafeBufferPointer<Bool>
        let k: Int
        let tolerance: UInt32
        /// Noisy frames: a quarter of the rows may disagree; otherwise a sixteenth.
        let loose: Bool

        @inline(__always) func matches(_ r: Int, _ y: Int) -> Bool {
            if ch[r] == rh[y] { return true }
            var d: UInt32 = 0
            let a = r * k, b = y * k
            for i in 0..<k {
                let x = cb[a + i], z = rb[b + i]
                d &+= x > z ? x - z : z - x
            }
            return d <= tolerance
        }

        /// Frame row `r` over picture row `y0 + r`.
        func evaluate(y0: Int, r0: Int, r1: Int, bodyEnd: Int, minOverlap: Int, info: UnsafeBufferPointer<Int32>) -> Candidate? {
            let lo = max(r0, -y0), hi = min(r1, bodyEnd - y0)
            let overlap = hi - lo
            guard overlap >= minOverlap else { return nil }
            // A quick look at up to 24 of the rows that carry something (not blank, not a copy of the
            // row above): a wrong offset fails here almost at once.
            // (The overlap's first row always differs from the one above it, which isn't compared.)
            let a = Self.lowerBound(info, lo + 1), b = Self.lowerBound(info, hi)
            let n = b - a
            if n > 0 {
                let samples = min(n, 24)
                var bad = 0
                for s in 0..<samples {
                    let r = Int(info[a + s * n / samples])
                    if !matches(r, y0 + r) {
                        bad += 1
                        if bad > samples / (loose ? 4 : 8) { return nil }
                    }
                }
            }
            // Then every row. What counts in a fit's favour: rows that carry something matching rows
            // that do too (an edge lining up with an edge, not a blank row with any other blank row).
            // A few rows may disagree (the pointer, an animation), with noisy frames up to a quarter;
            // a wrong offset disagrees on more than half of them.
            let maxBad = max(1, overlap / (loose ? 4 : 16)), maxInfoBad = max(1, n / (loose ? 4 : 8))
            var bad = 0, infoBad = 0, support = 0, exact = 0
            for r in lo..<hi {
                let y = y0 + r
                if matches(r, y) {
                    if ch[r] == rh[y] { exact += 1 }
                    if r > lo, ci[r], ri[y] { support += 1 }
                } else {
                    bad += 1
                    if r > lo, ci[r] { infoBad += 1 }
                    if bad > maxBad || infoBad > maxInfoBad { return nil }
                }
            }
            return Candidate(y0: y0, bad: bad, info: support, overlap: overlap, exact: exact)
        }

        static func lowerBound(_ a: UnsafeBufferPointer<Int32>, _ v: Int) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(a[mid]) < v { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    /// Learns the wheel's direction and scale from frames that were placed.
    private func learn(_ dy: Int?) {
        guard let dy, abs(dy) >= 12, let p = pendingRaw, abs(p) >= 2 else { return }
        let ratio = Double(dy) / p
        if gainVotes == 0 { gain = ratio; gainVotes = 1; return }
        if ratio.sign == gain.sign, abs(ratio / gain - 1) < 0.35 {
            gain = gain * 0.8 + ratio * 0.2
            gainVotes = min(gainVotes + 1, 8)
        } else {
            gainVotes -= 1
            if gainVotes == 0 { gain = ratio; gainVotes = 1 }
        }
    }

    // MARK: Features

    private struct Features {
        var hash: [UInt64]
        var bands: [UInt32]
        /// Differs from the row above.
        var isInfo: [Bool]
        var infoRows: [Int32]
    }

    @inline(__always) private func distance(_ a: Features, _ ra: Int, _ b: Features, _ rb: Int) -> UInt32 {
        if a.hash[ra] == b.hash[rb] { return 0 }
        var d: UInt32 = 0
        for i in 0..<k {
            let x = a.bands[ra * k + i], z = b.bands[rb * k + i]
            d &+= x > z ? x - z : z - x
        }
        return d
    }

    @inline(__always) private func same(_ a: Features, _ ra: Int, _ b: Features, _ rb: Int) -> Bool {
        distance(a, ra, b, rb) <= tolerance
    }

    /// How many rows from `from` (going `step`) stayed put between the frames: a sticky header or
    /// footer. Held to the strict tolerance, so a smooth gradient that moved a little doesn't pass for
    /// one; a few noisy rows in a row are let through.
    private func sticky(_ cur: Features, _ prev: Features, from: Int, step: Int, limit: Int) -> Int {
        let strict = strictTolerance
        var n = 0, loose = 0
        var r = from
        while n < limit {
            let d = distance(cur, r, prev, r)
            if d > tolerance { break }
            if d > strict { loose += 1; if loose > 3 { n -= loose - 1; break } } else { loose = 0 }
            n += 1
            r += step
        }
        return max(0, n)
    }

    private func extract(_ frame: StitchFrame) -> Features {
        let h = frame.height, k = self.k, bandWords = self.bandWords
        let edge = tolerance * 2
        var hash = [UInt64](repeating: 0, count: h)
        var bands = [UInt32](repeating: 0, count: h * k)
        var isInfo = [Bool](repeating: false, count: h)
        var infoRows: [Int32] = []
        infoRows.reserveCapacity(h)
        let mask: UInt64 = 0x00FF_00FF_00FF_00FF
        @inline(__always) func fold(_ l: UInt64) -> UInt32 {
            UInt32(l & 0xFFFF) + UInt32((l >> 16) & 0xFFFF) + UInt32((l >> 32) & 0xFFFF) + UInt32(l >> 48)
        }
        hash.withUnsafeMutableBufferPointer { hp in
            bands.withUnsafeMutableBufferPointer { bp in
                isInfo.withUnsafeMutableBufferPointer { ip in
                    for r in 0..<h {
                        let row = frame.base + r * frame.bytesPerRow
                        var h1: UInt64 = 0x243F_6A88_85A3_08D3, h2: UInt64 = 0x1319_8A2E_0370_7344
                        var w = 0
                        for b in 0..<k {
                            let end = w + bandWords
                            var lanes: UInt64 = 0, total: UInt32 = 0, run = 0
                            while w + 1 < end {
                                let v1 = row.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
                                let v2 = row.loadUnaligned(fromByteOffset: w * 8 + 8, as: UInt64.self)
                                h1 = (h1 ^ v1) &* 0x9E37_79B9_7F4A_7C15
                                h2 = (h2 ^ v2) &* 0xC2B2_AE3D_27D4_EB4F
                                lanes &+= (v1 & mask) &+ ((v1 >> 8) & mask) &+ (v2 & mask) &+ ((v2 >> 8) & mask)
                                w += 2
                                run += 2
                                if run >= 120 { total &+= fold(lanes); lanes = 0; run = 0 }
                            }
                            if w < end {
                                let v = row.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
                                h1 = (h1 ^ v) &* 0x9E37_79B9_7F4A_7C15
                                lanes &+= (v & mask) &+ ((v >> 8) & mask)
                                w += 1
                            }
                            bp[r * k + b] = total &+ fold(lanes)
                        }
                        var x = h1 ^ (h2 &* 0xFF51_AFD7_ED55_8CCD)
                        x ^= x >> 33
                        hp[r] = x
                        // Carries something: clearly different from the row above (not blank, not
                        // a copy of it, and not just noise).
                        if r > 0, x != hp[r - 1] {
                            var d: UInt32 = 0
                            let a = r * k, b = (r - 1) * k
                            for i in 0..<k {
                                let p = bp[a + i], q = bp[b + i]
                                d &+= p > q ? p - q : q - p
                            }
                            if d > edge { ip[r] = true }
                        }
                    }
                }
            }
        }
        for r in 0..<h where isInfo[r] { infoRows.append(Int32(r)) }
        return Features(hash: hash, bands: bands, isInfo: isInfo, infoRows: infoRows)
    }

    // MARK: Storage

    /// Grows in steps (realloc: big blocks move by remapping pages, not copying), never past
    /// `maxHeight` plus a frame.
    private func reserve(_ rows: Int) {
        guard rows > capacityRows else { return }
        let cap = min(max(rows, capacityRows * 2), max(rows, maxHeight + frameHeight))
        guard let next = realloc(store, cap * rowBytes) else { return }
        store = next
        capacityRows = cap
    }

    private func truncate(to rows: Int) {
        guard rows < height else { return }
        height = rows
        resHash.removeLast(resHash.count - rows)
        resInfo.removeLast(resInfo.count - rows)
        resBands.removeLast(resBands.count - rows * k)
    }

    private func append(_ frame: StitchFrame, _ f: Features, _ rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        reserve(height + rows.count)
        guard let store, capacityRows >= height + rows.count else { return } // out of memory: keep what there is
        let bytes = rowBytes
        for (i, r) in rows.enumerated() {
            (store + (height + i) * bytes).copyMemory(from: frame.base + r * frame.bytesPerRow, byteCount: bytes)
        }
        height += rows.count
        resHash.append(contentsOf: f.hash[rows])
        resInfo.append(contentsOf: f.isInfo[rows])
        resBands.append(contentsOf: f.bands[(rows.lowerBound * k)..<(rows.upperBound * k)])
    }

    // MARK: Output

    private static let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)

    /// The whole picture (a copy).
    /// The colour space the frames are in (the display's, as the stream delivers them).
    var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The whole picture (a copy).
    func image() -> CGImage? {
        guard height > 0, let store else { return nil }
        let data = Data(bytes: store, count: height * rowBytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: colorSpace, bitmapInfo: Self.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The whole picture, handing over its memory instead of copying it (a tall one can be over a
    /// gigabyte); the stitcher is empty afterwards.
    func takeImage() -> CGImage? {
        guard height > 0, let store else { return nil }
        let bytes = height * rowBytes
        self.store = nil
        capacityRows = 0
        let (w, h, rb) = (width, height, rowBytes)
        height = 0
        resHash = []; resBands = []; resInfo = []; prev = nil
        guard let provider = CGDataProvider(dataInfo: nil, data: store, size: bytes, releaseData: { _, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
        }) else { free(store); return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rb,
                       space: colorSpace, bitmapInfo: Self.bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A small copy of the end of the picture (at most 1.5 widths tall), for the live preview.
    func preview(maxWidth: Int) -> CGImage? {
        guard height > 0, let store else { return nil }
        let rows = min(height, width * 3 / 2)
        let bytes = rowBytes
        // Wraps the rows in place: drawn right away, before anything can change them.
        guard let provider = CGDataProvider(dataInfo: nil, data: store + (height - rows) * bytes, size: rows * bytes,
                                            releaseData: { _, _, _ in }),
              let tail = CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytes,
                                 space: colorSpace, bitmapInfo: Self.bitmapInfo,
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let w = min(maxWidth, width), h = max(1, rows * w / width)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: Self.bitmapInfo.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(tail, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Row `y` of the picture (for tests).
    func row(_ y: Int) -> UnsafeRawPointer? {
        guard y >= 0, y < height, let store else { return nil }
        return UnsafeRawPointer(store + y * rowBytes)
    }
}
