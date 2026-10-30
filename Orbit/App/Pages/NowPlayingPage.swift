import AppKit
import SwiftUI

/// Now Playing: a desktop widget for whatever is playing, plus a song-change banner and a notch player.
struct NowPlayingPage: View {
    private var np: NowPlaying { .shared }
    private var controller: NowPlayingWidgetController { .shared }
    private var state: WidgetState { controller.state }

    @AppStorage(NowPlayingPrefs.widget) private var widget = false
    @AppStorage(NowPlayingPrefs.popup) private var popup = false
    @AppStorage(NowPlayingPrefs.popupPlace) private var popupPlace = TrackPopup.Place.notch.rawValue
    @AppStorage(NowPlayingPrefs.popupOnlyHidden) private var popupOnlyHidden = true
    @AppStorage(NowPlayingPrefs.notch) private var notch = false
    @AppStorage(NotchPrefs.enabled) private var orbitNotch = true
    @AppStorage(NotchPrefs.liveMusic) private var notchMusic = true
    @AppStorage(NowPlayingPrefs.directControl) private var direct = false
    @AppStorage(NowPlayingPrefs.sharperCovers) private var sharperCovers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Now Playing", subtitle: "What’s playing, on your desktop — from any app, in a look that’s yours.") {
                Toggle("", isOn: feature(NowPlayingPrefs.widget, $widget)).toggleStyle(.switch).labelsHidden()
            }

            PreviewStage(style: state.style)

            if widget { WidgetStatus() }

            SourcesSection()

            ThemesSection(style: state.style) { controller.setStyle($0, animated: true) }

            SettingsGroup(title: "Layout") {
                SettingsRow(title: "Layout", symbol: "rectangle.3.group") {
                    ChipPicker(selection: bind(\.layout), options: [(.horizontal, "Side by side"), (.vertical, "Stacked"), (.artwork, "Cover"), (.pill, "Pill")])
                }
                RowDivider()
                SliderRow(title: "Cover size", symbol: "photo", value: bind(\.artworkSize), range: state.style.layout == .pill ? 24...56 : 48...320, step: 2, unit: "pt")
                if state.style.layout != .artwork {
                    RowDivider()
                    SliderRow(title: "Text width", symbol: "text.alignleft", value: bind(\.textWidth), range: 120...380, step: 5, unit: "pt")
                    RowDivider()
                    SettingsRow(title: "Alignment", symbol: "text.aligncenter") {
                        ChipPicker(selection: bind(\.align), options: [(.leading, "Left"), (.center, "Center"), (.trailing, "Right")])
                    }
                }
                RowDivider()
                SliderRow(title: "Corners", symbol: "app", value: bind(\.cornerRadius), range: 0...44, step: 1, unit: "pt")
                if state.style.layout != .artwork {
                    RowDivider()
                    SliderRow(title: "Cover corners", symbol: "square.on.square", value: bind(\.artworkRadius), range: 0...40, step: 1, unit: "pt")
                }
            }

            SettingsGroup(title: "Show") {
                ToggleRow(title: "Title", symbol: "textformat", isOn: bind(\.showTitle))
                RowDivider()
                ToggleRow(title: "Artist", symbol: "person", isOn: bind(\.showArtist))
                RowDivider()
                ToggleRow(title: "Album", symbol: "square.stack", isOn: bind(\.showAlbum))
                RowDivider()
                ToggleRow(title: "Progress", subtitle: "Drag it to jump around in the song.", symbol: "slider.horizontal.below.rectangle", isOn: bind(\.showProgress))
                RowDivider()
                ToggleRow(title: "Controls", symbol: "playpause", isOn: bind(\.showControls))
                if state.style.showControls {
                    RowDivider()
                    ToggleRow(title: "Controls only under the pointer", subtitle: "A clean widget until you reach for it.", symbol: "cursorarrow.rays", isOn: bind(\.controlsOnHover))
                    RowDivider()
                    ToggleRow(title: "Like button", subtitle: "Loves the song in Music.", symbol: "heart", isOn: bind(\.showLike))
                }
                RowDivider()
                ToggleRow(title: "App icon", subtitle: "A small badge for the app that’s playing.", symbol: "app.badge", isOn: bind(\.showSource))
            }

            SettingsGroup(title: "Look") {
                SettingsRow(title: "Background", symbol: "square.fill.on.square") {
                    ChipPicker(selection: bind(\.background), options: [(.tinted, "Cover tint"), (.glass, "Glass"), (.solid, "Solid"), (.none, "None")])
                }
                if state.style.background == .tinted || state.style.background == .solid {
                    RowDivider()
                    SliderRow(title: "Opacity", symbol: "circle.lefthalf.filled", value: bind(\.backgroundOpacity), range: 0.3...1, step: 0.05, unit: "%")
                }
                RowDivider()
                SettingsRow(title: "Colors", subtitle: "From the cover picks an accent from the album art.", symbol: "paintpalette") {
                    ChipPicker(selection: bind(\.colors), options: [(.artwork, "From the cover"), (.light, "Light"), (.dark, "Dark")])
                }
                RowDivider()
                SettingsRow(title: "Font", symbol: "textformat.alt") {
                    ChipPicker(selection: bind(\.design), options: [(.standard, "System"), (.rounded, "Rounded"), (.serif, "Serif"), (.mono, "Mono")])
                }
                RowDivider()
                SettingsRow(title: "Weight", symbol: "bold") {
                    ChipPicker(selection: bind(\.weight), options: [(.regular, "Regular"), (.semibold, "Semibold"), (.bold, "Bold"), (.heavy, "Heavy")])
                }
                RowDivider()
                SliderRow(title: "Text size", symbol: "textformat.size", value: bind(\.titleSize), range: 11...26, step: 1, unit: "pt")
                RowDivider()
                SliderRow(title: "Shadow", symbol: "shadow", value: bind(\.shadow), range: 0...1, step: 0.05, unit: "%")
                RowDivider()
                ToggleRow(title: "Animate song changes", symbol: "sparkles", isOn: bind(\.animate))
            }

            SettingsGroup(title: "Where it sits", footer: "Drag the widget anywhere on your desktop — it snaps to the edges, the corners and the middle.") {
                SettingsRow(title: "Position", symbol: "square.grid.3x3") {
                    AnchorPicker(anchor: state.style.anchor) { a in
                        var s = state.style
                        s.anchor = a
                        s.dx = [.top, .center, .bottom].contains(a) ? 0 : 24
                        s.dy = [.left, .center, .right].contains(a) ? 0 : 24
                        controller.setStyle(s, animated: true)
                    }
                }
                RowDivider()
                SettingsRow(title: "Display", symbol: "display") { DisplayMenu(selection: bind(\.display)) }
                RowDivider()
                SettingsRow(title: "Level", subtitle: state.style.level == .desktop ? "On the desktop, under your windows." : "Above your windows, always in sight.", symbol: "square.3.layers.3d") {
                    ChipPicker(selection: bind(\.level), options: [(.desktop, "Desktop"), (.floating, "Floating")])
                }
                RowDivider()
                ToggleRow(title: "Lock position", subtitle: "No accidental drags.", symbol: "lock", isOn: bind(\.locked))
                RowDivider()
                ToggleRow(title: "Hide when nothing is playing", symbol: "eye.slash", isOn: bind(\.hideWhenIdle))
                RowDivider()
                ToggleRow(title: "Hide when paused", symbol: "pause.circle", isOn: bind(\.hideWhenPaused))
                if state.style.hideWhenPaused {
                    RowDivider()
                    SettingsRow(title: "After", symbol: "timer") {
                        ChipPicker(selection: bind(\.hideDelay), options: [(0.0, "Right away"), (8.0, "8 s"), (30.0, "30 s"), (60.0, "1 min"), (300.0, "5 min")])
                    }
                }
            }

            SettingsGroup(title: "When the song changes") {
                SettingsRow(title: "Show a banner", subtitle: "Cover, title and artist for a moment. Click it to open the player.", symbol: "bell.badge") {
                    Toggle("", isOn: feature(NowPlayingPrefs.popup, $popup)).toggleStyle(.switch).labelsHidden()
                }
                if popup {
                    RowDivider()
                    SettingsRow(title: "Banner position", symbol: "rectangle.topthird.inset.filled") {
                        ChipPicker(selection: $popupPlace, options: [(TrackPopup.Place.notch.rawValue, "From the notch"), (TrackPopup.Place.topRight.rawValue, "Top right"), (TrackPopup.Place.bottom.rawValue, "Bottom")])
                    }
                    RowDivider()
                    SettingsRow(title: "Skip it when the widget floats on top", symbol: "eye") {
                        Toggle("", isOn: $popupOnlyHidden).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Try it", symbol: "play.rectangle") {
                        Button("Show") { TrackPopup.shared.preview() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            AutoPauseSection()

            SettingsGroup(title: "Notch", footer: orbitNotch ? nil : NotchPlayer.notchScreen == nil ? "Needs a display with a notch." : nil) {
                SettingsRow(title: "Live in the notch", subtitle: "The cover and a little equalizer either side of the notch while music plays. Point at it for the controls.", symbol: "rectangle.topthird.inset.filled") {
                    // With Orbit's notch on, the music there is its Music live activity: the same switch.
                    if orbitNotch {
                        Toggle("", isOn: Binding(get: { notchMusic }, set: { notchMusic = $0; NotchCenter.shared.apply() }))
                            .toggleStyle(.switch).labelsHidden()
                    } else {
                        Toggle("", isOn: feature(NowPlayingPrefs.notch, $notch)).toggleStyle(.switch).labelsHidden()
                            .disabled(NotchPlayer.notchScreen == nil)
                    }
                }
            }

            SettingsGroup(title: "Players", footer: "macOS asks once for each app. Without it, Orbit still sees and controls every app through Now Playing.") {
                SettingsRow(title: "Talk to Music and Spotify directly", subtitle: "Likes songs in Music, reads whether a song is loved, and keeps working if Now Playing doesn’t.", symbol: "music.note.list") {
                    Toggle("", isOn: Binding(get: { direct }, set: { on in
                        direct = on
                        NowPlayingLog.write("direct control \(on ? "on" : "off")")
                        if on { Task { await automation.ask() } }
                    })).toggleStyle(.switch).labelsHidden()
                }
                if direct {
                    ForEach(ScriptedPlayers.App.allCases, id: \.self) { app in
                        RowDivider()
                        AutomationRow(app: app, status: automation.status[app] ?? .unknown)
                    }
                }
                RowDivider()
                SettingsRow(title: "Sharper covers", subtitle: "When an app hands over a small cover, like YouTube Music in a browser, Orbit finds the song’s cover in Apple Music’s catalog. Only the title and artist are sent.", symbol: "photo.badge.checkmark") {
                    Toggle("", isOn: Binding(get: { sharperCovers }, set: { on in
                        sharperCovers = on
                        NowPlayingLog.write("sharper covers \(on ? "on" : "off")")
                    })).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .onAppear { NowPlaying.shared.start(); automation.refresh() }
        .onDisappear { NowPlaying.shared.update() }
    }

    @State private var automation = AutomationState()

    /// A feature switch: saved, logged, and acted on right away.
    private func feature(_ key: String, _ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { on in
            value.wrappedValue = on
            Pref.defaults.set(on, forKey: key)
            NowPlayingLog.write("\(key) \(on ? "on" : "off")")
            NowPlaying.shared.update()
            if on, key == NowPlayingPrefs.widget { NowPlayingWidgetController.shared.flash() }
        })
    }

    private func bind<T>(_ kp: WritableKeyPath<WidgetStyle, T>) -> Binding<T> {
        Binding(get: { state.style[keyPath: kp] }, set: { v in
            var s = state.style
            s[keyPath: kp] = v
            controller.setStyle(s)
        })
    }
}

// MARK: - Preview

/// The widget as it'll look, on a little desktop. Live when something's playing, a sample otherwise.
private struct PreviewStage: View {
    let style: WidgetStyle
    @State private var hovering = false

    var body: some View {
        let live = WidgetContent.current()
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.2, blue: 0.32), Color(red: 0.36, green: 0.22, blue: 0.3), Color(red: 0.12, green: 0.1, blue: 0.16)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if let art = (live ?? .sample).artwork {
                    // Filled, the cover is far taller than the stage, and clipping only hides the
                    // overflow: it stretched the stage and took the clicks meant for the header's
                    // switch above it. Sized by the stage instead, and never hit.
                    Color.clear
                        .overlay { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).blur(radius: 60).opacity(0.35) }
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                NowPlayingWidgetView(style: style, content: live ?? .sample, hovering: hovering)
                    .fixedSize()
                    .onHover { hovering = $0 }
                    .scaleEffect(scale)
            }
            .frame(height: stageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .animation(.spring(duration: 0.4, bounce: 0.12), value: style)

            HStack(spacing: 6) {
                Circle().fill(live?.playing == true ? Palette.accent : Palette.inkSecondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(statusText(live)).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            .padding(.leading, 4)
        }
    }

    /// Big covers are shown smaller so the whole widget fits.
    private var scale: CGFloat {
        let tall = style.layout == .vertical ? style.artworkSize + 150 : style.artworkSize + 40
        return min(1, (stageHeight - 30) / max(1, tall))
    }

    private var stageHeight: CGFloat { 280 }

    private func statusText(_ live: WidgetContent?) -> String {
        if case .unavailable(let m) = NowPlaying.shared.status, live == nil { return m.loc }
        guard let live else { return "Nothing is playing — this is a sample.".loc }
        let app = live.appName ?? "an app".loc
        return (live.playing ? "Playing in %@" : "Paused in %@").loc(app)
    }
}

// MARK: - Themes

private struct ThemesSection: View {
    let style: WidgetStyle
    let apply: (WidgetStyle) -> Void
    @State private var saved = WidgetTheme.saved()
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Themes")
                Spacer()
                Button("Save This Look…") { name = ""; naming = true }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(WidgetTheme.builtIns + saved) { theme in
                        ThemeCard(theme: theme, selected: style.sameLook(as: theme.style)) { apply(style.applyingLook(of: theme.style)) }
                            .contextMenu {
                                if !theme.builtIn {
                                    Button("Delete", role: .destructive) {
                                        saved.removeAll { $0.id == theme.id }
                                        WidgetTheme.save(saved)
                                    }
                                }
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .alert("Save This Look", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Save") {
                let n = name.trimmingCharacters(in: .whitespaces)
                saved.append(WidgetTheme(id: UUID().uuidString, name: n.isEmpty ? "My Look".loc : n, style: style))
                WidgetTheme.save(saved)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ThemeCard: View {
    let theme: WidgetTheme
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.2, green: 0.22, blue: 0.34), Color(red: 0.3, green: 0.18, blue: 0.26)], startPoint: .top, endPoint: .bottom))
                    NowPlayingWidgetView(style: theme.style, content: .sample)
                        .fixedSize()
                        .scaleEffect(thumbScale)
                        .allowsHitTesting(false)
                }
                .frame(width: 150, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Palette.accent : Palette.hairline, lineWidth: selected ? 2 : 1))
                Text(theme.builtIn ? theme.name.loc : theme.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.ink : Palette.inkSecondary)
                    .lineLimit(1)
            }
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var thumbScale: CGFloat {
        let s = theme.style
        let w: Double = switch s.layout {
        case .horizontal: s.artworkSize + s.textWidth + 40
        case .vertical: max(s.artworkSize, s.textWidth) + 30
        case .artwork: s.artworkSize
        case .pill: s.artworkSize + s.textWidth + 110
        }
        let h: Double = switch s.layout {
        case .vertical: s.artworkSize + 150
        case .pill: s.artworkSize + 12
        default: s.artworkSize + 30
        }
        return min(0.6, 140 / w, 86 / h)
    }
}

