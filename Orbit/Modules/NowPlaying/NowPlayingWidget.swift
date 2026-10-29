import SwiftUI

/// What a widget shows: the live song, or a sample for previews.
struct WidgetContent {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var palette: ArtworkPalette
    var playing: Bool
    var liked: Bool
    var duration: Double
    var elapsed: (Date) -> Double
    var appIcon: NSImage?
    var appName: String?
    var generation: Int
    var live: Bool

    @MainActor static func current() -> WidgetContent? {
        let np = NowPlaying.shared
        guard let t = np.track else { return nil }
        return WidgetContent(title: t.title, artist: t.artist, album: t.album, artwork: np.artwork, palette: np.palette,
                             playing: np.playing, liked: np.liked, duration: t.duration, elapsed: { np.elapsed(at: $0) },
                             appIcon: np.appIcon, appName: t.appName, generation: np.generation, live: true)
    }

    /// A made-up song with a generated cover, for when nothing is playing.
    @MainActor static let sample: WidgetContent = {
        let art = sampleArtwork
        let start = Date()
        return WidgetContent(title: "Night Drive", artist: "Orbit", album: "Afterglow", artwork: art,
                             palette: ArtworkPalette(art), playing: true, liked: true, duration: 214,
                             elapsed: { 62 + $0.timeIntervalSince(start).truncatingRemainder(dividingBy: 150) },
                             appIcon: nil, appName: "Music", generation: 0, live: false)
    }()

    @MainActor static let sampleArtwork: NSImage = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { r in
        let g = NSGradient(colors: [NSColor(srgbRed: 1, green: 0.45, blue: 0.22, alpha: 1),
                                    NSColor(srgbRed: 0.55, green: 0.12, blue: 0.42, alpha: 1),
                                    NSColor(srgbRed: 0.08, green: 0.06, blue: 0.2, alpha: 1)])
        g?.draw(in: r, angle: -60)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: 70, dy: 110).offsetBy(dx: 0, dy: -10))
        ring.lineWidth = 6
        ring.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.midX - 46, y: r.midY - 56, width: 92, height: 92)).fill()
        return true
    }
}

/// The widget itself, drawn the same on the desktop, in the notch preview and on the settings page.
struct NowPlayingWidgetView: View {
    let style: WidgetStyle
    let content: WidgetContent
    /// Hover state comes from outside so the window can also track it.
    var hovering = false
    var onDrag: ((DragGesture.Value?) -> Void)?

