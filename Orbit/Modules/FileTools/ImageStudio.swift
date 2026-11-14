import AppKit
import CoreImage
import ImageIO
import SwiftUI
import Vision

/// Crop, Background and Redact for a picture dropped on the file ring: one small window per file,
/// saving a new file beside the original.
@MainActor @Observable
final class ImageStudio {
    enum Mode: Equatable {
        case crop, background, redact
        var title: String {
            switch self { case .crop: "Crop Image"; case .background: "Add Background"; case .redact: "Redact" }
        }
    }

    let source: URL
    let mode: Mode
    let image: CGImage
    /// At most ~1400 px: what the window shows and live-renders.
    let preview: CGImage
    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    // Crop, in image pixels with the origin at the top left.
    var crop: CGRect
    var aspect: CropAspect = .free

    var backdrop = StudioBackdrop()
    var backgroundImage: CGImage?

    var redactions: [CGRect] = []
    var redactStyle: RedactStyle = .blur
    var finding = false

    var saving = false
    @ObservationIgnored private var window: NSWindow?
    private static var open: [ImageStudio] = []

    private init(source: URL, mode: Mode, image: CGImage) {
        self.source = source
        self.mode = mode
        self.image = image
        self.preview = Self.downscaled(image, to: 1400)
        self.crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    /// Decodes off the main thread (a big photo takes a moment), then opens the window.
    static func open(_ url: URL, mode: Mode) {
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) { try FileEngine.uprightImage(at: url) }.value
                let studio = ImageStudio(source: url, mode: mode, image: image)
                open.append(studio)
                studio.show()
            } catch {
                Toast.show("Couldn’t open the image", symbol: "exclamationmark.triangle", detail: error.localizedDescription)
            }
        }
    }

    private func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = mode.title.loc
        window.subtitle = source.lastPathComponent
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 560)
        let host = NSHostingView(rootView: ImageStudioView(studio: self).orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = []
        window.contentView = FloatingPanel.container(for: host)
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Self.open.removeAll { $0 === self } }
        }
        self.window = window
        window.bringToFront()
    }

    func close() { window?.close() }

    // MARK: Crop

    func setAspect(_ next: CropAspect) {
        aspect = next
        guard let ratio = next.ratio(original: pixelSize) else { return }
        // The biggest rectangle of that shape that fits the picture, centered where the crop was.
        var size = CGSize(width: pixelSize.width, height: pixelSize.width / ratio)
        if size.height > pixelSize.height { size = CGSize(width: pixelSize.height * ratio, height: pixelSize.height) }
        crop = clamp(CGRect(x: crop.midX - size.width / 2, y: crop.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// Typing a width or height keeps the center and, with a fixed ratio, the shape.
    func setCropSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        var size = crop.size
        let ratio = aspect.ratio(original: pixelSize)
        if let width { size.width = width; if let ratio { size.height = width / ratio } }
        if let height { size.height = height; if let ratio { size.width = height * ratio } }
        // Shrink both sides together, so a fixed ratio survives hitting the picture's edge.
        let fit = min(1, pixelSize.width / max(size.width, 1), pixelSize.height / max(size.height, 1))
        size = CGSize(width: max(16, (size.width * fit).rounded()), height: max(16, (size.height * fit).rounded()))
        crop = clamp(CGRect(x: crop.midX - size.width / 2, y: crop.midY - size.height / 2, width: size.width, height: size.height))
    }

    func clamp(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        r.size.width = min(max(16, r.width), pixelSize.width)
        r.size.height = min(max(16, r.height), pixelSize.height)
        r.origin.x = min(max(0, r.minX), pixelSize.width - r.width)
        r.origin.y = min(max(0, r.minY), pixelSize.height - r.height)
        return CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
    }

    func reset() {
        switch mode {
        case .crop: aspect = .free; crop = CGRect(origin: .zero, size: pixelSize)
        case .background: backdrop = StudioBackdrop(); backgroundImage = nil
        case .redact: redactions = []
        }
    }

    // MARK: Redact

    /// Text and faces found on-device, added as boxes to cover.
    func find(_ what: RedactTarget) {
        guard !finding else { return }
        finding = true
        let image = self.image
        Task.detached(priority: .userInitiated) {
            let request: VNImageBasedRequest = what == .text ? VNRecognizeTextRequest() : VNDetectFaceRectanglesRequest()
            (request as? VNRecognizeTextRequest)?.recognitionLevel = .fast
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let boxes = (request.results as? [VNDetectedObjectObservation] ?? []).map(\.boundingBox)
            await MainActor.run {
                let size = self.pixelSize
                let rects = boxes.map { box in
                    // Vision boxes are normalized with the origin at the bottom left; pad them a little.
                    let r = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                   width: box.width * size.width, height: box.height * size.height)
                    return self.clamp(r.insetBy(dx: -r.height * 0.15, dy: -r.height * 0.15))
                }
                self.redactions.append(contentsOf: rects.filter { new in !self.redactions.contains(new) })
                self.finding = false
                if rects.isEmpty { Toast.show(what == .text ? "No text found" : "No faces found", symbol: "magnifyingglass") }
            }
        }
    }

    // MARK: Output

    @ObservationIgnored private var previewCache: (key: String, image: CGImage?)?

    /// The live preview, rendered again only when a setting changed (not on every view update).
    func renderedPreview() -> CGImage? {
        let key = "\(backdrop)|\(backgroundImage.map { ObjectIdentifier($0) }.debugDescription)|\(redactions)|\(redactStyle)"
        if let cached = previewCache, cached.key == key { return cached.image }
        let image = render(preview: true)
        previewCache = (key, image)
        return image
    }

    func render(preview: Bool) -> CGImage? {
        let base = preview ? self.preview : image
        let k = CGFloat(base.width) / pixelSize.width
        switch mode {
        case .crop:
            return base
        case .background:
            return StudioRenderer.background(base, backdrop: backdrop, image: backgroundImage)
        case .redact:
            let rects = redactions.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k) }
            return StudioRenderer.redact(base, rects: rects, style: redactStyle)
        }
    }

    func save() {
        guard !saving else { return }
        saving = true
        let image = self.image, source = self.source, mode = self.mode
        let crop = self.crop, backdrop = self.backdrop, background = backgroundImage
        let rects = redactions, style = redactStyle
        Task.detached(priority: .userInitiated) {
            do {
                let output: URL
                switch mode {
                case .crop:
                    guard let cropped = image.cropping(to: crop) else { throw FileToolError.encoding }
                    output = try Self.write(cropped, like: source, "%@ Cropped")
                case .background:
                    guard let framed = StudioRenderer.background(image, backdrop: backdrop, image: background) else { throw FileToolError.encoding }
                    // PNG: soft shadows and gradients without JPEG blocks.
                    output = try FileOutput.write(try FileEngine.encode(framed, as: .png), beside: source, "%@ With Background", ext: "png")
                case .redact:
                    guard let covered = StudioRenderer.redact(image, rects: rects, style: style) else { throw FileToolError.encoding }
                    output = try Self.write(covered, like: source, "%@ Redacted")
                }
                await MainActor.run {
                    self.saving = false
                    self.close()
                    FileTools.shared.announce([output])
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    Toast.show("Couldn’t save the image", symbol: "exclamationmark.triangle", detail: error.localizedDescription)
                }
            }
        }
    }

    /// In the original's format where macOS can write it (a JPEG stays a JPEG), PNG otherwise.
    nonisolated static func write(_ image: CGImage, like source: URL, _ pattern: String) throws -> URL {
        let same = FileFormat.allCases.first { $0.matches(source) && $0.canWriteImage }
        let data = try FileEngine.encode(image, as: same ?? .png, quality: 0.95)
        let ext = same != nil && !source.pathExtension.isEmpty ? source.pathExtension : (same ?? .png).ext
        return try FileOutput.write(data, beside: source, pattern, ext: ext)
    }

    nonisolated static func downscaled(_ image: CGImage, to longest: CGFloat) -> CGImage {
        let scale = longest / CGFloat(max(image.width, image.height))
        guard scale < 1 else { return image }
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

enum RedactTarget { case text, faces }

enum RedactStyle: String, CaseIterable {
    case blur, pixelate, black
    var title: String {
        switch self { case .blur: "Blur"; case .pixelate: "Pixelate"; case .black: "Black" }
    }
}

enum CropAspect: String, CaseIterable {
    case free, original, square, wide, tall, standard, portrait
    var title: String {
        switch self {
        case .free: "Freeform"; case .original: "Original"; case .square: "1:1"; case .wide: "16:9"
        case .tall: "9:16"; case .standard: "4:3"; case .portrait: "3:4"
        }
    }
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: original.width / original.height
        case .square: 1
        case .wide: 16 / 9
        case .tall: 9 / 16
        case .standard: 4 / 3
        case .portrait: 3 / 4
        }
    }
}

