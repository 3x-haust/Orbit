import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins
import Observation

struct Annotation: Identifiable, Equatable {
    enum Tool: String, CaseIterable {
        case select, arrow, line, rect, ellipse, pen, highlight, text, counter
        case blur, pixelate, erase, spotlight, loupe, measure, picker, crop

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .arrow: "arrow.up.right"
            case .line: "line.diagonal"
            case .rect: "rectangle"
            case .ellipse: "circle"
            case .pen: "scribble"
            case .highlight: "highlighter"
            case .text: "textformat"
            case .counter: "1.circle"
            case .blur: "drop.halffull"
            case .pixelate: "square.grid.3x3.square"
            case .erase: "eraser"
            case .spotlight: "light.max"
            case .loupe: "magnifyingglass.circle"
            case .measure: "ruler"
            case .picker: "eyedropper"
            case .crop: "crop"
            }
        }

        var title: String {
            switch self {
            case .select: "Select"
            case .arrow: "Arrow"
            case .line: "Line"
            case .rect: "Rectangle"
            case .ellipse: "Ellipse"
            case .pen: "Pen"
            case .highlight: "Highlighter"
            case .text: "Text"
            case .counter: "Counter"
            case .blur: "Blur"
            case .pixelate: "Pixelate"
            case .erase: "Erase"
            case .spotlight: "Spotlight"
            case .loupe: "Magnifier"
            case .measure: "Ruler"
            case .picker: "Color Picker"
            case .crop: "Crop"
            }
        }

        /// Single-letter keys, Shottr-style. L is Live Text, handled by the window.
        var key: Character {
            switch self {
            case .select: "v"
            case .arrow: "a"
            case .line: "i"
            case .rect: "r"
            case .ellipse: "o"
            case .pen: "d"
            case .highlight: "h"
            case .text: "t"
            case .counter: "n"
            case .blur: "b"
            case .pixelate: "p"
            case .erase: "e"
            case .spotlight: "s"
            case .loupe: "g"
            case .measure: "m"
            case .picker: "k"
            case .crop: "c"
            }
        }

        /// Tools that hide what's under them.
        var redacts: Bool { self == .blur || self == .pixelate || self == .erase }
    }

    /// The toolbar's groups: one button each, the rest of a group a click away.
    enum Group: String, CaseIterable {
        case select, shapes, draw, text, counter, redact, inspect, crop

        var tools: [Tool] {
            switch self {
            case .select: [.select]
            case .shapes: [.arrow, .line, .rect, .ellipse]
            case .draw: [.pen, .highlight]
            case .text: [.text]
            case .counter: [.counter]
            case .redact: [.blur, .pixelate, .erase, .spotlight]
            case .inspect: [.loupe, .measure, .picker]
            case .crop: [.crop]
            }
        }

        var title: String {
            switch self {
            case .select: "Select"
            case .shapes: "Shapes"
            case .draw: "Draw"
            case .text: "Text"
            case .counter: "Counter"
            case .redact: "Hide & Focus"
            case .inspect: "Measure"
            case .crop: "Crop"
            }
        }

        static func of(_ tool: Tool) -> Group { allCases.first { $0.tools.contains(tool) } ?? .select }
    }

    enum TextStyle: String, CaseIterable { case shadow, plain, pill, outline }
    enum TextWeight: String, CaseIterable {
        case regular, semibold, bold, heavy
        var font: Font.Weight {
            switch self {
            case .regular: .regular
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            }
        }
    }

    var id = UUID()
    var tool: Tool
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
    var text = ""
    var number = 0
    var filled = false
    var cornerRadius: CGFloat = 3
    var curved = false
    var fontSize: CGFloat = 24
    var weight: TextWeight = .bold
    var textStyle: TextStyle = .shadow
    /// Blur and pixelate strength, 1–10.
    var strength: CGFloat = 5
    /// The erase tool's fill, sampled from around the area when it's drawn.
    var fill: Color?

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var counterDiameter: CGFloat { 18 + width * 3 }
    var loupeRadius: CGFloat { 36 + width * 7 }
    static let loupeZoom: CGFloat = 2.5

    /// Where the magnifier's lens sits: where the drag ended, or up and to the right for a click.
    var loupeCenter: CGPoint {
        hypot(end.x - start.x, end.y - start.y) < 6 ? CGPoint(x: start.x + loupeRadius * 1.6, y: start.y - loupeRadius * 1.6) : end
    }

    var textSize: CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: NSFont.Weight(weight))
        let size = (text as NSString).boundingRect(with: CGSize(width: 2000, height: 4000), options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: font]).size
        return CGSize(width: max(20, ceil(size.width)), height: max(fontSize * 1.2, ceil(size.height)))
    }

    /// Approximate bounds for hit-testing.
    var bounds: CGRect {
        switch tool {
        case .text:
            let s = textSize
            let pad: CGFloat = textStyle == .pill ? fontSize * 0.4 : 0
            return CGRect(x: start.x - pad, y: start.y - pad / 2, width: s.width + pad * 2, height: s.height + pad)
        case .counter:
            let d = counterDiameter
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        case .loupe:
            let r = loupeRadius, c = loupeCenter
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .pen, .highlight:
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        default:
            return rect
        }
    }

    func translated(by d: CGSize) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return copy
    }
}

