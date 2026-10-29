import AppKit

/// Orbit's own menu bar runners, drawn in code: crisp at any scale and tinted like the rest of the menu bar.
enum RunnerArt: String, CaseIterable, Identifiable {
    case orbit, bars, dots

    var id: String { rawValue }
    /// The runners are drawn on an 18pt grid and shown a little larger, filling the menu bar.
    static let height: CGFloat = 18
    static let scale: CGFloat = 1.2

    /// Runners that were retired (every character); a saved choice of one of them moves to Orbit.
    static func resolve(_ id: String) -> String {
        guard !id.hasPrefix("custom."), RunnerArt(rawValue: id) == nil else { return id }
        return RunnerArt.orbit.rawValue
    }

    var title: String {
        switch self {
        case .orbit: "Orbit"
        case .bars: "Bars"
        case .dots: "Dots"
        }
    }

    private var frameCount: Int {
        switch self {
        case .orbit: 16
        case .dots: 12
        case .bars: 10
        }
    }

    private var width: CGFloat {
        switch self {
        case .orbit: 24
        case .bars, .dots: 20
        }
    }

    func frames() -> [NSImage] {
        (0..<frameCount).map { i in
            let image = NSImage(size: NSSize(width: (width * Self.scale).rounded(), height: (Self.height * Self.scale).rounded()), flipped: false) { _ in
                NSAffineTransform().then { $0.scale(by: Self.scale) }.concat()
                NSColor.black.setFill()
                NSColor.black.setStroke()
                draw(frame: i, of: frameCount)
                return true
            }
            image.isTemplate = true
            return image
        }
    }

    private func draw(frame i: Int, of n: Int) {
        let p = CGFloat(Double(i) / Double(n) * 2 * .pi)
        switch self {
        case .orbit: Draw.orbit(p)
        case .bars: Draw.bars(p)
        case .dots: Draw.dots(p)
        }
    }
}

// MARK: - Drawing

private enum Draw {
    static func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    static func fill(_ path: NSBezierPath, alpha: CGFloat = 1) {
        NSColor.black.withAlphaComponent(alpha).setFill()
        path.fill()
    }

    /// Cuts shapes out of what's drawn so far.
    static func knockout(_ body: () -> Void) {
        let context = NSGraphicsContext.current
        let previous = context?.compositingOperation ?? .sourceOver
        context?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSColor.black.setStroke()
        body()
        context?.compositingOperation = previous
        NSColor.black.setFill()
        NSColor.black.setStroke()
    }

    // MARK: Satellite

    /// A little planet with a satellite circling it.
    static func orbit(_ p: CGFloat) {
        // The planet holds still; only the moon goes round.
        let c = CGPoint(x: 12, y: 9)
        let tilt: CGFloat = -0.38
        func point(_ θ: CGFloat) -> CGPoint {
            let x = 10.5 * cos(θ), y = 3.4 * sin(θ)
            return CGPoint(x: c.x + x * cos(tilt) - y * sin(tilt), y: c.y + x * sin(tilt) + y * cos(tilt))
        }
        func arc(_ from: CGFloat, _ to: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.move(to: point(from))
            for i in 1...40 { path.line(to: point(from + (to - from) * CGFloat(i) / 40)) }
            return path
        }
        let back = arc(0, .pi)
        back.lineWidth = 1.5
        back.stroke()
        knockout { circle(c, 6.3).fill() }
        fill(circle(c, 5.2))
        let front = arc(.pi, 2 * .pi)
        knockout { front.lineWidth = 3.2; front.stroke() }
        front.lineWidth = 1.5
        front.stroke()

        let θ = -p
        let s = point(θ)
        let hidden = sin(θ) >= 0 && hypot(s.x - c.x, s.y - c.y) < 6.3
        if !hidden {
            knockout { circle(s, 3.0).fill() }
            fill(circle(s, 2.1))
        }
    }

    // MARK: Abstract

    static func bars(_ p: CGFloat) {
        for i in 0..<5 {
            let h = 3 + 12 * (0.5 + 0.5 * sin(p + CGFloat(i) * 0.8))
            let rect = CGRect(x: 1.8 + CGFloat(i) * 3.6, y: (RunnerArt.height - h) / 2, width: 2.4, height: h)
            fill(NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2))
        }
    }

    /// Three jelly beans hopping in turn.
    static func dots(_ p: CGFloat) {
        for i in 0..<3 {
            let lift = abs(sin(p - CGFloat(i) * .pi / 3))
            let r: CGFloat = 2.4
            let squash: CGFloat = lift < 0.2 ? 0.9 : (lift > 0.8 ? -0.3 : 0)
            let rect = CGRect(x: 4 + CGFloat(i) * 6 - r - squash / 2, y: 1.4 + lift * 9, width: r * 2 + squash, height: r * 2 - squash)
            fill(NSBezierPath(ovalIn: rect))
        }
    }
}

private extension NSAffineTransform {
    func then(_ change: (NSAffineTransform) -> Void) -> NSAffineTransform { change(self); return self }
}
