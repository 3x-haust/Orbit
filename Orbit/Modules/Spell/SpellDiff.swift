import Foundation

/// Where spell check finds its edits: never the engine's word for it, always a diff of the text
/// before and after. Words (어절 for Korean — everything between spaces) are lined up first, then
/// the characters inside each changed stretch, so "학교에 갓다" → "학교에 갔다" marks just 갓 → 갔.
enum SpellDiff {
    enum Op: Equatable { case equal, delete, insert }

    struct Segment: Equatable, Hashable {
        var op: Op
        var text: String
    }

    /// One changed stretch of the source.
    struct Hunk: Equatable {
        /// In Characters (grapheme clusters) of the source.
        var range: Range<Int>
        var original: String
        var replacement: String
        /// Character-level detail: equal / deleted / inserted pieces, in reading order.
        var segments: [Segment]
    }

    // MARK: Hunks

    static func hunks(from source: String, to corrected: String) -> [Hunk] {
        let a = tokens(source), b = tokens(corrected)
        let steps = myers(a.map(\.text), b.map(\.text))
        guard steps.contains(where: { $0.op != .equal }) else { return [] }

        // Changed stretches of the step list, [lo, hi).
        var spans: [(lo: Int, hi: Int)] = []
        var i = 0
        while i < steps.count {
            guard steps[i].op != .equal else { i += 1; continue }
            var j = i
            while j < steps.count, steps[j].op != .equal { j += 1 }
            spans.append((i, j))
            i = j
        }

        func text(_ lo: Int, _ hi: Int, source: Bool) -> String {
            steps[lo..<hi].compactMap { s in
                if source { s.op == .insert ? nil : a[s.a].text } else { s.op == .delete ? nil : b[s.b].text }
            }.joined()
        }
        func hasWord(_ s: String) -> Bool { !s.allSatisfy(\.isWhitespace) }
        func trimmedEnd(_ s: String) -> Substring { s[..<(s.lastIndex(where: { !$0.isWhitespace }).map { s.index(after: $0) } ?? s.startIndex)] }
        /// Readable on its own: a word on both sides, and more than a space at the end changed
        /// ("going → am going", not "+ am"; "a  b → a b", not "a␣␣ → a␣").
        func readable(_ lo: Int, _ hi: Int) -> Bool {
            let src = text(lo, hi, source: true), dst = text(lo, hi, source: false)
            return hasWord(src) && hasWord(dst) && trimmedEnd(src) != trimmedEnd(dst)
        }

        var merged: [(lo: Int, hi: Int)] = []
        for span in spans {
            var lo = span.lo, hi = span.hi
            func absorb() {
                if let last = merged.last, last.hi >= lo { lo = last.lo; hi = max(hi, last.hi); merged.removeLast() }
            }
            absorb()
            while !readable(lo, hi) {
                if hi < steps.count { hi += 1 } else if lo > 0 { lo -= 1 } else { break }
                // Grew into the next stretch: one hunk.
                while hi < steps.count, steps[hi].op != .equal { hi += 1 }
                absorb()
            }
            merged.append((lo, hi))
        }

        return merged.flatMap { span -> [Hunk] in
            let src = steps[span.lo..<span.hi].filter { $0.op != .insert }.map { a[$0.a] }
            let dst = steps[span.lo..<span.hi].filter { $0.op != .delete }.map { b[$0.b].text }
            let start = src.first?.offset ?? insertionOffset(steps, span.lo, a)
            let original = src.map(\.text).joined()
            let replacement = dst.joined()
            // Spaces added or dropped at the very end of the text aren't worth a correction.
            guard original.trimmingCharacters(in: .whitespacesAndNewlines) != replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return [] }
            return split(Hunk(range: start..<(start + original.count), original: original, replacement: replacement,
                              segments: refine(original, replacement)))
        }
    }

    /// Neighbouring words fixed at once ("has a" → "have an") become a correction each, cut at the
    /// unchanged spaces between them — as long as every piece still reads on its own.
    private static func split(_ h: Hunk) -> [Hunk] {
        var pieces: [(op: Op, ch: Character)] = []
        for s in h.segments { for c in s.text { pieces.append((s.op, c)) } }
        guard pieces.count > 1 else { return [h] }
        var cuts = [0]
        for i in 1..<pieces.count where pieces[i - 1].op == .equal && pieces[i - 1].ch.isWhitespace
            && pieces[i].op != .insert && !pieces[i].ch.isWhitespace { cuts.append(i) }
        cuts.append(pieces.count)
        guard cuts.count > 2 else { return [h] }
        var groups: [Range<Int>] = zip(cuts, cuts.dropFirst()).map { $0..<$1 }

        func changed(_ g: Range<Int>) -> Bool { pieces[g].contains { $0.op != .equal } }
        func sides(_ g: Range<Int>) -> (String, String) {
            (String(pieces[g].filter { $0.op != .insert }.map(\.ch)), String(pieces[g].filter { $0.op != .delete }.map(\.ch)))
        }
        func readable(_ g: Range<Int>) -> Bool {
            let (src, dst) = sides(g)
            let t = CharacterSet.whitespacesAndNewlines
            return src.contains { !$0.isWhitespace } && dst.contains { !$0.isWhitespace }
                && src.trimmingCharacters(in: t) != dst.trimmingCharacters(in: t)
        }
        while groups.count > 1, let i = groups.firstIndex(where: { changed($0) && !readable($0) }) {
            if i + 1 < groups.count { groups[i] = groups[i].lowerBound..<groups[i + 1].upperBound; groups.remove(at: i + 1) }
            else { groups[i - 1] = groups[i - 1].lowerBound..<groups[i].upperBound; groups.remove(at: i) }
        }
        return groups.filter(changed).map { g in
            let before = pieces[..<g.lowerBound].filter { $0.op != .insert }.count
            let (src, dst) = sides(g)
            var segs: [Segment] = []
            for p in pieces[g] {
                if let last = segs.last, last.op == p.op { segs[segs.count - 1].text.append(p.ch) }
                else { segs.append(Segment(op: p.op, text: String(p.ch))) }
            }
            let start = h.range.lowerBound + before
            return Hunk(range: start..<(start + src.count), original: src, replacement: dst, segments: segs)
        }
    }

    /// Where a pure insertion lands in the source (after the last token before it).
    private static func insertionOffset(_ steps: [Step], _ lo: Int, _ a: [Token]) -> Int {
        for s in steps[..<lo].reversed() where s.op != .insert { return a[s.a].offset + a[s.a].text.count }
        return 0
    }

    /// The source with the given hunks replaced.
    static func apply(_ hunks: [Hunk], to source: String) -> String {
        let chars = Array(source)
        var out = ""
        var at = 0
        for h in hunks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where h.range.lowerBound >= at {
            out += String(chars[at..<min(h.range.lowerBound, chars.count)])
            out += h.replacement
            at = min(h.range.upperBound, chars.count)
        }
        out += String(chars[min(at, chars.count)...])
        return out
    }

    // MARK: Character refinement

    /// Character diff of one changed stretch, cleaned up so it reads: a lone letter left standing
    /// between two changes is folded into them ("t~~eh~~he", not "t~~e~~h+e+").
    static func refine(_ original: String, _ replacement: String) -> [Segment] {
        let a = Array(original), b = Array(replacement)
        // Too big to be worth it: one whole replacement.
        guard a.count * b.count <= 160_000 else {
            return [Segment(op: .delete, text: original), Segment(op: .insert, text: replacement)].filter { !$0.text.isEmpty }
        }
        var segs: [Segment] = []
        for s in myers(a, b) {
            let ch = s.op == .insert ? b[s.b] : a[s.a]
            if let last = segs.last, last.op == s.op { segs[segs.count - 1].text.append(ch) }
            else { segs.append(Segment(op: s.op, text: String(ch))) }
        }
        // Fold short equal islands between changes, except next to a spacing change: "안될것" →
        // "안 될 것" reads best as two inserted spaces.
        var changed = true
        while changed {
            changed = false
            var i = 1
            while i < segs.count - 1 {
                let s = segs[i]
                if s.op == .equal, s.text.count <= 1, !s.text.allSatisfy(\.isWhitespace),
                   segs[i - 1].op != .equal, segs[i + 1].op != .equal,
                   !segs[i - 1].text.allSatisfy(\.isWhitespace), !segs[i + 1].text.allSatisfy(\.isWhitespace) {
                    segs[i] = Segment(op: .delete, text: s.text)
                    segs.insert(Segment(op: .insert, text: s.text), at: i + 1)
                    changed = true
                }
                i += 1
            }
            segs = normalize(segs)
        }
        return segs
    }

    /// Runs of changes as one deletion then one insertion; neighbouring equal pieces joined.
    private static func normalize(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var del = "", ins = ""
        func flush() {
            if !del.isEmpty { out.append(Segment(op: .delete, text: del)) }
            if !ins.isEmpty { out.append(Segment(op: .insert, text: ins)) }
            del = ""; ins = ""
        }
        for s in segs {
            switch s.op {
            case .delete: del += s.text
            case .insert: ins += s.text
            case .equal:
                flush()
                if let last = out.last, last.op == .equal { out[out.count - 1].text += s.text } else { out.append(s) }
            }
        }
        flush()
        return out
    }

    // MARK: Tokens

    struct Token: Equatable {
        var text: String
        /// In Characters from the start of the text.
        var offset: Int
    }

    /// A word (an 어절 with its particles and punctuation) together with the spaces after it; any
    /// spaces before the first word are a token of their own. Joined back they are the text again.
    /// Keeping the spaces on the word stops the diff from lining up spaces alone: "안녕 하세요" →
    /// "안녕하세요" is one change, not "안녕 → 안녕하세요" plus "하세요 → ∅".
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = []
        var current = "", start = 0, i = 0, inSpace = true
        for ch in text {
            let space = ch.isWhitespace
            // A word starts after spaces: close the previous token.
            if !space, inSpace, !current.isEmpty {
                out.append(Token(text: current, offset: start))
                current = ""; start = i
            }
            inSpace = space
            current.append(ch)
            i += 1
        }
        if !current.isEmpty { out.append(Token(text: current, offset: start)) }
        return out
    }

    // MARK: Myers

    struct Step: Equatable {
        var op: Op
        /// Index into the first sequence (equal, delete) and the second (equal, insert); -1 if none.
        var a: Int
        var b: Int
    }

    /// Myers' O((N+M)·D) shortest edit script. Common ends are peeled off first, and a script
    /// longer than `limit` edits gives up into "delete all, insert all".
    static func myers<T: Equatable>(_ x: [T], _ y: [T], limit: Int = 1200) -> [Step] {
        var head = 0
        while head < x.count, head < y.count, x[head] == y[head] { head += 1 }
        var tail = 0
        while tail < x.count - head, tail < y.count - head, x[x.count - 1 - tail] == y[y.count - 1 - tail] { tail += 1 }
        let a = Array(x[head..<(x.count - tail)]), b = Array(y[head..<(y.count - tail)])

        var steps: [Step] = (0..<head).map { Step(op: .equal, a: $0, b: $0) }
        steps += middle(a, b, limit: limit).map {
            Step(op: $0.op, a: $0.a < 0 ? -1 : $0.a + head, b: $0.b < 0 ? -1 : $0.b + head)
        }
        steps += (0..<tail).map { Step(op: .equal, a: x.count - tail + $0, b: y.count - tail + $0) }
        return steps
    }

    private static func middle<T: Equatable>(_ a: [T], _ b: [T], limit: Int) -> [Step] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { Step(op: .insert, a: -1, b: $0) } }
        if m == 0 { return (0..<n).map { Step(op: .delete, a: $0, b: -1) } }
        let maxD = n + m, off = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...maxD {
            if d > limit { break }
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[off + k] = x
                if x >= n, y >= m { found = true; break search }
            }
        }
        guard found else {
            return (0..<n).map { Step(op: .delete, a: $0, b: -1) } + (0..<m).map { Step(op: .insert, a: -1, b: $0) }
        }
        var out: [Step] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) ? k + 1 : k - 1
            let prevX = v[off + prevK], prevY = prevX - prevK
            while x > prevX, y > prevY {
                out.append(Step(op: .equal, a: x - 1, b: y - 1)); x -= 1; y -= 1
            }
            if d > 0 {
                if x == prevX { out.append(Step(op: .insert, a: -1, b: y - 1)) }
                else { out.append(Step(op: .delete, a: x - 1, b: -1)) }
            }
            x = prevX; y = prevY
        }
        return out.reversed()
    }
}