private extension NSFont.Weight {
    init(_ w: Annotation.TextWeight) {
        switch w {
        case .regular: self = .regular
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        }
    }
}

/// A frame around the finished picture: padding, a background, rounded corners and a shadow.
struct Backdrop: Equatable {
    var padding: CGFloat = 48
    var style = 0
    var radius: CGFloat = 12
    var shadow = true

    static let styles: [[Color]] = [
        [Color(red: 0.98, green: 0.55, blue: 0.24), Color(red: 0.93, green: 0.27, blue: 0.43)],
        [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.71, green: 0.36, blue: 0.95)],
        [Color(red: 0.13, green: 0.76, blue: 0.67), Color(red: 0.16, green: 0.45, blue: 0.85)],
        [Color(red: 0.99, green: 0.82, blue: 0.35), Color(red: 0.98, green: 0.47, blue: 0.29)],
        [Color(red: 0.17, green: 0.18, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.07)],
        [Color(white: 0.96), Color(white: 0.88)],
        [.white],
        [.black],
        [],
    ]

    var fill: AnyShapeStyle {
        let colors = Self.styles[min(style, Self.styles.count - 1)]
        if colors.isEmpty { return AnyShapeStyle(Color.clear) }
        if colors.count == 1 { return AnyShapeStyle(colors[0]) }
        return AnyShapeStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

@MainActor @Observable
final class EditorModel {
    static let palette: [Color] = [
        Color(red: 1, green: 0.27, blue: 0.33), Color(red: 1, green: 0.62, blue: 0.1), Color(red: 1, green: 0.84, blue: 0.1),
        Color(red: 0.2, green: 0.8, blue: 0.45), Color(red: 0.22, green: 0.5, blue: 1), Color(red: 0.62, green: 0.4, blue: 1),
        .white, .black,
    ]

    private(set) var image: NSImage
    let fileURL: URL?

    var annotations: [Annotation] = []
    var draft: Annotation?
    var tool: Annotation.Tool = .arrow {
        didSet {
            selectedID = nil; commitText(); selectingText = false
            lastTool[Annotation.Group.of(tool)] = tool
        }
    }
    /// The tool each toolbar group last had, so its button brings that one back.
    var lastTool: [Annotation.Group: Annotation.Tool] = [:]
    /// Live Text mode: drag across words in the picture to copy just those; drawing pauses meanwhile.
    var selectingText = false { didSet { if selectingText { selectedID = nil; commitText() } else { selectedText = "" } } }
    /// What's selected in Live Text mode.
    var selectedText = ""
    var analyzingText = false

    // Style for new marks; changing one also changes the selected mark.
    var color: Color = EditorModel.palette[0] { didSet { updateSelected { $0.color = color } } }
    var width: CGFloat = 4 { didSet { updateSelected { $0.width = width } } }
    var filled = false { didSet { updateSelected { $0.filled = filled } } }
    var cornerRadius: CGFloat = 3 { didSet { updateSelected { $0.cornerRadius = cornerRadius } } }
    var curved = false { didSet { updateSelected { $0.curved = curved } } }
    var fontSize: CGFloat = 24 { didSet { updateSelected { $0.fontSize = fontSize } } }
    var weight: Annotation.TextWeight = .bold { didSet { updateSelected { $0.weight = weight } } }
    var textStyle: Annotation.TextStyle = .shadow { didSet { updateSelected { $0.textStyle = textStyle } } }
    var strength: CGFloat = 5 { didSet { updateSelected { $0.strength = strength } } }

    var selectedID: UUID? { didSet { adoptSelectedStyle() } }
    var crop: CGRect?
    var backdrop: Backdrop?
    var editingText: (point: CGPoint, text: String)?

    // View state.
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var panning = false
    var hoverPoint: CGPoint?

    private struct State {
        var annotations: [Annotation]
        var crop: CGRect?
        var image: NSImage
        var backdrop: Backdrop?
    }
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var moveOrigin: Annotation?
    @ObservationIgnored private var adopting = false
    @ObservationIgnored private var redactions: [String: NSImage] = [:]
    @ObservationIgnored private var bitmap: NSBitmapImageRep?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var size: CGSize { image.size }
    /// Pixels per point of the picture (2 for a Retina capture).
    var pixelScale: CGFloat { (image.representations.first.map { CGFloat($0.pixelsWide) } ?? size.width) / max(1, size.width) }
    var pixelSize: CGSize { CGSize(width: (size.width * pixelScale).rounded(), height: (size.height * pixelScale).rounded()) }

    init(image: NSImage, fileURL: URL?) {
        self.image = image
        self.fileURL = fileURL
    }

    // MARK: Editing

    private var current: State { State(annotations: annotations, crop: crop, image: image, backdrop: backdrop) }

    private func restore(_ s: State) {
        annotations = s.annotations
        crop = s.crop
        backdrop = s.backdrop
        if s.image !== image { setImage(s.image) }
    }

    func record() {
        undoStack.append(current)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(current)
        restore(last)
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        restore(next)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        record()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard !adopting, let id = selectedID, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        var copy = annotations[i]
        change(&copy)
        guard copy != annotations[i] else { return }
        record()
        annotations[i] = copy
    }

    /// Selecting a mark shows its style in the toolbar.
    private func adoptSelectedStyle() {
        guard let id = selectedID, let a = annotations.first(where: { $0.id == id }) else { return }
        adopting = true
        defer { adopting = false }
        color = a.color; width = a.width; filled = a.filled; cornerRadius = a.cornerRadius; curved = a.curved
        fontSize = a.fontSize; weight = a.weight; textStyle = a.textStyle; strength = a.strength
    }

    private func make(_ tool: Annotation.Tool, _ points: [CGPoint]) -> Annotation {
        Annotation(tool: tool, points: points, color: color, width: width, filled: filled, cornerRadius: cornerRadius, curved: curved,
                   fontSize: fontSize, weight: weight, textStyle: textStyle, strength: strength)
    }

    func dragChanged(from start: CGPoint, to p: CGPoint) {
        switch tool {
        case .select:
            if moveOrigin == nil {
                guard let hit = hitTest(start) else { selectedID = nil; return }
                selectedID = hit.id
                moveOrigin = hit
                record()
            }
            guard let origin = moveOrigin, let i = annotations.firstIndex(where: { $0.id == origin.id }) else { return }
            annotations[i] = origin.translated(by: CGSize(width: p.x - start.x, height: p.y - start.y))
        case .pen, .highlight:
            if draft == nil { draft = make(tool, [start]) }
            draft?.points.append(p)
        case .text, .counter, .picker:
            break
        default:
            var end = p
            if NSEvent.modifierFlags.contains(.shift) { end = constrained(from: start, to: p) }
            draft = make(tool, [start, end])
        }
    }

    func dragEnded(at p: CGPoint, start: CGPoint) {
        defer { moveOrigin = nil }
        let isClick = hypot(p.x - start.x, p.y - start.y) < 3
        switch tool {
        case .select:
            guard isClick else { return }
            let hit = hitTest(p)
            if let hit, hit.tool == .text, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { edit(hit); return }
            selectedID = hit?.id
        case .text:
            commitText()
            if let hit = hitTest(p), hit.tool == .text { edit(hit) } else { editingText = (p, "") }
        case .counter:
            record()
            let next = (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
            var a = make(.counter, [p])
            a.number = next
            annotations.append(a)
        case .picker:
            pickColor(at: p)
        case .loupe:
            record()
            annotations.append(draft ?? make(.loupe, [start, p]))
            draft = nil
        case .crop:
            if let d = draft, d.rect.width > 8, d.rect.height > 8 {
                record()
                crop = d.rect.intersection(CGRect(origin: .zero, size: size))
            }
            draft = nil
        default:
            if var d = draft, !isClick || d.tool == .pen {
                if d.tool == .erase { d.fill = surroundingColor(d.rect) }
                record()
                annotations.append(d)
            }
            draft = nil
        }
    }

    /// Re-opens a placed text for editing, with its own style.
    private func edit(_ hit: Annotation) {
        record()
        annotations.removeAll { $0.id == hit.id }
        selectedID = nil
        adopting = true
        color = hit.color; fontSize = hit.fontSize; weight = hit.weight; textStyle = hit.textStyle
        adopting = false
        editingText = (hit.start, hit.text)
    }

    func commitText() {
        guard let editing = editingText else { return }
        editingText = nil
        let text = editing.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        record()
        var a = make(.text, [editing.point])
        a.text = text
        annotations.append(a)
    }

    func resetCrop() {
        guard crop != nil else { return }
        record()
        crop = nil
    }

    private func hitTest(_ p: CGPoint) -> Annotation? {
        annotations.last { $0.bounds.insetBy(dx: -8, dy: -8).contains(p) }
    }

    private func constrained(from s: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        switch tool {
        case .arrow, .line, .measure, .loupe:
            // Snap to 45° increments.
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + side * (dx < 0 ? -1 : 1), y: s.y + side * (dy < 0 ? -1 : 1))
        }
    }

    // MARK: Pixels

    private func setImage(_ new: NSImage) {
        image = new
        redactions.removeAll()
        bitmap = nil
    }

    /// The picture blurred or pixelated at a strength, made once and reused.
    func redacted(_ tool: Annotation.Tool, strength: CGFloat) -> NSImage {
        let level = Int(strength.rounded())
        let key = "\(tool.rawValue)\(level)"
        if let cached = redactions[key] { return cached }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let input = CIImage(cgImage: cg)
        let output: CIImage?
        if tool == .blur {
            let f = CIFilter.gaussianBlur()
            f.inputImage = input.clampedToExtent()
            f.radius = Float(CGFloat(level) * max(2, CGFloat(cg.width) / 400))
            output = f.outputImage
        } else {
            let f = CIFilter.pixellate()
            f.inputImage = input.clampedToExtent()
            f.scale = Float(CGFloat(level) * max(3, CGFloat(cg.width) / 450))
            f.center = .zero
            output = f.outputImage
        }
        guard let out = output?.cropped(to: input.extent), let result = Self.ci.createCGImage(out, from: input.extent) else { return image }
        let made = NSImage(cgImage: result, size: image.size)
        redactions[key] = made
        return made
    }

    private static let ci = CIContext()

    private func pixelColor(at p: CGPoint) -> NSColor? {
        if bitmap == nil, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { bitmap = NSBitmapImageRep(cgImage: cg) }
        guard let bitmap else { return nil }
        let x = Int(p.x * pixelScale), y = Int(p.y * pixelScale)
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    /// The colour under a point, for the hover readout.
    func hex(at p: CGPoint) -> (String, Color)? {
        guard let c = pixelColor(at: p) else { return nil }
        return (Self.hex(c), Color(nsColor: c))
    }

    private static func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private func pickColor(at p: CGPoint) {
        guard let c = pixelColor(at: p) else { return }
        let hex = Self.hex(c)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        ClipboardStore.shared.markOwnWrite()
        color = Color(nsColor: c)
        Toast.show("Copied %@".loc(hex), symbol: "eyedropper")
    }

    /// The average colour of a thin ring just outside an area — what the eraser fills it with.
    private func surroundingColor(_ r: CGRect) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, n: CGFloat = 0
        let ring = r.insetBy(dx: -3, dy: -3)
        let step = max(1, max(ring.width, ring.height) / 60)
        func sample(_ p: CGPoint) {
            guard let c = pixelColor(at: p) else { return }
            red += c.redComponent; green += c.greenComponent; blue += c.blueComponent; n += 1
        }
        for x in stride(from: ring.minX, through: ring.maxX, by: step) { sample(CGPoint(x: x, y: ring.minY)); sample(CGPoint(x: x, y: ring.maxY)) }
        for y in stride(from: ring.minY, through: ring.maxY, by: step) { sample(CGPoint(x: ring.minX, y: y)); sample(CGPoint(x: ring.maxX, y: y)) }
        guard n > 0 else { return .white }
        return Color(red: red / n, green: green / n, blue: blue / n)
    }

    // MARK: Canvas

    /// Draws the marks into the picture so it can be resized or joined with another.
    private func flattened() -> NSImage {
        commitText()
        return renderMarks()
    }

    func resize(toPixels target: CGSize) {
        let w = max(1, Int(target.width.rounded())), h = max(1, Int(target.height.rounded()))
        guard CGFloat(w) != pixelSize.width || CGFloat(h) != pixelSize.height else { return }
        let flat = flattened()
        guard let cg = flat.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return }
        let scale = pixelScale
        record()
        annotations = []
        crop = nil
        selectedID = nil
        setImage(NSImage(cgImage: out, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale)))
    }

    enum Axis: String, CaseIterable { case horizontal, vertical }
    enum Alignment: String, CaseIterable { case start, center, end }

    var combineAxis: Axis = .horizontal { didSet { recombine() } }
    var combineAlignment: Alignment = .center { didSet { recombine() } }
    var combineGap: CGFloat = 16 { didSet { recombine() } }
    /// The last join, so changing its layout redoes it instead of joining again.
    @ObservationIgnored private var combined: (base: NSImage, other: NSImage, result: NSImage)?
    var canRelayout: Bool { combined?.result === image }

    /// Puts another picture next to this one (right of it, or below).
    func combine(with other: NSImage) {
        let flat = flattened()
        guard let joined = Self.join([flat, other], axis: combineAxis, alignment: combineAlignment, gap: combineGap) else { return }
        record()
        annotations = []
        crop = nil
        selectedID = nil
        setImage(joined)
        combined = (flat, other, joined)
    }

    private func recombine() {
        guard let c = combined, c.result === image,
              let joined = Self.join([c.base, c.other], axis: combineAxis, alignment: combineAlignment, gap: combineGap) else { return }
        setImage(joined)
        combined = (c.base, c.other, joined)
    }

    /// Joins pictures in a row or a column at the sharpest of their resolutions.
    static func join(_ images: [NSImage], axis: Axis, alignment: Alignment, gap: CGFloat, background: NSColor? = nil) -> NSImage? {
        guard !images.isEmpty else { return nil }
        let scale = images.map { img in (img.representations.first.map { CGFloat($0.pixelsWide) } ?? img.size.width) / max(1, img.size.width) }.max() ?? 1
        let sizes = images.map(\.size)
        let total: CGSize = axis == .horizontal
            ? CGSize(width: sizes.map(\.width).reduce(0, +) + gap * CGFloat(images.count - 1), height: sizes.map(\.height).max() ?? 0)
            : CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +) + gap * CGFloat(images.count - 1))
        let pw = Int((total.width * scale).rounded()), ph = Int((total.height * scale).rounded())
        guard pw > 0, ph > 0, let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        if let background { ctx.setFillColor(background.cgColor); ctx.fill(CGRect(origin: .zero, size: total)) }
        var offset: CGFloat = 0
        for (img, s) in zip(images, sizes) {
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            var r = CGRect(origin: .zero, size: s)
            // CoreGraphics counts y from the bottom; place pictures top to bottom.
            if axis == .horizontal {
                r.origin.x = offset
                let slack = total.height - s.height
                r.origin.y = switch alignment { case .start: slack; case .center: slack / 2; case .end: 0 }
                offset += s.width + gap
            } else {
                r.origin.y = total.height - offset - s.height
                let slack = total.width - s.width
                r.origin.x = switch alignment { case .start: 0; case .center: slack / 2; case .end: slack }
                offset += s.height + gap
            }
            ctx.draw(cg, in: r)
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSImage(cgImage: out, size: total)
    }

    func setBackdrop(_ b: Backdrop?) {
        guard b != backdrop else { return }
        record()
        backdrop = b
    }

    /// Changes the backdrop while a slider is being dragged, without an undo step per tick.
    func adjustBackdrop(_ change: (inout Backdrop) -> Void) {
        guard var b = backdrop else { return }
        change(&b)
        backdrop = b
    }

    func setZoom(_ z: CGFloat) { zoom = min(8, max(0.25, z)); if zoom == 1 { pan = .zero } }

    // MARK: Output

    /// The picture with its marks and crop, without the backdrop.
    private func renderMarks() -> NSImage {
        let scale = max(1, pixelScale)
        let renderer = ImageRenderer(content: AnnotatedImage(model: self, scale: 1, exporting: true).frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard var cg = renderer.cgImage else { return image }
        if let crop {
            let px = crop.applying(.init(scaleX: scale, y: scale)).integral
            cg = cg.cropping(to: px) ?? cg
        }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    func render() -> NSImage {
        let marked = renderMarks()
        guard let backdrop else { return marked }
        let pad = backdrop.padding
        let size = CGSize(width: marked.size.width + pad * 2, height: marked.size.height + pad * 2)
        let renderer = ImageRenderer(content: BackdropView(image: marked, backdrop: backdrop).frame(width: size.width, height: size.height))
        renderer.scale = max(1, pixelScale)
        guard let cg = renderer.cgImage else { return marked }
        return NSImage(cgImage: cg, size: size)
    }
}

/// The finished picture on its backdrop, for export and the editor's preview.
struct BackdropView: View {
    let image: NSImage
    let backdrop: Backdrop

    var body: some View {
        ZStack {
            Rectangle().fill(backdrop.fill)
            Image(nsImage: image)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: backdrop.radius, style: .continuous))
                .shadow(color: .black.opacity(backdrop.shadow ? 0.35 : 0), radius: backdrop.padding * 0.35, y: backdrop.padding * 0.12)
                .padding(backdrop.padding)
        }
    }
}