/// Sizes are fractions of the picture, so a preview and the full-size result look the same.
struct StudioBackdrop: Equatable {
    var fill = 0
    /// Of the picture's longer side.
    var padding: CGFloat = 0.08
    /// Of the picture's shorter side.
    var corners: CGFloat = 0.03
    var shadow: CGFloat = 0.5
    var ratio: BackdropRatio = .auto

    static let gradients: [[UInt32]] = [
        [0xFF8A3D, 0xEE4570], [0xFDD15A, 0xF7782F], [0x5C6BFA, 0xB55CF2], [0x22C2AB, 0x2973D9],
        [0xF9A8D4, 0xA78BFA], [0x2B2E38, 0x0D0D12], [0xF5F5F5, 0xE0E0E0],
    ]
    static let solids: [UInt32] = [0xFFFFFF, 0xF2C94C, 0x6FCF57, 0x27AE60, 0x2BB5A8, 0x56CCF2, 0x2F6BFF, 0x1F2430, 0x000000]
    static var swatchCount: Int { gradients.count + solids.count }

    var colors: [UInt32] {
        fill < Self.gradients.count ? Self.gradients[fill] : [Self.solids[min(fill - Self.gradients.count, Self.solids.count - 1)]]
    }
}

enum BackdropRatio: String, CaseIterable {
    case auto, square, wide, portrait, story
    var title: String {
        switch self { case .auto: "Auto"; case .square: "1:1"; case .wide: "16:9"; case .portrait: "4:5"; case .story: "9:16" }
    }
    var value: CGFloat? {
        switch self { case .auto: nil; case .square: 1; case .wide: 16 / 9; case .portrait: 4 / 5; case .story: 9 / 16 }
    }
}

