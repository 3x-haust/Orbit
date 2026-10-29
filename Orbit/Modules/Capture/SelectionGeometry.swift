import CoreGraphics

/// Aspect presets for the area selection, cycled with Tab / ⇧Tab.
enum AspectPreset: Int, CaseIterable {
    case free, square, fourThree, threeTwo, sixteenNine, nineSixteen

    /// Width over height; nil is free.
    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .threeTwo: 3.0 / 2.0
        case .sixteenNine: 16.0 / 9.0
        case .nineSixteen: 9.0 / 16.0
        }
    }

    var label: String {
        switch self {
        case .free: "Free"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }

    func next(backward: Bool = false) -> AspectPreset {
        let all = Self.allCases
        return all[(rawValue + (backward ? all.count - 1 : 1)) % all.count]
    }
}

/// The math behind a drag: where it started, where the pointer is, and arrow-key nudges of the
/// moving corner. Pure, so it can be checked without a screen. Points, any origin.
struct SelectionGeometry {
    var anchor: CGPoint
    var pointer: CGPoint
    /// Arrow-key nudges of the moving corner, kept on top of the pointer.
    var offset = CGVector.zero

    init(start: CGPoint) {
        anchor = start
        pointer = start
    }

    /// The corner that follows the pointer.
    var tip: CGPoint { CGPoint(x: pointer.x + offset.dx, y: pointer.y + offset.dy) }

    /// The selection, kept inside `bounds`. With an aspect (width / height) it grows to hold the tip and
    /// shrinks as a whole at an edge, so the ratio holds; from the center, the anchor is the middle.
    func rect(aspect: CGFloat?, fromCenter: Bool, in bounds: CGRect) -> CGRect {
        let dx = tip.x - anchor.x, dy = tip.y - anchor.y
        let sx: CGFloat = dx < 0 ? -1 : 1, sy: CGFloat = dy < 0 ? -1 : 1
        var w = abs(dx), h = abs(dy)
        if let r = aspect, r > 0, w > 0 || h > 0 {
            if h == 0 || w / h > r { h = w / r } else { w = h * r }
        }
        let roomX = max(0, fromCenter ? min(anchor.x - bounds.minX, bounds.maxX - anchor.x)
                                      : (sx > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX))
        let roomY = max(0, fromCenter ? min(anchor.y - bounds.minY, bounds.maxY - anchor.y)
                                      : (sy > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY))
        if aspect != nil, w > 0, h > 0 {
            let s = min(1, roomX / w, roomY / h)
            w *= s; h *= s
        } else {
            w = min(w, roomX); h = min(h, roomY)
        }
        if fromCenter { return CGRect(x: anchor.x - w, y: anchor.y - h, width: w * 2, height: h * 2) }
        return CGRect(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
    }

    /// The pointer moved. Carrying (Space held), the whole selection travels with it, stopping at the edges.
    mutating func move(pointer p: CGPoint, carrying: Bool, aspect: CGFloat?, fromCenter: Bool, in bounds: CGRect) {
        guard carrying else { pointer = p; return }
        let delta = CGVector(dx: p.x - pointer.x, dy: p.y - pointer.y)
        let moved = Self.clampedShift(rect(aspect: aspect, fromCenter: fromCenter, in: bounds), by: delta, in: bounds)
        anchor.x += moved.dx; anchor.y += moved.dy
        // The tip moves by the same amount, whatever the pointer did past an edge.
        offset.dx += moved.dx - delta.dx; offset.dy += moved.dy - delta.dy
        pointer = p
    }

    /// Arrow keys: the moving corner by `d`, kept inside `bounds`.
    mutating func nudge(_ d: CGVector, in bounds: CGRect) {
        let t = tip
        let x = min(max(t.x + d.dx, bounds.minX), bounds.maxX)
        let y = min(max(t.y + d.dy, bounds.minY), bounds.maxY)
        offset.dx += x - t.x; offset.dy += y - t.y
    }

    /// How far `rect` can travel by `delta` without leaving `bounds`.
    static func clampedShift(_ rect: CGRect, by delta: CGVector, in bounds: CGRect) -> CGVector {
        CGVector(dx: min(max(delta.dx, bounds.minX - rect.minX), bounds.maxX - rect.maxX),
                 dy: min(max(delta.dy, bounds.minY - rect.minY), bounds.maxY - rect.maxY))
    }

    static func shifted(_ rect: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        let d = clampedShift(rect, by: delta, in: bounds)
        return rect.offsetBy(dx: d.dx, dy: d.dy)
    }

    /// "#RRGGBB" for 8-bit channels.
    static func hex(r: UInt8, g: UInt8, b: UInt8) -> String {
        String(format: "#%02X%02X%02X", r, g, b)
    }
}
