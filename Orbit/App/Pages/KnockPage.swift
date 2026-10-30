import SwiftUI

struct KnockPage: View {
    @Bindable private var knock = Knock.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Knock", subtitle: "Knock on your MacBook twice or three times to run anything in Orbit.") {
                Toggle("", isOn: $knock.enabled.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
                    .disabled(knock.status == .unsupported)
            }

            if knock.status == .unsupported || knock.status == .failed {
                KnockNotice(unsupported: knock.status == .unsupported)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            KnockStage(knock: knock)
                .opacity(knock.status == .listening ? 1 : 0.55)
                .animation(.spring(duration: 0.3), value: knock.status)

            SettingsGroup(title: "Knocks") {
                SettingsRow(title: "Two knocks", subtitle: "Knock, knock.", symbol: "hand.tap") {
                    KnockActionMenu(count: 2, knock: knock)
                }
                RowDivider()
                SettingsRow(title: "Three knocks", subtitle: "Knock, knock, knock — in an even beat.", symbol: "hand.tap.fill") {
                    KnockActionMenu(count: 3, knock: knock)
                }
            }

            SettingsGroup(footer: "Knocks right as you type or click don’t count, nor while the Mac is moving, asleep or locked.") {
                SettingsRow(title: "Sensitivity", subtitle: "High feels the lightest taps; Low needs a firmer knock and ignores more bumps.", symbol: "dial.medium") {
                    ChipPicker(selection: $knock.sensitivity, options: [(.high, "High"), (.normal, "Normal"), (.low, "Low")])
                }
                RowDivider()
                SettingsRow(title: "Show what ran", subtitle: "A short note after each knock.", symbol: "text.bubble") {
                    Toggle("", isOn: $knock.showWhatRan).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .animation(.spring(duration: 0.3), value: knock.status)
        .onAppear { knock.metering = true }
        .onDisappear { knock.metering = false }
    }
}

/// A MacBook seen from above: ripples where it's knocked, and what the last pattern was.
private struct KnockStage: View {
    let knock: Knock
    @State private var ripples: [Ripple] = []

    private struct Ripple: Identifiable {
        let id = UUID()
        let strength: Double
    }

    var body: some View {
        let threshold = knock.sensitivity.threshold
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 18) {
                laptop
                    .overlay {
                        ForEach(ripples) { r in RippleRing(strength: r.strength) }
                    }
                VStack(spacing: 6) {
                    Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.opacity)
                    meter(threshold: threshold)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .frame(height: 300)
        .environment(\.colorScheme, .dark)
        .onChange(of: knock.level) { _, level in
            // A jolt over the bar: a ripple, as big as the knock was hard.
            guard level > threshold, ripples.count < 4 else { return }
            let r = Ripple(strength: min(1, level / (threshold * 6)))
            ripples.append(r)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { ripples.removeAll { $0.id == r.id } }
        }
    }

    private var caption: String {
        if let p = knock.lastPattern, Date().timeIntervalSince(p.at) < 3 {
            let t = knock.target(p.count)
            return "%@ → %@".loc(p.count == 2 ? "Two knocks".loc : "Three knocks".loc, t.title)
        }
        return knock.status == .listening ? "Knock twice to try it".loc : "Turn on Knock to try it".loc
    }

    /// The palm rest, the keyboard and the trackpad, faintly.
    private var laptop: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.22))
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.06)).frame(height: 66)
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)).frame(width: 110, height: 58)
            }
            .padding(14)
            Image(systemName: "hand.tap.fill").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                .offset(x: 92, y: 30)
        }
        .frame(width: 260, height: 168)
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    /// How hard the Mac is being knocked right now, and where a knock starts.
    private func meter(threshold: Double) -> some View {
        let full = threshold * 4
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(knock.level > threshold ? Palette.accent : .white.opacity(0.5))
                    .frame(width: max(4, geo.size.width * min(1, knock.level / full)))
                    .animation(.easeOut(duration: 0.08), value: knock.level)
                Rectangle().fill(.white.opacity(0.6)).frame(width: 1.5, height: 10)
                    .offset(x: geo.size.width * threshold / full)
            }
        }
        .frame(width: 220, height: 6)
    }
}

private struct RippleRing: View {
    let strength: Double
    @State private var grown = false

    var body: some View {
        Circle()
            .strokeBorder(Palette.accent, lineWidth: 2)
            .frame(width: 30, height: 30)
            .scaleEffect(grown ? 2 + 4 * strength : 0.4)
            .opacity(grown ? 0 : 0.9)
            .offset(x: 92, y: 30)
            .onAppear { withAnimation(.easeOut(duration: 0.65)) { grown = true } }
            .allowsHitTesting(false)
    }
}

/// What a pattern runs: the same choices as a hot corner, plus media.
private struct KnockActionMenu: View {
    let count: Int
    let knock: Knock

    private static let groups = ["Media", "Capture", "Clipboard", "Window", "System", "Orbit"]

    var body: some View {
        let target = knock.target(count)
        Menu {
            Button { knock.set(HotCorners.Target.none, for: count) } label: { Label("Nothing".loc, systemImage: "minus") }
            Button { knock.set(.ring, for: count) } label: { Label("Orbit Ring".loc, systemImage: "circle.dashed") }
            Section("macOS".loc) {
                ForEach(HotCorners.System.allCases, id: \.self) { s in
                    Button { knock.set(.system(s), for: count) } label: { Label(s.title.loc, systemImage: s.symbol) }
                }
            }
            Section("Orbit".loc) {
                ForEach(Self.groups, id: \.self) { g in
                    Menu(g.loc) {
                        ForEach(OrbitAction.allCases.filter { $0.group == g }, id: \.self) { a in
                            Button { knock.set(.command(a), for: count) } label: { Label(a.title, systemImage: a.symbol) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: target.symbol).font(.system(size: 11, weight: .semibold))
                Text(target.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.5)
            }
            .foregroundStyle(target == .none ? Palette.inkSecondary : Palette.ink)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Palette.raised))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct KnockNotice: View {
    let unsupported: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).background(Circle().fill(Palette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(unsupported ? "This Mac has no motion sensor".loc : "The motion sensor didn’t answer".loc)
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                Text(unsupported
                     ? "Knock feels knocks with the sensor inside MacBooks with Apple silicon (M2 or later, and some M1 Pro). Desktop Macs and Intel MacBooks don’t have one.".loc
                     : "Turn Knock off and on again, or restart the Mac.".loc)
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
