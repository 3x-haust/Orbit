import AppKit
import SwiftUI

/// What the notch holds in each phase. Each piece is laid out at the size of the shape it belongs
/// to and clipped by the shape as it moves, so nothing reflows mid-morph — it's revealed or covered.
struct NotchContent: View {
    let phase: NotchCenter.Phase
    /// The shape's size in this phase.
    let size: CGSize
    let notch: CGSize
    let display: CGDirectDisplayID
    private var center: NotchCenter { .shared }

    var body: some View {
        let inner = CGSize(width: size.width - 2 * NotchGeometry.ear(phase).width, height: size.height)
        ZStack(alignment: .top) {
            switch phase {
            case .hidden, .idle:
                Color.clear
            case .ears(let ear):
                NotchEars(ear: ear, notch: notch, width: (inner.width - notch.width) / 2)
                    .frame(width: inner.width, height: inner.height)
                    .transition(.notchContent).id("ears-\(ear)")
            case .hud:
                if let hud = center.hud {
                    NotchHUDEars(hud: hud, notch: notch, width: (inner.width - notch.width) / 2)
                        .frame(width: inner.width, height: inner.height)
                        .transition(.notchContent).id("hud")
                }
            case .peek:
                if let peek = center.peek {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: notch.height)
                        NotchPeekRow(peek: peek)
                    }
                    .frame(width: inner.width, height: inner.height, alignment: .top)
                    .transition(.notchContent).id("peek")
                }
            case .banner:
                if let banner = center.banner {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: notch.height)
                        NotchBannerRow(content: banner)
                    }
                    .frame(width: inner.width, height: inner.height, alignment: .top)
                    .transition(.notchContent).id("banner")
                }
            case .expanded:
                NotchOpenPanel(notch: notch, display: display)
                    .frame(width: inner.width, height: inner.height, alignment: .top)
                    .transition(.notchContent).id("panel")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

// MARK: - Ears

/// Left and right of the camera: a picture on one side, a value on the other.
struct NotchEars: View {
    let ear: NotchCenter.Ear
    let notch: CGSize
    /// Each ear's width (capped by the menu bar's free room).
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            left.earSide(.leading, width: width, height: notch.height)
            Spacer(minLength: notch.width)
            right.earSide(.trailing, width: width, height: notch.height)
        }
        .frame(height: notch.height)
    }

    @ViewBuilder private var left: some View {
        switch ear {
        case .music:
            let np = NowPlaying.shared
            Group {
                if let art = np.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                else { CoverPlaceholder(appIcon: np.appIcon, side: 20) }
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .timer:
            Image(systemName: NotchTimer.shared.isPaused ? "pause.fill" : "timer").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.brand)
        case .recording:
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.6), radius: 3)
        case .download:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
        case .awake:
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
        case .charging(let on):
            // As big as the music ear's cover: a tile the height of the bar, with the bolt in it.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(on ? Color.green : Color.white.opacity(0.2))
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: on ? "bolt.fill" : "powerplug.portrait.fill")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(on ? .black : .white)
                }
        }
    }

    @ViewBuilder private var right: some View {
        switch ear {
        case .music:
            Equalizer(playing: NowPlaying.shared.playing, color: NowPlaying.shared.palette.accent)
                .frame(width: 16, height: 13)
        case .timer:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                EarText(NotchTimer.clock(NotchTimer.shared.remaining(at: ctx.date)))
            }
        case .recording:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                EarText(NotchTimer.clock(ctx.date.timeIntervalSince(Recorder.shared.startedAt ?? ctx.date)), color: .red)
            }
        case .download:
            EarText(NotchDownloads.shared.summary)
        case .awake:
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                if let until = KeepAwake.shared.until { EarText(NotchTimer.short(until.timeIntervalSince(ctx.date))) }
                else { Image(systemName: "infinity").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85)) }
            }
        case .charging(let on):
            let percent = NotchEars.chargingPercent
            HStack(alignment: .center, spacing: 4) {
                Text("\(percent)%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(on ? Color.green : .white)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(1)
                BatteryGlyph(level: Double(percent) / 100, tint: on ? .green : percent < 20 ? .red : .white)
                    .frame(width: 20, height: 10)
            }
        }
    }

    @MainActor static var chargingPercent: Int {
        #if DEBUG
        if let p = NotchCenter.shared.debugPercent, NotchCenter.shared.debugEarOn { return p }
        #endif
        return NotchLive.shared.battery?.percent ?? 100
    }
}