enum StudioRenderer {
    /// The picture's own RGB space (Display P3 stays P3); sRGB for anything else.
    static func space(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The canvas grows to the chosen ratio; the picture is never stretched or cut.
    static func canvas(for size: CGSize, backdrop: StudioBackdrop) -> CGSize {
        let pad = (max(size.width, size.height) * backdrop.padding).rounded()
        var canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        if let ratio = backdrop.ratio.value {
            if canvas.width / canvas.height < ratio { canvas.width = (canvas.height * ratio).rounded() }
            else { canvas.height = (canvas.width / ratio).rounded() }
        }
        return canvas
    }

    static func background(_ image: CGImage, backdrop: StudioBackdrop, image fillImage: CGImage?) -> CGImage? {
        var size = CGSize(width: image.width, height: image.height)
        var canvas = canvas(for: size, backdrop: backdrop)
        // A 48 MP photo with wide padding and a tall ratio would need gigabytes: cap the canvas at 100 MP.
        let k = min(1, sqrt(100_000_000 / (canvas.width * canvas.height)))
        if k < 1 {
            size = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
            canvas = CGSize(width: (canvas.width * k).rounded(), height: (canvas.height * k).rounded())
        }
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space(of: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: canvas)
        context.interpolationQuality = .high
        if let fillImage {
            // Fill the canvas, cut what overflows.
            let k = max(canvas.width / CGFloat(fillImage.width), canvas.height / CGFloat(fillImage.height))
            let w = CGFloat(fillImage.width) * k, h = CGFloat(fillImage.height) * k
            context.draw(fillImage, in: CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
        } else {
            let colors = backdrop.colors.map(color)
            if colors.count == 1 {
                context.setFillColor(colors[0])
                context.fill(full)
            } else if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
            }
        }
        let frame = CGRect(x: ((canvas.width - size.width) / 2).rounded(), y: ((canvas.height - size.height) / 2).rounded(),
                           width: size.width, height: size.height)
        let radius = min(size.width, size.height) * backdrop.corners
        let path = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if backdrop.shadow > 0 {
            let blur = max(size.width, size.height) * 0.05 * backdrop.shadow
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                              color: CGColor(gray: 0, alpha: 0.45 * backdrop.shadow))
            context.addPath(path)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: frame)
        context.restoreGState()
        return context.makeImage()
    }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// `rects` are in pixels with the origin at the top left.
    static func redact(_ image: CGImage, rects: [CGRect], style: RedactStyle) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space(of: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: size)
        context.draw(image, in: full)
        guard !rects.isEmpty else { return context.makeImage() }
        let flipped = rects.map { CGRect(x: $0.minX, y: size.height - $0.maxY, width: $0.width, height: $0.height) }
        var cover: CGImage?
        let input = CIImage(cgImage: image)
        switch style {
        case .black:
            break
        case .blur:
            // Strong enough that text can't be read back, relative to the picture.
            let radius = max(12, max(size.width, size.height) * 0.02)
            cover = ci.createCGImage(input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent), from: input.extent)
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate", parameters: [kCIInputImageKey: input.clampedToExtent(),
                                                                     kCIInputScaleKey: max(10, max(size.width, size.height) / 60),
                                                                     kCIInputCenterKey: CIVector(x: 0, y: 0)])
            cover = filter?.outputImage.flatMap { ci.createCGImage($0.cropped(to: input.extent), from: input.extent) }
        }
        for rect in flipped {
            context.saveGState()
            context.clip(to: rect)
            if let cover { context.draw(cover, in: full) } else { context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(rect) }
            context.restoreGState()
        }
        return context.makeImage()
    }
}

