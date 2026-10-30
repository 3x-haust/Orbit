import SwiftUI
import KeyboardShortcuts

struct HomePage: View {
    let router: AppRouter
    private var permissions: Permissions { .shared }
    private var capture: CaptureService { .shared }

    private static let quick: [OrbitAction] = [
        .captureArea, .captureWindow, .captureScreen, .captureText,
        .clipboard, .launcher, .colorPicker, .shelf,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            PageHeader(title: greeting, subtitle: "Orbit is running in your menu bar.")

            if Overlaps.shared.count > 0 {
                HStack(spacing: 14) {
                    Image(systemName: "square.on.square.dashed").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent)
                        .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("%ld things overlap with Orbit".loc(Overlaps.shared.count)).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                        Text("Quit or remove them in one place.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    Button("Review") { MainWindow.show(.overlaps) }.buttonStyle(PillButtonStyle(prominent: true))
                }
                .padding(16).card()
            }

            if !(permissions.screenCapture && permissions.accessibility) {
                SetupBanner { go(.setup) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            RingHero { go(.ring) }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Quick actions")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(Self.quick) { a in ActionCard(action: a) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Recent captures")
                    Spacer()
                    if !capture.recent.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.open(CaptureService.dir) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                    }
                }
                RecentCaptures()
            }

            HStack(spacing: 12) {
                StatCard(value: "\(ClipboardStore.shared.items.count)", label: "Clipboard items", symbol: "doc.on.clipboard") { go(.clipboard) }
                StatCard(value: "\(capture.recent.count)", label: "Captures", symbol: "viewfinder") { go(.capture) }
                StatCard(value: KeepAwake.shared.isOn ? "On" : "Off", label: "Awake", symbol: "cup.and.saucer") { go(.awake) }
            }
        }
        .animation(.spring(duration: 0.4), value: permissions.screenCapture && permissions.accessibility)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private func go(_ page: Page) {
        withAnimation(Motion.adaptive(.spring(duration: 0.32, bounce: 0.12))) { router.page = page }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.loc.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Palette.inkSecondary).padding(.leading, 4)
    }
}

/// Generic hover-lift card surface.
struct CardSurface: ViewModifier {
    var active = false
    var hovering = false
    var radius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(active ? Palette.accent : (hovering ? Palette.ink.opacity(0.2) : Palette.hairline), lineWidth: active ? 2 : 1))
            .shadow(color: .black.opacity(hovering ? 0.08 : 0), radius: 10, y: 4)
            .offset(y: hovering ? -2 : 0)
    }
}

extension View {
    func card(active: Bool = false, hovering: Bool = false, radius: CGFloat = 14) -> some View {
        modifier(CardSurface(active: active, hovering: hovering, radius: radius))
    }
}

private struct SetupBanner: View {
    let open: () -> Void
    private var p: Permissions { .shared }

    var body: some View {
        let left = [p.screenCapture, p.accessibility].filter { !$0 }.count
        HStack(spacing: 14) {
            Image(systemName: "lock.open")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(Palette.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(left == 1 ? "One permission left".loc : "%ld permissions left".loc(left)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Captures and window snapping need your OK in System Settings.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button("Finish Setup", action: open).buttonStyle(PillButtonStyle())
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
    }
}

private struct RingHero: View {
    let customize: () -> Void
    @State private var highlight = 0
    @State private var hovering = false
    private let timer = Timer.publish(every: 1.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 28) {
            MiniRing(slots: OrbitRing.loadSlots(), size: 150, highlight: highlight)
                .animation(.spring(duration: 0.35, bounce: 0.3), value: highlight)
            VStack(alignment: .leading, spacing: 10) {
                Text("Your Ring").font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.ink)
                Text("Hold the shortcut or the middle mouse button, aim, and let go.")
                    .font(.system(size: 13)).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ShortcutKeys(text: KeyboardShortcuts.getShortcut(for: .ring)?.description)
                    Text("or").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                    Label("Middle button", systemImage: "computermouse")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.raised))
                }
                HStack(spacing: 8) {
                    Button("Customize Ring", action: customize).buttonStyle(PillButtonStyle())
                    Button("Open Now") { OrbitRing.shared.open(hold: false) }.buttonStyle(PillButtonStyle(prominent: false))
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .card(hovering: hovering, radius: 18)
        .onHover { h in withAnimation(.spring(duration: 0.3)) { hovering = h } }
        .onReceive(timer) { _ in highlight = (highlight + 1) % 8 }
    }
}

struct ActionCard: View {
    let action: OrbitAction
    @State private var hovering = false
    @State private var pressed = 0

    var body: some View {
        Button {
            pressed += 1
            MainWindow.shared.perform(action)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: action.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white : Palette.canvas)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Palette.accent : Palette.ink))
                    .symbolEffect(.bounce, value: pressed)
                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    if let label = action.shortcutLabel {
                        ShortcutKeys(text: label).scaleEffect(0.9, anchor: .leading)
                    } else {
                        Text(action.groupTitle).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).frame(height: 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .card(hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hovering = h } }
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let symbol: String
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text(label.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(Palette.inkSecondary)
            }
            .padding(16)
            .card(hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hovering = h } }
    }
}

struct RecentCaptures: View {
    private var capture: CaptureService { .shared }

    var body: some View {
        if capture.recent.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20)).foregroundStyle(Palette.inkSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No captures yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Press %@ to grab part of the screen.".loc(OrbitAction.captureArea.shortcutLabel ?? "⌥⇧4"))
                        .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
            }
            .padding(18)
            .card()
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(capture.recent.prefix(10)) { c in CaptureThumb(capture: c) }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
        }
    }
}

private struct CaptureThumb: View {
    let capture: Capture
    @State private var hovering = false

    var body: some View {
        Button { EditorWindow.open(image: capture.image, fileURL: capture.fileURL) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: capture.image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) // clicks only where it shows
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hovering ? Palette.accent : Palette.hairline, lineWidth: hovering ? 2 : 1))
                Text(capture.date.orbitRelative).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
            }
            .scaleEffect(hovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hovering = h } }
        .draggable(capture.image)
        .help("Open in editor")
    }
}