extension View {
    /// Lays out one ear's content: against the shape's rounded end with room to breathe
    /// (`earOuterPadding`), a little less toward the camera, centred top to bottom.
    func earSide(_ side: HorizontalAlignment, width: CGFloat, height: CGFloat) -> some View {
        let outer = NotchGeometry.earOuterPadding, inner = NotchGeometry.earInnerPadding
        return self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side == .leading ? .leading : .trailing)
            .padding(.leading, side == .leading ? outer : inner)
            .padding(.trailing, side == .leading ? inner : outer)
            .frame(width: width, height: height)
    }
}

/// A battery outline filled to its level.
struct BatteryGlyph: View {
    let level: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            let body = CGSize(width: g.size.width - 2.5, height: g.size.height)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1.2)
                    .frame(width: body.width, height: body.height)
                RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, (body.width - 4) * min(max(level, 0), 1)), height: body.height - 4)
                    .padding(.leading, 2)
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: 1.8, height: body.height * 0.4)
                    .offset(x: body.width + 0.7)
            }
        }
    }
}

private struct EarText: View {
    let text: String
    var color: Color = .white
    init(_ text: String, color: Color = .white) { self.text = text; self.color = color }

    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7)
            .contentTransition(.numericText())
    }
}

// MARK: - HUD

/// Volume, brightness or keyboard light: the symbol on the left, the level on the right.
struct NotchHUDEars: View {
    let hud: NotchCenter.HUD
    let notch: CGSize
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(hud.kind == .muted ? .white.opacity(0.5) : .white)
                .contentTransition(.symbolEffect(.replace))
                .earSide(.leading, width: width, height: notch.height)
            Spacer(minLength: notch.width)
            HStack(spacing: 7) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(hud.value >= 0.999 ? Palette.brand : .white)
                            .frame(width: max(4, g.size.width * hud.value))
                    }
                }
                .frame(width: max(16, width - NotchGeometry.earOuterPadding - NotchGeometry.earInnerPadding - 29), height: 5)
                Text("\(Int((hud.value * 100).rounded()))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 22, alignment: .trailing)
                    .contentTransition(.numericText())
            }
            .earSide(.trailing, width: width, height: notch.height)
        }
        .animation(.spring(duration: 0.18, bounce: 0), value: hud.value)
    }

    private var symbol: String {
        switch hud.kind {
        case .brightness: hud.value < 0.34 ? "sun.min.fill" : "sun.max.fill"
        case .volume: hud.value < 0.01 ? "speaker.fill" : hud.value < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
        case .muted: "speaker.slash.fill"
        case .keyboard: hud.value < 0.01 ? "light.min" : "light.max"
        }
    }
}

// MARK: - Notice

struct NotchPeekRow: View {
    let peek: NotchCenter.Peek

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: peek.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(peek.tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(peek.tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title.loc).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let detail = peek.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !peek.levels.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(peek.levels.enumerated()), id: \.offset) { _, level in
                        HStack(spacing: 4) {
                            Image(systemName: level.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                                .frame(width: 18)
                            Text("\(level.percent)%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(level.percent < 20 ? Color.red : .white)
                        }
                    }
                }
            } else if let trailing = peek.trailing {
                Text(trailing).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(peek.tint)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

// MARK: - Song banner

struct NotchBannerRow: View {
    let content: WidgetContent

    var body: some View {
        HStack(spacing: 11) {
            Group {
                if let art = content.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                else { CoverPlaceholder(appIcon: content.appIcon, side: 44) }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(content.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Equalizer(playing: content.playing, color: content.palette.accent).frame(width: 16, height: 14)
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .contentShape(Rectangle())
        .onTapGesture { NowPlaying.shared.openSource() }
    }
}
