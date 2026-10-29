import SwiftUI

struct HotCornersPage: View {
    @Bindable private var corners = HotCorners.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Hot Corners", subtitle: "Push the pointer into a corner of the screen to run anything in Orbit.") {
                Toggle("", isOn: $corners.enabled.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
            }

            if !conflicts.isEmpty {
                MacOSCornersBanner(count: conflicts.count) { corners.takeOverFromMacOS() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            ScreenPreview(corners: corners)
                .opacity(corners.enabled ? 1 : 0.55)
                .animation(.spring(duration: 0.3), value: corners.enabled)

            SettingsGroup {
                SettingsRow(title: "Response", subtitle: "How long the pointer rests in the corner first.", symbol: "timer") {
                    ChipPicker(selection: $corners.delay, options: [(0.0, "Instant"), (0.2, "Quick"), (0.5, "Relaxed"), (1.0, "Deliberate")])
                }
                RowDivider()
                SettingsRow(title: "Corner glow", subtitle: "A soft light gathers in the corner just before it fires.", symbol: "sun.max") {
                    Toggle("", isOn: $corners.glowing).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "While dragging", subtitle: "Carry a file or window into a corner — drop it on the Shelf, or into Mission Control.", symbol: "hand.draw") {
                    Toggle("", isOn: $corners.whileDragging).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .animation(.spring(duration: 0.3), value: conflicts.isEmpty)
    }

    private var conflicts: [HotCorners.Corner] {
        _ = corners.macOSChanged
        return corners.conflicts
    }
}

/// A little Mac screen with a menu for each corner.
private struct ScreenPreview: View {
    let corners: HotCorners

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
            // Menu bar and Dock, faintly.
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 18)
                Spacer()
                Capsule().fill(.white.opacity(0.08)).frame(width: 190, height: 26).padding(.bottom, 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Image(nsImage: Brand.logo).resizable().frame(width: 54, height: 54).opacity(0.5)

            ForEach(HotCorners.Corner.allCases) { c in
                CornerPuck(corner: c, corners: corners)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(c))
                    .padding(14)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .frame(height: 330)
        .environment(\.colorScheme, .dark)
    }

    private func alignment(_ c: HotCorners.Corner) -> Alignment {
        switch c {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

private struct CornerPuck: View {
    let corner: HotCorners.Corner
    let corners: HotCorners
    @State private var hovering = false

    private static let groups = ["Capture", "Clipboard", "Window", "System", "Orbit"]

    var body: some View {
        let target = corners.target(corner)
        let live = corners.active == corner
        // A corner left to macOS shows what macOS does there.
        let macOSOnly = target == .none ? corners.macOSCorners[corner].flatMap(HotCorners.macOSName) : nil
        Menu {
            Button { corners.set(HotCorners.Target.none, for: corner) } label: { Label("Nothing".loc, systemImage: "minus") }
            Button { corners.set(.ring, for: corner) } label: { Label("Orbit Ring".loc, systemImage: "circle.dashed") }
            Section("macOS".loc) {
                ForEach(HotCorners.System.allCases, id: \.self) { s in
                    Button { corners.set(.system(s), for: corner) } label: { Label(s.title.loc, systemImage: s.symbol) }
                }
            }
            Section("Orbit".loc) {
                ForEach(Self.groups, id: \.self) { g in
                    Menu(g.loc) {
                        ForEach(OrbitAction.allCases.filter { $0.group == g }, id: \.self) { a in
                            Button { corners.set(.command(a), for: corner) } label: { Label(a.title, systemImage: a.symbol) }
                        }
                    }
                }
            }
            Divider()
            Menu("Hold a key".loc) {
                ForEach(HotCorners.Modifier.allCases, id: \.self) { m in
                    Toggle(m.label.loc, isOn: Binding(get: { corners.modifier(corner) == m }, set: { _ in corners.set(m, for: corner) }))
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: target.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(target == .none ? .white.opacity(0.45) : .black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(target == .none ? .white.opacity(0.08) : .white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(corner.title.loc).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    HStack(spacing: 5) {
                        Text(macOSOnly.map { "macOS: %@".loc($0.loc) } ?? target.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(target == .none ? .white.opacity(0.5) : .white)
                            .fixedSize()
                        if corners.modifier(corner) != .none {
                            Text(corners.modifier(corner).label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 5).frame(height: 16)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.14)))
                        }
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.leading, 6).padding(.trailing, 12).frame(height: 44)
            .background(Capsule().fill(.white.opacity(hovering ? 0.13 : 0.08)))
            .overlay(Capsule().strokeBorder(live ? Palette.accent : .white.opacity(0.12), lineWidth: live ? 1.5 : 1))
            .scaleEffect(live ? 1.04 : 1)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: live)
    }
}

private struct MacOSCornersBanner: View {
    let count: Int
    let takeOver: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 30, height: 30).background(Circle().fill(Palette.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS’s own hot corners are on").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                Text("Both would fire in the same corner. Move them into Orbit and turn macOS’s off.")
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Move to Orbit", action: takeOver).buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}