// MARK: - Window

private struct ImageStudioView: View {
    @Bindable var studio: ImageStudio

    var body: some View {
        VStack(spacing: 0) {
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 40)
                .padding(.bottom, 16)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            controls.padding(20)
            HStack {
                Button("Reset") { studio.reset() }.buttonStyle(PillButtonStyle(prominent: false))
                Spacer()
                Button { studio.save() } label: {
                    if studio.saving { ProgressView().controlSize(.small) } else { Text(primaryTitle.loc) }
                }
                .buttonStyle(AccentPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(studio.saving || (studio.mode == .redact && studio.redactions.isEmpty))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Palette.canvas)
        .ignoresSafeArea()
    }

    private var primaryTitle: String {
        switch studio.mode { case .crop: "Apply"; case .background: "Save with Background"; case .redact: "Save" }
    }

    @ViewBuilder private var canvas: some View {
        switch studio.mode {
        case .crop: CropCanvas(studio: studio)
        case .background: BackgroundPreview(studio: studio)
        case .redact: RedactCanvas(studio: studio)
        }
    }

    @ViewBuilder private var controls: some View {
        switch studio.mode {
        case .crop: cropControls
        case .background: backgroundControls
        case .redact: redactControls
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Aspect ratio") {
                ChipPicker(selection: Binding(get: { studio.aspect }, set: { studio.setAspect($0) }),
                           options: CropAspect.allCases.map { ($0, $0.title) })
            }
            row("Size") {
                HStack(spacing: 6) {
                    Text("W").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    PixelField(value: studio.crop.width) { studio.setCropSize(width: $0) }
                    Text("H").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    PixelField(value: studio.crop.height) { studio.setCropSize(height: $0) }
                    Text("px").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Background") { BackdropSwatches(studio: studio) }
            row("Padding") { slider(\.padding, 0...0.3, px: max(studio.pixelSize.width, studio.pixelSize.height)) }
            row("Corners") { slider(\.corners, 0...0.15, px: min(studio.pixelSize.width, studio.pixelSize.height)) }
            row("Shadow") { slider(\.shadow, 0...1, px: nil) }
            row("Ratio") {
                ChipPicker(selection: $studio.backdrop.ratio, options: BackdropRatio.allCases.map { ($0, $0.title) })
            }
        }
    }

    private var redactControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Style") { ChipPicker(selection: $studio.redactStyle, options: RedactStyle.allCases.map { ($0, $0.title) }) }
            row("Find") {
                HStack(spacing: 8) {
                    Button("Text") { studio.find(.text) }.buttonStyle(PillButtonStyle(prominent: false))
                    Button("Faces") { studio.find(.faces) }.buttonStyle(PillButtonStyle(prominent: false))
                    if studio.finding { ProgressView().controlSize(.small) }
                }
            }
            Text("Drag over the picture to cover an area. Click a box to remove it.")
                .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func slider(_ key: WritableKeyPath<StudioBackdrop, CGFloat>, _ range: ClosedRange<CGFloat>, px base: CGFloat?) -> some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { studio.backdrop[keyPath: key] }, set: { studio.backdrop[keyPath: key] = $0 }), in: range)
            Text(base.map { "\(Int(($0 * studio.backdrop[keyPath: key]).rounded())) px" } ?? "\(Int((studio.backdrop[keyPath: key] * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

/// The accent is for the one action that saves.
struct AccentPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 16).frame(height: 32)
            .foregroundStyle(.white)
            .background(Capsule().fill(Palette.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct PixelField: View {
    let value: CGFloat
    let commit: (CGFloat) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12).monospacedDigit())
            .frame(width: 70)
            .focused($focused)
            .onAppear { text = "\(Int(value))" }
            .onChange(of: value) { if !focused { text = "\(Int(value))" } }
            .onSubmit { apply() }
            .onChange(of: focused) { if !focused { apply() } }
    }

