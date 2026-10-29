import SwiftUI

/// Draws the screenshot with its annotations. Used both on screen (scaled) and for export (scale 1).
struct AnnotatedImage: View {
    let model: EditorModel
    let scale: CGFloat
    var exporting = false

    var body: some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: scale, y: scale)
            let full = CGRect(origin: .zero, size: model.size)
            let base = Image(nsImage: model.image)
            ctx.draw(base, in: full)

            var all = model.annotations
            if let draft = model.draft, draft.tool != .crop { all.append(draft) }

            // Hiding first, then the dimming around spotlights, then marks on top so they stay bright.
            for a in all where a.tool.redacts { Self.draw(a, in: &ctx, model: model, base: base, full: full) }
            let spots = all.filter { $0.tool == .spotlight }
            if !spots.isEmpty {
                var outside = Path(full)
                for s in spots { outside.addPath(Path(roundedRect: s.rect, cornerRadius: 8, style: .continuous)) }
                ctx.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            }
            for a in all where !a.tool.redacts && a.tool != .spotlight { Self.draw(a, in: &ctx, model: model, base: base, full: full) }

            guard !exporting else { return }
            for a in all where a.id == model.selectedID {
                let b = a.bounds.insetBy(dx: -6, dy: -6)
                ctx.stroke(Path(roundedRect: b, cornerRadius: 4), with: .color(Palette.accent),
                           style: StrokeStyle(lineWidth: 1.5 / scale, dash: [4 / scale, 3 / scale]))
            }
            for s in spots where model.draft?.id == s.id {
                ctx.stroke(Path(roundedRect: s.rect, cornerRadius: 8, style: .continuous), with: .color(.white.opacity(0.8)),
                           style: StrokeStyle(lineWidth: 1 / scale, dash: [5 / scale, 4 / scale]))
            }
            let cropRect = model.draft?.tool == .crop ? model.draft?.rect : model.crop
            if let cropRect {
                var outside = Path(full)
                outside.addRect(cropRect)
                ctx.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
                ctx.stroke(Path(cropRect), with: .color(.white), style: StrokeStyle(lineWidth: 1.5 / scale, dash: [6 / scale, 4 / scale]))
                let px = model.pixelScale
                ctx.draw(Text("\(Int(cropRect.width * px)) × \(Int(cropRect.height * px))")
                            .font(.system(size: 11 / scale, weight: .semibold).monospacedDigit()).foregroundStyle(.white),
                         at: CGPoint(x: cropRect.midX, y: cropRect.maxY + 12 / scale))
            }
        }
    }

    static func draw(_ a: Annotation, in ctx: inout GraphicsContext, model: EditorModel, base: Image, full: CGRect) {
        let shading = GraphicsContext.Filter.shadow(color: .black.opacity(0.35), radius: 2.5, x: 0, y: 1)
        switch a.tool {
        case .arrow:
            ctx.drawLayer { layer in
                layer.addFilter(shading)
                let (shaft, head) = arrowPaths(from: a.start, to: a.end, width: a.width, curved: a.curved)
                layer.stroke(shaft, with: .color(a.color), style: StrokeStyle(lineWidth: a.width, lineCap: .round))
                layer.fill(head, with: .color(a.color))
            }
        case .line:
            ctx.drawLayer { layer in
                layer.addFilter(shading)
                var p = Path()
                p.move(to: a.start)
                p.addLine(to: a.end)
                layer.stroke(p, with: .color(a.color), style: StrokeStyle(lineWidth: a.width, lineCap: .round))
            }
        case .rect:
            ctx.drawLayer { layer in
                layer.addFilter(shading)
                let path = Path(roundedRect: a.rect, cornerRadius: min(a.cornerRadius, min(a.rect.width, a.rect.height) / 2), style: .continuous)
                if a.filled { layer.fill(path, with: .color(a.color)) } else { layer.stroke(path, with: .color(a.color), lineWidth: a.width) }
            }
        case .ellipse:
            ctx.drawLayer { layer in
                layer.addFilter(shading)
                let path = Path(ellipseIn: a.rect)
                if a.filled { layer.fill(path, with: .color(a.color)) } else { layer.stroke(path, with: .color(a.color), lineWidth: a.width) }
            }
        case .pen:
            ctx.drawLayer { layer in
                layer.addFilter(shading)
                layer.stroke(smooth(a.points), with: .color(a.color), style: StrokeStyle(lineWidth: a.width, lineCap: .round, lineJoin: .round))
            }
        case .highlight:
            var layer = ctx
            layer.blendMode = .multiply
            layer.stroke(smooth(a.points), with: .color(a.color.opacity(0.45)),
                         style: StrokeStyle(lineWidth: a.width * 5 + 8, lineCap: .round, lineJoin: .round))
        case .text:
            drawText(a, in: &ctx)
        case .counter:
            let d = a.counterDiameter
            let r = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
            ctx.drawLayer { layer in
                layer.addFilter(shading)
                layer.fill(Path(ellipseIn: r), with: .color(a.color))
            }
            ctx.stroke(Path(ellipseIn: r.insetBy(dx: 1, dy: 1)), with: .color(.white.opacity(0.9)), lineWidth: 2)
            ctx.draw(Text("\(a.number)").font(.system(size: d * 0.52, weight: .bold, design: .rounded)).foregroundStyle(contrast(a.color)),
                     at: CGPoint(x: r.midX, y: r.midY))
        case .blur, .pixelate:
            var layer = ctx
            layer.clip(to: Path(roundedRect: a.rect, cornerRadius: a.tool == .blur ? 6 : 2, style: .continuous))
            layer.draw(Image(nsImage: model.redacted(a.tool, strength: a.strength)), in: full)
        case .erase:
            ctx.fill(Path(a.rect), with: .color(a.fill ?? .white))
        case .loupe:
            drawLoupe(a, in: &ctx, base: base, full: full)
        case .measure:
            drawRuler(a, in: &ctx, pixelScale: model.pixelScale)
        case .spotlight, .crop, .select, .picker:
            break
        }
    }

    // MARK: Pieces

    private static func drawText(_ a: Annotation, in ctx: inout GraphicsContext) {
        let font = Font.system(size: a.fontSize, weight: a.weight.font)
        switch a.textStyle {
        case .shadow:
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1))
                layer.draw(Text(a.text).font(font).foregroundStyle(a.color), at: a.start, anchor: .topLeading)
            }
        case .plain:
            ctx.draw(Text(a.text).font(font).foregroundStyle(a.color), at: a.start, anchor: .topLeading)
        case .pill:
            let b = a.bounds
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1))
                layer.fill(Path(roundedRect: b, cornerRadius: min(b.height / 2, a.fontSize * 0.7), style: .continuous), with: .color(a.color))
            }
            ctx.draw(Text(a.text).font(font).foregroundStyle(contrast(a.color)), at: a.start, anchor: .topLeading)
        case .outline:
            let edge = contrast(a.color)
            let o = max(1, a.fontSize / 14)
            for (dx, dy) in [(-o, 0), (o, 0), (0, -o), (0, o), (-o, -o), (o, o), (-o, o), (o, -o)] {
                ctx.draw(Text(a.text).font(font).foregroundStyle(edge), at: CGPoint(x: a.start.x + dx, y: a.start.y + dy), anchor: .topLeading)
            }
            ctx.draw(Text(a.text).font(font).foregroundStyle(a.color), at: a.start, anchor: .topLeading)
        }
    }

    private static func drawLoupe(_ a: Annotation, in ctx: inout GraphicsContext, base: Image, full: CGRect) {
        let r = a.loupeRadius, c = a.loupeCenter, z = Annotation.loupeZoom
        let lens = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        // A thin leader from the spot to the lens, and a ring on the spot itself.
        let spot = r / z
        var leader = Path()
        let angle = atan2(c.y - a.start.y, c.x - a.start.x)
        leader.move(to: CGPoint(x: a.start.x + cos(angle) * spot, y: a.start.y + sin(angle) * spot))
        leader.addLine(to: CGPoint(x: c.x - cos(angle) * r, y: c.y - sin(angle) * r))
        ctx.stroke(leader, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        ctx.stroke(Path(ellipseIn: CGRect(x: a.start.x - spot, y: a.start.y - spot, width: spot * 2, height: spot * 2)),
                   with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 3))
            layer.fill(Path(ellipseIn: lens), with: .color(.white))
        }
        var inside = ctx
        inside.clip(to: Path(ellipseIn: lens))
        let zoomed = CGRect(x: c.x - a.start.x * z, y: c.y - a.start.y * z, width: full.width * z, height: full.height * z)
        inside.draw(base, in: zoomed)
        ctx.stroke(Path(ellipseIn: lens.insetBy(dx: 1.5, dy: 1.5)), with: .color(a.color), lineWidth: 3)
    }

    private static func drawRuler(_ a: Annotation, in ctx: inout GraphicsContext, pixelScale: CGFloat) {
        let s = a.start, e = a.end
        let angle = atan2(e.y - s.y, e.x - s.x)
        let tick: CGFloat = 6
        var path = Path()
        path.move(to: s)
        path.addLine(to: e)
        for p in [s, e] {
            path.move(to: CGPoint(x: p.x + cos(angle + .pi / 2) * tick, y: p.y + sin(angle + .pi / 2) * tick))
            path.addLine(to: CGPoint(x: p.x - cos(angle + .pi / 2) * tick, y: p.y - sin(angle + .pi / 2) * tick))
        }
        ctx.stroke(path, with: .color(.black.opacity(0.5)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        ctx.stroke(path, with: .color(a.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        let length = Int((hypot(e.x - s.x, e.y - s.y) * pixelScale).rounded())
        let dx = Int((abs(e.x - s.x) * pixelScale).rounded()), dy = Int((abs(e.y - s.y) * pixelScale).rounded())
        let label = dx > 2 && dy > 2 ? "\(length) px  (\(dx) × \(dy))" : "\(length) px"
        let text = ctx.resolve(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white))
        let size = text.measure(in: CGSize(width: 400, height: 40))
        let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
        let pill = CGRect(x: mid.x - size.width / 2 - 7, y: mid.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
        ctx.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(.black.opacity(0.75)))
        ctx.draw(text, at: mid)
    }

    /// White on dark colours, black on light ones.
    static func contrast(_ c: Color) -> Color {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return .white }
        let l = 0.299 * n.redComponent + 0.587 * n.greenComponent + 0.114 * n.blueComponent
        return l > 0.7 ? .black : .white
    }

    private static func arrowPaths(from s: CGPoint, to e: CGPoint, width w: CGFloat, curved: Bool) -> (Path, Path) {
        let length = hypot(e.x - s.x, e.y - s.y)
        // A curved arrow bows to one side; its head follows the curve's direction at the tip.
        let control = CGPoint(x: (s.x + e.x) / 2 - (e.y - s.y) * 0.28, y: (s.y + e.y) / 2 + (e.x - s.x) * 0.28)
        let angle = curved ? atan2(e.y - control.y, e.x - control.x) : atan2(e.y - s.y, e.x - s.x)
        let headLength = min(max(14, w * 4.2), length * 0.6)
        let headWidth = headLength * 0.85
        let base = CGPoint(x: e.x - cos(angle) * headLength * 0.8, y: e.y - sin(angle) * headLength * 0.8)

        var shaft = Path()
        shaft.move(to: s)
        if curved { shaft.addQuadCurve(to: base, control: control) } else { shaft.addLine(to: base) }

        let back = CGPoint(x: e.x - cos(angle) * headLength, y: e.y - sin(angle) * headLength)
        let left = CGPoint(x: back.x + cos(angle + .pi / 2) * headWidth / 2, y: back.y + sin(angle + .pi / 2) * headWidth / 2)
        let right = CGPoint(x: back.x + cos(angle - .pi / 2) * headWidth / 2, y: back.y + sin(angle - .pi / 2) * headWidth / 2)
        var head = Path()
        head.move(to: e)
        head.addLine(to: left)
        head.addQuadCurve(to: right, control: base)
        head.closeSubpath()
        return (shaft, head)
    }

    private static func smooth(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points.last!)
        return path
    }
}
