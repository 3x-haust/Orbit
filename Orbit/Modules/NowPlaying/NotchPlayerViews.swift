import SwiftUI

@MainActor @Observable
final class NotchPlayerModel {
    /// The camera housing's size, from the screen.
    var notch = CGSize(width: 185, height: 32)
    /// The pointer is on it.
    var expanded = false
    /// The live activity is turned on (otherwise the island only opens for banners).
    var wings = true
    /// A song-change banner showing right now, and what it shows.
    var banner: WidgetContent?
    @ObservationIgnored var onHover: ((Bool) -> Void)?
}

/// Until the cover arrives: the playing app's icon on a dark tile.
struct CoverPlaceholder: View {
    let appIcon: NSImage?
    let side: CGFloat

    var body: some View {
        Color(white: 0.16).overlay {
            if let appIcon { Image(nsImage: appIcon).resizable().interpolation(.high).frame(width: side * 0.62, height: side * 0.62) }
            else { Image(systemName: "music.note").font(.system(size: side * 0.42)).foregroundStyle(.white.opacity(0.6)) }
        }
    }
}

/// A rounded rectangle whose top corners can be square, so it hangs from the top of the screen.
struct HangingShape: Shape {
    var radius: CGFloat
    var top: CGFloat

    func path(in r: CGRect) -> Path {
        Path(roundedRect: r, cornerRadii: RectangleCornerRadii(topLeading: top, bottomLeading: radius, bottomTrailing: radius, topTrailing: top),
             style: .continuous)
    }
}

/// The notch, grown: one black shape that widens into wings while music plays, and opens downward into
/// a banner or a small player. It always starts from — and returns to — the notch's own size, so it reads
/// as the notch changing shape rather than something dropping in front of it.
struct NotchPlayerBody: View {
    @Bindable var model: NotchPlayerModel
    let content: WidgetContent?
    @State private var collapseWork: DispatchWorkItem?

    enum Phase { case hidden, wings, banner, expanded }

    static let wing: CGFloat = 38
    /// The inward curves where the shape meets the bezel.
    static let shoulder: CGFloat = 6
    static let notchRadius: CGFloat = 8

    private var phase: Phase {
        if model.expanded, content != nil, model.wings || model.banner != nil { return .expanded }
        if model.banner != nil { return .banner }
        if model.wings, content != nil { return .wings }
        return .hidden
    }

    /// Outer size, shoulders included.
    private func size(_ p: Phase) -> CGSize {
        let n = model.notch, s = Self.shoulder * 2
        switch p {
        case .hidden: return CGSize(width: n.width + s, height: n.height)
        case .wings: return CGSize(width: n.width + 2 * Self.wing + s, height: n.height)
        case .banner: return CGSize(width: max(340, n.width + 2 * Self.wing + s), height: n.height + 62)
        case .expanded: return CGSize(width: max(360, n.width + 2 * Self.wing + s + 40), height: n.height + 138)
        }
    }

    private func radius(_ p: Phase) -> CGFloat {
        switch p {
        case .hidden, .wings: Self.notchRadius
        case .banner: 20
        case .expanded: 24
        }
    }

    var body: some View {
        let p = phase
        let s = size(p)
        ZStack(alignment: .top) {
            NotchShape(topRadius: Self.shoulder, bottomRadius: radius(p))
                .fill(.black)
            Group {
                switch p {
                case .hidden: EmptyView()
                case .wings: if let c = content { wings(c).transition(Self.contentIn) }
                case .banner: if let c = model.banner { banner(c).transition(Self.contentIn) }
                case .expanded: if let c = content { expanded(c).transition(Self.contentIn) }
                }
            }
            .padding(.horizontal, Self.shoulder)
        }
        .frame(width: s.width, height: s.height, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering($0) }
        .opacity(p == .hidden ? 0 : 1) // identical to the notch anyway; keeps the edges from ever peeking
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.42, bounce: 0.18), value: p)
    }

    /// Content waits for the shape to grow, then fades in; it leaves at once.
    static let contentIn: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.16)),
        removal: .opacity.animation(.easeIn(duration: 0.08)))

    private func hovering(_ h: Bool) {
        collapseWork?.cancel()
        model.onHover?(h)
        if h {
            guard phase != .hidden else { return }
            model.expanded = true
        } else {
            let work = DispatchWorkItem { model.expanded = false }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: Wings

    /// Exactly the notch's height: the cover centered in the left wing, the bars in the right.
    private func wings(_ c: WidgetContent) -> some View {
        let h = model.notch.height
        return HStack(spacing: 0) {
            cover(c, side: min(20, h - 10), radius: 5)
                .frame(width: Self.wing, height: h)
            Color.clear.frame(width: model.notch.width, height: h)
            Equalizer(playing: c.playing, color: c.palette.accent)
                .frame(width: 14, height: 11)
                .frame(width: Self.wing, height: h)
        }
    }

    // MARK: Banner

    private func banner(_ c: WidgetContent) -> some View {
        HStack(spacing: 11) {
            cover(c, side: 40, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if !c.artist.isEmpty {
                    Text(c.artist).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Equalizer(playing: c.playing, color: c.palette.accent).frame(width: 14, height: 12)
        }
        .padding(.horizontal, 14)
        .padding(.top, model.notch.height + 8)
        .onTapGesture { NowPlaying.shared.openSource() }
    }

    // MARK: Player

    private func expanded(_ c: WidgetContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                cover(c, side: 46, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if !c.artist.isEmpty {
                        Text(c.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Equalizer(playing: c.playing, color: c.palette.accent).frame(width: 14, height: 12)
            }
            progress(c)
            ZStack {
                HStack(spacing: 10) {
                    WidgetControl(symbol: "backward.fill", size: 14, color: .white, enabled: c.live) { NowPlaying.shared.previous() }
                    WidgetControl(symbol: c.playing ? "pause.fill" : "play.fill", size: 19, color: .white, enabled: c.live) { NowPlaying.shared.togglePlayPause() }
                    WidgetControl(symbol: "forward.fill", size: 14, color: .white, enabled: c.live) { NowPlaying.shared.next() }
                }
                HStack {
                    Spacer()
                    WidgetControl(symbol: c.liked ? "heart.fill" : "heart", size: 14, color: c.liked ? c.palette.accent : .white.opacity(0.85),
                                  enabled: c.live) { NowPlaying.shared.toggleLike() }
                }
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 16)
        .padding(.top, model.notch.height + 10)
    }

    private func progress(_ c: WidgetContent) -> some View {
        TimelineView(.animation(minimumInterval: 1, paused: !c.playing)) { ctx in
            let elapsed = c.elapsed(ctx.date)
            let fraction = c.duration > 0 ? min(1, max(0, elapsed / c.duration)) : 0
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(c.palette.accent).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { p in
                        guard c.live, c.duration > 0 else { return }
                        NowPlaying.shared.seek(to: min(1, max(0, p.x / geo.size.width)) * c.duration)
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(NowPlayingWidgetView.time(elapsed))
                    Spacer()
                    Text("-" + NowPlayingWidgetView.time(max(0, c.duration - elapsed)))
                }
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .opacity(c.duration > 0 ? 1 : 0)
            }
        }
    }

    private func cover(_ c: WidgetContent, side: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            if let art = c.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
            else { CoverPlaceholder(appIcon: c.appIcon, side: side) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .id(c.generation)
        .transition(.opacity)
    }
}