    private func apply() {
        if let number = Double(text.filter(\.isNumber)), number > 0 { commit(CGFloat(number)) }
        text = "\(Int(value))"
    }
}

/// Fits a picture of `size` into `area`, centered.
private func fitted(_ size: CGSize, in area: CGSize) -> CGRect {
    let k = min(area.width / size.width, area.height / size.height)
    let w = size.width * k, h = size.height * k
    return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
}

private struct CropCanvas: View {
    @Bindable var studio: ImageStudio
    @State private var start: CGRect?

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    var body: some View {
        GeometryReader { geo in
            let shown = fitted(studio.pixelSize, in: geo.size)
            let k = shown.width / studio.pixelSize.width
            let crop = CGRect(x: shown.minX + studio.crop.minX * k, y: shown.minY + studio.crop.minY * k,
                              width: studio.crop.width * k, height: studio.crop.height * k)
            ZStack(alignment: .topLeading) {
                Image(decorative: studio.preview, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: shown.minX, y: shown.minY)
                // Everything outside the crop is dimmed.
                Path { p in
                    p.addRect(shown)
                    p.addRect(crop)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .background(Color.white.opacity(0.001))
                    .frame(width: crop.width, height: crop.height)
                    .offset(x: crop.minX, y: crop.minY)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let from = start ?? studio.crop
                            start = from
                            studio.crop = studio.clamp(from.offsetBy(dx: value.translation.width / k, dy: value.translation.height / k))
                        }
                        .onEnded { _ in start = nil })
                ForEach(Handle.allCases, id: \.self) { handle in
                    let p = point(handle, in: crop)
                    Circle()
                        .fill(Palette.accent)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .offset(x: p.x - 14, y: p.y - 14)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let from = start ?? studio.crop
                                start = from
                                studio.crop = resized(from, handle, by: CGSize(width: value.translation.width / k, height: value.translation.height / k))
                            }
                            .onEnded { _ in start = nil })
                }
            }
        }
    }

    private func point(_ handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Moves the dragged edges; with a fixed ratio the other side follows.
    private func resized(_ r: CGRect, _ handle: Handle, by d: CGSize) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        let bounds = studio.pixelSize
        switch handle {
        case .topLeft: minX += d.width; minY += d.height
        case .top: minY += d.height
        case .topRight: maxX += d.width; minY += d.height
        case .right: maxX += d.width
        case .bottomRight: maxX += d.width; maxY += d.height
        case .bottom: maxY += d.height
        case .bottomLeft: minX += d.width; maxY += d.height
        case .left: minX += d.width
        }
        minX = max(0, min(minX, maxX - 16)); maxX = min(bounds.width, max(maxX, minX + 16))
        minY = max(0, min(minY, maxY - 16)); maxY = min(bounds.height, max(maxY, minY + 16))
        var out = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio = studio.aspect.ratio(original: bounds) else { return studio.clamp(out) }
        switch handle {
        case .top, .bottom:
            let w = min(out.height * ratio, bounds.width)
            out = CGRect(x: r.midX - w / 2, y: out.minY, width: w, height: w / ratio)
        default:
            let h = min(out.width / ratio, bounds.height)
            let y = [.topLeft, .topRight].contains(handle) ? out.maxY - h : (handle == .left || handle == .right ? r.midY - h / 2 : out.minY)
            out = CGRect(x: out.minX, y: y, width: h * ratio, height: h)
            if [.topLeft, .bottomLeft, .left].contains(handle) { out.origin.x = r.maxX - out.width }
        }
        return studio.clamp(out)
    }
}