// MARK: - Controls

private struct SliderRow: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        SettingsRow(title: title, symbol: symbol) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(width: 160)
                Text(unit == "%" ? "\(Int((value * 100).rounded()))%" : "\(Int(value.rounded()))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var subtitle: String?
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// A little screen with nine spots; the widget's corner of it is orange.
private struct AnchorPicker: View {
    let anchor: WidgetStyle.Anchor
    let pick: (WidgetStyle.Anchor) -> Void

    var body: some View {
        let rows: [[WidgetStyle.Anchor]] = [[.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight]]
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 4) {
                    ForEach(rows[r], id: \.self) { a in
                        Button { pick(a) } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(a == anchor ? Palette.accent : Palette.ink.opacity(0.14))
                                .frame(width: 22, height: 13)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
        .animation(.spring(duration: 0.25, bounce: 0.2), value: anchor)
    }
}

private struct DisplayMenu: View {
    @Binding var selection: String

    var body: some View {
        let screens = NSScreen.screens
        Menu {
            Button("Main Display") { selection = "" }
            if screens.count > 1 {
                Divider()
                ForEach(screens.dropFirst(), id: \.localizedName) { s in
                    Button(s.localizedName) { selection = s.localizedName }
                }
            }
        } label: {
            Text(selection.isEmpty ? "Main Display".loc : selection)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Status

/// Where the widget is, or why it isn't showing.
private struct WidgetStatus: View {
    var body: some View {
        let np = NowPlaying.shared
        let style = NowPlayingWidgetController.shared.state.style
        let (symbol, text, problem): (String, String, Bool) = {
            if case .unavailable(let m) = np.status { return ("exclamationmark.triangle.fill", m, true) }
            if np.track == nil {
                return ("music.note", style.hideWhenIdle ? "The widget appears as soon as a music app plays." : "Nothing is playing — the widget says so.", false)
            }
            return (style.level == .desktop ? "menubar.dock.rectangle" : "macwindow.on.rectangle",
                    style.level == .desktop ? "On your desktop, under your windows." : "Floating above your windows.", false)
        }()
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(problem ? Palette.accent : Palette.inkSecondary)
            Text(text.loc).font(.orbitCaption).foregroundStyle(problem ? Palette.ink : Palette.inkSecondary)
            Spacer()
            if np.track != nil {
                Button("Show Me") { NowPlayingWidgetController.shared.flash() }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
        .padding(.top, -14)
    }
}

// MARK: - Sources

/// Which apps the widget, banner and notch follow.
private struct SourcesSection: View {
    @AppStorage(NowPlayingPrefs.sources) private var sources = "music"
    @State private var excluded = Pref.defaults.stringArray(forKey: NowPlayingPrefs.excluded) ?? []

    var body: some View {
        SettingsGroup(title: "Show from", footer: sources == "music" ? "Music apps like Music, Spotify, TIDAL and Podcasts, and music in a browser such as YouTube Music. Other videos in browsers are left out: choose All for YouTube videos too." : nil) {
            SettingsRow(title: "Show from", symbol: "music.note.house") {
                ChipPicker(selection: Binding(get: { sources }, set: { sources = $0; NowPlaying.shared.sourcesChanged() }),
                           options: [("music", "Music apps only"), ("all", "Everything")])
            }
            ForEach(excluded, id: \.self) { bundle in
                RowDivider()
                SettingsRow(title: NowPlaying.appName(for: bundle) ?? bundle, subtitle: "Never shown", icon: Self.icon(bundle)) {
                    Button { set(excluded.filter { $0 != bundle }) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show this app again".loc)
                }
            }
            RowDivider()
            SettingsRow(title: "Skip an app", subtitle: "Its songs and videos never show.", symbol: "nosign") {
                Menu {
                    if let last = NowPlaying.shared.lastSource, !excluded.contains(last.bundle) {
                        Button("Skip %@ (playing now)".loc(last.name)) { set(excluded + [last.bundle]) }
                        Divider()
                    }
                    ForEach(Self.candidates(excluding: excluded), id: \.0) { bundle, name in
                        Button(name) { set(excluded + [bundle]) }
                    }
                } label: { Text("Choose…".loc) }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func set(_ list: [String]) {
        excluded = list
        Pref.defaults.set(list, forKey: NowPlayingPrefs.excluded)
        NowPlaying.shared.sourcesChanged()
    }

    private static func icon(_ bundle: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Running apps with a window, by name.
    private static func candidates(excluding: [String]) -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !excluding.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

/// Music pauses for a video and comes back after.
private struct AutoPauseSection: View {
    @State private var on = NowPlayingPrefs.autoPauseOn
    @AppStorage(NowPlayingPrefs.autoPauseCalls) private var calls = false
    @State private var excluded = Pref.defaults.stringArray(forKey: NowPlayingPrefs.autoPauseExcluded) ?? []

    var body: some View {
        SettingsGroup(title: "Videos", footer: on ? "Works with YouTube in any browser, video players and other apps with sound. Music you paused or changed yourself is left alone." : nil) {
            SettingsRow(title: "Pause music while a video plays", subtitle: "Music, Spotify and other music apps pause when a video starts, and pick up again a moment after it stops.", symbol: "pause.rectangle") {
                Toggle("", isOn: Binding(get: { on }, set: { value in
                    on = value
                    Pref.defaults.set(value, forKey: NowPlayingPrefs.autoPause)
                    NowPlayingLog.write("\(NowPlayingPrefs.autoPause) \(value ? "on" : "off")")
                    MediaDucker.shared.reset()
                    NowPlaying.shared.update()
                })).toggleStyle(.switch).labelsHidden()
            }
            if on {
                RowDivider()
                SettingsRow(title: "Pause during calls too", subtitle: "FaceTime, Zoom, Teams, Discord and other call apps.", symbol: "phone") {
                    Toggle("", isOn: $calls).toggleStyle(.switch).labelsHidden()
                }
                ForEach(excluded, id: \.self) { bundle in
                    RowDivider()
                    SettingsRow(title: NowPlaying.appName(for: bundle) ?? bundle, subtitle: "Never pauses the music", icon: Self.icon(bundle)) {
                        Button { set(excluded.filter { $0 != bundle }) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Pause for this app again".loc)
                    }
                }
                RowDivider()
                SettingsRow(title: "Ignore an app", subtitle: "Its sound never pauses the music.", symbol: "speaker.slash") {
                    Menu {
                        ForEach(Self.candidates(excluding: excluded), id: \.0) { bundle, name in
                            Button(name) { set(excluded + [bundle]) }
                        }
                    } label: { Text("Choose…".loc) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private func set(_ list: [String]) {
        excluded = list
        Pref.defaults.set(list, forKey: NowPlayingPrefs.autoPauseExcluded)
    }

    private static func icon(_ bundle: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Running apps with a window, music apps left out.
    private static func candidates(excluding: [String]) -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !excluding.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier && !NowPlaying.musicApps.contains($0.0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}

// MARK: - Automation

@MainActor @Observable
private final class AutomationState {
    var status: [ScriptedPlayers.App: ScriptedPlayers.Permission] = [:]

    func refresh() {
        Task {
            for app in ScriptedPlayers.App.allCases { status[app] = await ScriptedPlayers.permission(app, ask: false) }
        }
    }

    /// Asks macOS for each running player now, rather than on the first song.
    func ask() async {
        for app in ScriptedPlayers.App.allCases { status[app] = await ScriptedPlayers.permission(app, ask: app.isRunning) }
    }
}

private struct AutomationRow: View {
    let app: ScriptedPlayers.App
    let status: ScriptedPlayers.Permission

    var body: some View {
        SettingsRow(title: app.scriptName, subtitle: subtitle, icon: icon) {
            if status == .denied {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            } else if status == .allowed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
            }
        }
    }

    private var subtitle: String {
        switch status {
        case .allowed: "Allowed"
        case .denied: "Not allowed — turn Orbit on under Automation in System Settings."
        case .notAsked: "macOS asks the first time it’s used."
        case .notRunning: "Asks when it’s open."
        case .unknown: "Checking…"
        }
    }

    private var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