    @State private var scrub: Double?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: style.layout == .pill ? 999 : style.cornerRadius, style: .continuous) }

    private var ink: Color {
        switch style.colors {
        case .artwork, .light: .white
        case .dark: .black
        }
    }

    private var accent: Color {
        switch style.colors {
        case .artwork: content.palette.accent
        case .light: .white
        case .dark: .black
        }
    }

    private var controlsVisible: Bool { style.showControls && (!style.controlsOnHover || hovering) }

    var body: some View {
        card
            .animation(style.animate ? .spring(duration: 0.45, bounce: 0.12) : nil, value: content.generation)
            .animation(.easeOut(duration: 0.18), value: hovering)
    }

    @ViewBuilder private var card: some View {
        let body = Group {
            switch style.layout {
            case .horizontal: horizontal
            case .vertical: vertical
            case .artwork: artworkOnly
            case .pill: pill
            }
        }
        body
            .padding(padding)
            .background { background }
            .clipShape(shape)
            .overlay {
                if style.background != .none {
                    shape.strokeBorder(.white.opacity(style.colors == .dark ? 0.0 : 0.1), lineWidth: 0.5)
                }
            }
            .contentShape(shape)
            .shadow(color: .black.opacity(style.background == .none ? 0 : 0.5 * style.shadow), radius: 26 * style.shadow, y: 12 * style.shadow)
            .gesture(dragGesture)
    }

    private var padding: CGFloat {
        switch style.layout {
        case .artwork: 0
        case .pill: 6
        default: style.background == .none ? 0 : max(10, min(18, style.artworkSize * 0.14))
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { onDrag?($0) }
            .onEnded { _ in onDrag?(nil) }
    }

    // MARK: Background

    @ViewBuilder private var background: some View {
        switch style.background {
        case .tinted:
            ZStack {
                content.palette.background
                if let art = content.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .scaleEffect(1.6).blur(radius: 44).saturation(1.3).opacity(0.55)
                        .id(content.generation).transition(.opacity)
                }
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            }
            .opacity(style.backgroundOpacity)
        case .glass:
            Color.clear.glassEffect(.regular.tint(content.palette.background.opacity(style.colors == .artwork ? 0.35 : 0)), in: shape)
        case .solid:
            (style.colors == .dark ? Color.white : style.colors == .light ? Color(white: 0.06) : content.palette.background)
                .opacity(style.backgroundOpacity)
        case .none:
            Color.clear
        }
    }

    // MARK: Layouts

    private var horizontal: some View {
        HStack(spacing: max(10, style.artworkSize * 0.14)) {
            artwork(style.artworkSize)
            VStack(alignment: style.horizontalAlignment, spacing: 0) {
                texts
                Spacer(minLength: 6)
                footer(controlSize: max(13, min(20, style.artworkSize * 0.17)))
            }
            .frame(width: style.textWidth, height: style.artworkSize, alignment: Alignment(horizontal: style.horizontalAlignment, vertical: .center))
        }
    }

    private var vertical: some View {
        VStack(alignment: style.horizontalAlignment, spacing: 12) {
            artwork(style.artworkSize)
            VStack(alignment: style.horizontalAlignment, spacing: 8) {
                texts
                footer(controlSize: 18)
            }
            .frame(width: max(style.artworkSize, style.textWidth), alignment: Alignment(horizontal: style.horizontalAlignment, vertical: .center))
        }
    }

    private var artworkOnly: some View {
        artwork(style.artworkSize, corner: style.cornerRadius)
            .overlay(alignment: .bottom) {
                if hovering {
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if style.showTitle {
                            Text(content.title).font(style.font(13, .semibold)).lineLimit(1)
                        }
                        if style.showControls {
                            HStack(spacing: 4) {
                                control("backward.fill", 13, light: true) { NowPlaying.shared.previous() }
                                control(content.playing ? "pause.fill" : "play.fill", 18, light: true) { NowPlaying.shared.togglePlayPause() }
                                control("forward.fill", 13, light: true) { NowPlaying.shared.next() }
                            }
                        }
                        if style.showProgress { bar(height: 3) }
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(width: style.artworkSize, height: style.artworkSize)
                    .background(LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.82), location: 1)], startPoint: .top, endPoint: .bottom))
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            artwork(style.artworkSize, corner: style.artworkSize / 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.title).font(style.font(style.titleSize, style.titleWeight)).lineLimit(1)
                    .foregroundStyle(ink)
                if style.showArtist, !content.artist.isEmpty {
                    Text(content.artist).font(style.font(style.titleSize - 2, .regular)).lineLimit(1).foregroundStyle(ink.opacity(0.6))
                }
            }
            .frame(width: style.textWidth, alignment: .leading)
            .id(content.generation).transition(.push(from: .bottom).combined(with: .opacity))
            if style.showControls {
                HStack(spacing: 2) {
                    control("backward.fill", 12) { NowPlaying.shared.previous() }.opacity(hovering ? 1 : 0)
                    control(content.playing ? "pause.fill" : "play.fill", 15) { NowPlaying.shared.togglePlayPause() }
                    control("forward.fill", 12) { NowPlaying.shared.next() }
                }
                .padding(.trailing, 4)
            } else {
                Equalizer(playing: content.playing, color: accent).frame(width: 16, height: 14).padding(.trailing, 8)
            }
        }
    }

    // MARK: Pieces

    private func artwork(_ side: Double, corner: Double? = nil) -> some View {
        ZStack {
            if let art = content.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: side * 0.36, weight: .medium)).foregroundStyle(.white.opacity(0.5)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner ?? style.artworkRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner ?? style.artworkRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(style.background == .none ? 0.45 * style.shadow : 0.25), radius: style.background == .none ? 16 * style.shadow : 6, y: 4)
        .id(content.generation)
        .transition(.blurReplace.combined(with: .scale(0.94)))
        .overlay(alignment: .bottomTrailing) {
            if style.showSource, let icon = content.appIcon, style.layout != .pill {
                Image(nsImage: icon).resizable().frame(width: max(16, side * 0.22), height: max(16, side * 0.22))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .offset(x: 5, y: 5)
            }
        }
        .scaleEffect(content.playing || !content.live ? 1 : 0.96)
        .animation(.spring(duration: 0.4, bounce: 0.25), value: content.playing)
    }

    private var texts: some View {
        VStack(alignment: style.horizontalAlignment, spacing: 2) {
            if style.showTitle {
                Text(content.title)
                    .font(style.font(style.titleSize, style.titleWeight))
                    .foregroundStyle(ink)
                    .lineLimit(style.layout == .vertical ? 2 : 1)
            }
            if style.showArtist, !content.artist.isEmpty {
                Text(content.artist)
                    .font(style.font(style.titleSize - 2, .regular))
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(1)
            }
            if style.showAlbum, !content.album.isEmpty {
                Text(content.album)
                    .font(style.font(style.titleSize - 3, .regular))
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(style.textAlignment)
        .shadow(color: style.background == .none ? .black.opacity(0.55 * style.shadow + 0.2) : .clear, radius: 6, y: 1)
        .id(content.generation)
        .transition(.asymmetric(insertion: .push(from: .bottom).combined(with: .opacity), removal: .opacity))
    }

    /// Progress, then one row that shows the times — or, under the pointer, the controls.
    @ViewBuilder private func footer(controlSize: Double) -> some View {
        VStack(alignment: style.horizontalAlignment, spacing: 4) {
            if style.showProgress { bar(height: 4) }
            let showTimes = style.showProgress && content.duration > 0
            ZStack {
                if showTimes { times.opacity(style.showControls && controlsVisible ? 0 : 1) }
                if style.showControls { controls(size: controlSize).opacity(controlsVisible ? 1 : 0) }
            }
        }
    }

    private func bar(height: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1, paused: !content.playing)) { ctx in
            let duration = content.duration
            let elapsed = scrub.map { $0 * duration } ?? content.elapsed(ctx.date)
            let fraction = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.18))
                    Capsule().fill(accent).frame(width: max(height, geo.size.width * fraction))
                }
                .frame(height: scrub == nil ? height : height + 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard content.live, duration > 0 else { return }
                        scrub = min(1, max(0, v.location.x / geo.size.width))
                    }
                    .onEnded { _ in
                        if let s = scrub, content.live { NowPlaying.shared.seek(to: s * duration) }
                        scrub = nil
                    })
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.12), value: scrub == nil)
        }
    }

    private var times: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !content.playing)) { ctx in
            let duration = content.duration
            let elapsed = scrub.map { $0 * duration } ?? content.elapsed(ctx.date)
            HStack {
                Text(Self.time(elapsed))
                Spacer()
                Text("-" + Self.time(max(0, duration - elapsed)))
            }
            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(ink.opacity(0.55))
            .frame(maxWidth: .infinity)
        }
    }

    private func controls(size: Double) -> some View {
        let like = style.showLike
            ? control(content.liked ? "heart.fill" : "heart", size * 0.8, tint: content.liked ? accent : nil) { NowPlaying.shared.toggleLike() }
            : nil
        let transport = HStack(spacing: size * 0.45) {
            control("backward.fill", size * 0.8) { NowPlaying.shared.previous() }
            control(content.playing ? "pause.fill" : "play.fill", size * 1.15) { NowPlaying.shared.togglePlayPause() }
            control("forward.fill", size * 0.8) { NowPlaying.shared.next() }
        }
        return HStack(spacing: size * 0.45) {
            switch style.align {
            case .leading:
                transport
                Spacer(minLength: 0)
                like
            case .center:
                Spacer(minLength: 0)
                transport
                like
                Spacer(minLength: 0)
            case .trailing:
                like
                Spacer(minLength: 0)
                transport
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: style.background == .none ? .black.opacity(0.5) : .clear, radius: 5, y: 1)
    }

    private func control(_ symbol: String, _ size: Double, tint: Color? = nil, light: Bool = false, action: @escaping () -> Void) -> some View {
        WidgetControl(symbol: symbol, size: size, color: tint ?? (light ? .white : ink), enabled: content.live, action: action)
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// A glyph button that swells a little under the pointer and pops when pressed.
struct WidgetControl: View {
    let symbol: String
    let size: Double
    let color: Color
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    @State private var bump = 0

    var body: some View {
        Button {
            bump += 1
            if enabled { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: bump)
                .frame(width: size * 1.75, height: size * 1.6)
                .background(Circle().fill(color.opacity(hover ? 0.14 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Bars dancing while music plays. Core Animation moves them on its own, so a playing song costs
/// Orbit nothing per frame (a SwiftUI timeline redrew the whole window around it 20 times a second).
struct Equalizer: NSViewRepresentable {
    let playing: Bool
    let color: Color

    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.update(playing: playing, color: NSColor(color))
    }
}

final class EqualizerView: NSView {
    private let bars = (0..<4).map { _ in CALayer() }
    private var playing = false
    private var color = NSColor.white

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bars.forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func update(playing: Bool, color: NSColor) {
        let changed = playing != self.playing
        self.playing = playing
        self.color = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bars.forEach { $0.backgroundColor = color.cgColor }
        }
        if changed { animate() }
    }

    private var laidOut = CGSize.zero

    override func layout() {
        super.layout()
        guard bounds.size != laidOut else { return }
        laidOut = bounds.size
        let n = CGFloat(bars.count), gap: CGFloat = 2
        let w = max(1, (bounds.width - gap * (n - 1)) / n)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(i) * (w + gap) + w / 2, y: 0)
            bar.cornerRadius = w / 2
        }
        CATransaction.commit()
        animate()
    }

    private func animate() {
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            guard playing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                bar.transform = CATransform3DMakeScale(1, 0.22, 1)
                continue
            }
            bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            // An uneven little loop per bar, each at its own speed, so they never march in step.
            let shapes: [[Double]] = [[0.3, 1, 0.55, 0.9, 0.35], [0.5, 0.8, 0.3, 1, 0.6], [0.35, 0.7, 1, 0.45, 0.85], [0.6, 0.35, 0.9, 0.5, 1]]
            let values = shapes[i % shapes.count]
            a.values = values + [values[0]]
            a.duration = 1.1 + Double(i) * 0.27
            a.calculationMode = .cubic
            a.repeatCount = .infinity
            a.timeOffset = Double(i) * 0.4
            bar.add(a, forKey: "dance")
        }
    }
}