private struct BackgroundPreview: View {
    let studio: ImageStudio

    var body: some View {
        GeometryReader { geo in
            if let image = studio.renderedPreview() {
                let shown = fitted(CGSize(width: image.width, height: image.height), in: geo.size)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    .offset(x: shown.minX, y: shown.minY)
            }
        }
    }
}

private struct BackdropSwatches: View {
    @Bindable var studio: ImageStudio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(StudioBackdrop.gradients.indices, id: \.self) { swatch($0) }
                Button(action: chooseImage) {
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.raised))
                        .overlay(ring(on: studio.backgroundImage != nil))
                }
                .buttonStyle(.plain)
                .help("Use a picture as the background".loc)
            }
            HStack(spacing: 6) {
                ForEach(StudioBackdrop.solids.indices, id: \.self) { swatch(StudioBackdrop.gradients.count + $0) }
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        let colors = index < StudioBackdrop.gradients.count ? StudioBackdrop.gradients[index]
            : [StudioBackdrop.solids[index - StudioBackdrop.gradients.count]]
        return Button { studio.backgroundImage = nil; studio.backdrop.fill = index } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: colors.map { Color(cgColor: StudioRenderer.color($0)) },
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .overlay(ring(on: studio.backgroundImage == nil && studio.backdrop.fill == index))
        }
        .buttonStyle(.plain)
    }

    private func ring(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.accent, lineWidth: 2).padding(-3).opacity(on ? 1 : 0)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url, let image = try? FileEngine.uprightImage(at: url) else { return }
            studio.backgroundImage = ImageStudio.downscaled(image, to: 4000)
        }
    }
}

private struct RedactCanvas: View {
    @Bindable var studio: ImageStudio
    @State private var drawing: CGRect?

    var body: some View {
        GeometryReader { geo in
            let shown = fitted(studio.pixelSize, in: geo.size)
            let k = shown.width / studio.pixelSize.width
            ZStack(alignment: .topLeading) {
                if let image = studio.renderedPreview() {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: shown.minX, y: shown.minY)
                }
                ForEach(Array(studio.redactions.enumerated()), id: \.offset) { index, rect in
                    Rectangle()
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                        .background(Color.white.opacity(0.001))
                        .frame(width: rect.width * k, height: rect.height * k)
                        .offset(x: shown.minX + rect.minX * k, y: shown.minY + rect.minY * k)
                        .onTapGesture { studio.redactions.remove(at: index) }
                        .help("Click to remove".loc)
                }
                if let drawing {
                    Rectangle()
                        .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: drawing.width, height: drawing.height)
                        .offset(x: drawing.minX, y: drawing.minY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { value in
                    drawing = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                                     width: abs(value.translation.width), height: abs(value.translation.height))
                        .intersection(shown)
                }
                .onEnded { _ in
                    if let r = drawing, r.width > 3, r.height > 3 {
                        studio.redactions.append(studio.clamp(CGRect(x: (r.minX - shown.minX) / k, y: (r.minY - shown.minY) / k,
                                                                     width: r.width / k, height: r.height / k)))
                    }
                    drawing = nil
                })
        }
    }
}
