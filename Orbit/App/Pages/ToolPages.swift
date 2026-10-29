import AppKit
import SwiftUI

// MARK: - Translate

struct TranslatePage: View {
    @AppStorage(Pref.translateDoubleCopy) private var doubleCopy = true
    @AppStorage(Pref.translateInterval) private var interval = 0.4
    @AppStorage(Pref.translateEngine) private var engine = "google"
    @AppStorage(Pref.translatePrimary) private var primary = "ko"
    @AppStorage(Pref.translateSecondary) private var secondary = "en"
    @AppStorage(Pref.translateFormality) private var formality = "auto"
    @AppStorage(Pref.translateFontSize) private var fontSize = 16.0
    @AppStorage(Pref.translateShowSource) private var showSource = true
    @AppStorage(Pref.translateCloseOnBlur) private var closeOnBlur = true
    @State private var key = TranslateController.deeplKey
    @State private var sample = "Orbit keeps every tool one gesture away."
    private var deepLRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.linguee.DeepLCopyTranslator").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Translate", subtitle: "Press ⌘C twice on any text to translate it in place.")

            if deepLRunning && doubleCopy {
                SettingsGroup {
                    SettingsRow(title: "DeepL is running", subtitle: "It also listens for ⌘C ⌘C, so both would open. Quit DeepL, or turn this off.",
                                symbol: "exclamationmark.triangle") {
                        Button("Quit DeepL") {
                            NSRunningApplication.runningApplications(withBundleIdentifier: "com.linguee.DeepLCopyTranslator").forEach { $0.terminate() }
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            TryTranslate(sample: $sample)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Engine")
                HStack(spacing: 12) {
                    ForEach(TranslationEngine.available) { e in
                        EngineCard(engine: e, selected: engine == e.rawValue) {
                            withAnimation(.spring(duration: 0.3)) { engine = e.rawValue }
                        }
                    }
                }
                if engine == TranslationEngine.deepl.rawValue {
                    SettingsGroup(footer: "Sign up at deepl.com/pro-api for the free plan. The key stays in your keychain.") {
                        SettingsRow(title: "DeepL API key", symbol: "key") {
                            SecureField("xxxxxxxx-xxxx-…:fx", text: $key)
                                .textFieldStyle(.roundedBorder).frame(width: 260)
                                .onChange(of: key) { TranslateController.deeplKey = key }
                            Button("Get a Key") { NSWorkspace.shared.open(URL(string: "https://www.deepl.com/pro-api")!) }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                        RowDivider()
                        SettingsRow(title: "Tone", subtitle: "Formal or casual wording, where DeepL supports it.", symbol: "text.bubble") {
                            ChipPicker(selection: $formality, options: [("auto", "Auto"), ("formal", "Formal"), ("casual", "Casual")])
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            SettingsGroup(title: "Languages", footer: "Text already in your language is translated to the second one instead.") {
                SettingsRow(title: "Translate into", symbol: "globe") { languageMenu($primary) }
                RowDivider()
                SettingsRow(title: "When it’s already in that language", symbol: "arrow.left.arrow.right") { languageMenu($secondary) }
            }

            SettingsGroup(title: "Trigger") {
                SettingsRow(title: "⌘C twice", subtitle: "Needs Accessibility to notice the keys.", symbol: "command") {
                    Toggle("", isOn: $doubleCopy).toggleStyle(.switch).labelsHidden()
                        .onChange(of: doubleCopy) { TranslateController.shared.start() }
                }
                RowDivider()
                SettingsRow(title: "Double-press speed", subtitle: "How quickly the second ⌘C must follow.", symbol: "speedometer") {
                    ChipPicker(selection: $interval, options: [(0.3, "Fast"), (0.4, "Normal"), (0.6, "Relaxed")])
                }
                RowDivider()
                SettingsRow(title: "Shortcut", subtitle: "Translates whatever is on the clipboard.", symbol: "keyboard") {
                    ShortcutKeys(text: OrbitAction.translate.shortcutLabel)
                }
            }

            SettingsGroup(title: "Card") {
                SettingsRow(title: "Text size", symbol: "textformat.size") {
                    ChipPicker(selection: $fontSize, options: [(14.0, "S"), (16.0, "M"), (19.0, "L"), (23.0, "XL")])
                }
                RowDivider()
                SettingsRow(title: "Show original text", symbol: "text.quote") {
                    Toggle("", isOn: $showSource).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Close when clicking elsewhere", symbol: "xmark.circle") {
                    Toggle("", isOn: $closeOnBlur).toggleStyle(.switch).labelsHidden()
                }
            }
        }
        .animation(.spring(duration: 0.3), value: engine)
    }

    private func languageMenu(_ binding: Binding<String>) -> some View {
        Picker("", selection: binding) {
            ForEach(TranslationLanguage.all) { Text($0.name).tag($0.code) }
        }
        .labelsHidden().fixedSize()
    }
}

private struct EngineCard: View {
    let engine: TranslationEngine
    let selected: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(engine.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(selected ? Palette.accent : Palette.inkSecondary.opacity(0.5))
                }
                Text(engine.detail.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .card(active: selected)
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }
}

/// Type or paste something and see the card without leaving the page.
private struct TryTranslate: View {
    @Binding var sample: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.bubble.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
            TextField("Type something to try…", text: $sample)
                .textFieldStyle(.plain).font(.system(size: 14))
                .onSubmit { TranslateController.shared.show(sample) }
            Button("Translate") { TranslateController.shared.show(sample) }
                .buttonStyle(PillButtonStyle())
                .disabled(sample.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .card()
    }
}

// MARK: - Korean input (Tavi)

struct InputPage: View {
    private var tavi: TaviBridge { .shared }
    @State private var raw = ""
    @State private var text = ""
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Korean Input", subtitle: "Type without switching 한/영 — Tavi decides per word.")

            TaviHero(tavi: tavi)

            if tavi.installedVersion != nil {
                SettingsGroup(title: "Typing") {
                    SettingsRow(title: "Automatic 한/영", subtitle: "Off hands typing back to your previous keyboard.", symbol: "wand.and.stars") {
                        Toggle("", isOn: Binding(get: { tavi.enabled }, set: { tavi.enabled = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Learn my spellings", subtitle: "A spelling you confirm three times becomes the default.", symbol: "brain") {
                        Toggle("", isOn: Binding(get: { tavi.learning }, set: { tavi.learning = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                }

                SettingsGroup(title: "Tavi updates") {
                    SettingsRow(title: "Tavi %@".loc(tavi.installedVersion ?? ""), subtitle: taviUpdateSummary, symbol: "arrow.down.circle") {
                        if tavi.updateState == .checking || tavi.updateState == .downloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Check Now") { Task { await tavi.checkForUpdate(userInitiated: true) } }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                    RowDivider()
                    SettingsRow(title: "Update Tavi automatically", subtitle: "Checks Tavi’s releases a minute after launch, then daily. Each update is verified before it’s installed.", symbol: "clock.arrow.circlepath") {
                        Toggle("", isOn: Binding(get: { tavi.autoUpdate }, set: { tavi.autoUpdate = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel("My words")
                        Spacer()
                        Text("%ld words".loc(tavi.words.count)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                    }
                    HStack(spacing: 8) {
                        TextField("Keys typed (e.g. 3xhaust)", text: $raw).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(Palette.inkSecondary)
                        TextField("Becomes (e.g. 3Xhaust)", text: $text).textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                        Button("Add", action: add).buttonStyle(PillButtonStyle()).disabled(raw.isEmpty || text.isEmpty)
                    }
                    .padding(14).card()

                    if !tavi.words.isEmpty {
                        SettingsGroup {
                            TextField("Filter", text: $filter).textFieldStyle(.plain).padding(.horizontal, 16).frame(height: 36)
                            ForEach(shown) { word in
                                RowDivider()
                                HStack(spacing: 10) {
                                    Text(word.raw).font(.system(size: 13, design: .monospaced)).foregroundStyle(Palette.inkSecondary)
                                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                                    Text(word.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                                    Spacer()
                                    Text("×\(word.confirmations)").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                                    Button { withAnimation { tavi.remove(word) } } label: {
                                        Image(systemName: "trash").font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary).help("Remove".loc)
                                }
                                .padding(.horizontal, 16).frame(height: 38)
                            }
                        }
                    }
                }
            }

            if tavi.standaloneAppInstalled && tavi.installedVersion != nil {
                SettingsGroup(footer: "Orbit installs and updates the input method itself. Your words stay put.") {
                    SettingsRow(title: "The separate Tavi app isn’t needed anymore", symbol: "checkmark.seal") {
                        Button("Move Tavi.app to Trash") {
                            NSWorkspace.shared.recycle([URL(fileURLWithPath: "/Applications/Tavi.app")]) { _, _ in
                                Task { @MainActor in TaviBridge.shared.refresh() }
                            }
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }
        }
        .onAppear { tavi.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tavi.refresh() }
    }

    private var taviUpdateSummary: String {
        switch tavi.updateState {
        case .checking: "Checking…".loc
        case .downloading: "Updating Tavi…".loc
        case .upToDate: "Tavi is up to date".loc
        case .failed(let message): message
        case .idle: "From Tavi’s GitHub releases".loc
        }
    }

    private var shown: [TaviBridge.Word] {
        let f = filter.lowercased()
        let list = f.isEmpty ? tavi.words : tavi.words.filter { $0.raw.lowercased().contains(f) || $0.text.lowercased().contains(f) }
        return Array(list.prefix(200))
    }

    private func add() {
        tavi.setWord(raw: raw, text: text)
        raw = ""
        text = ""
    }
}

private struct TaviHero: View {
    let tavi: TaviBridge

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                demo("dkssudgktpdy", "안녕하세요")
                demo("APIfmf", "API를")
                demo("gksdudwjsghks", "한영전환")
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.raised))

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions }.padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .card(active: tavi.status == .ready, radius: 18)
    }

    private func demo(_ keys: String, _ out: String) -> some View {
        HStack(spacing: 8) {
            Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.inkSecondary)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent)
            Text(out).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
        }
    }

    private var title: String {
        switch tavi.status {
        case .notInstalled: "Install Tavi".loc
        case .updateAvailable: "Update available".loc
        case .needsAdding: "Add Tavi in Keyboard Settings".loc
        case .ready: tavi.isSelected ? "Tavi is typing".loc : "Tavi is installed".loc
        case .working(let s): s
        case .failed: "Something went wrong".loc
        }
    }

    private var detail: String {
        switch tavi.status {
        case .notInstalled: "Orbit includes Tavi. Installing takes a second; macOS then asks you to add it once.".loc
        case .updateAvailable(let v): "Version %@ is ready to install.".loc(v)
        case .needsAdding: "One step only you can do: in Keyboard Settings, Text Input › Edit… › + › Korean › Tavi › Add. Orbit switches to Tavi as soon as it’s added.".loc
        case .ready: tavi.isSelected ? "Version %@. Everything runs on this Mac.".loc(tavi.installedVersion ?? "") : "Pick Tavi from the input menu, or switch here.".loc
        case .working: "".loc
        case .failed(let message): message
        }
    }

    @ViewBuilder private var actions: some View {
        switch tavi.status {
        case .notInstalled, .failed:
            Button("Install") { Task { await tavi.install() } }.buttonStyle(PillButtonStyle()).disabled(tavi.bundledVersion == nil)
        case .updateAvailable:
            Button("Update") { Task { await tavi.install() } }.buttonStyle(PillButtonStyle())
        case .needsAdding:
            Button("Open Keyboard Settings") { tavi.openKeyboardSettings() }.buttonStyle(PillButtonStyle())
        case .ready:
            if !tavi.isSelected { Button("Use Tavi Now") { tavi.select() }.buttonStyle(PillButtonStyle()) }
            Button("Keyboard Settings") { tavi.openKeyboardSettings() }.buttonStyle(PillButtonStyle(prominent: false))
        case .working:
            ProgressView().controlSize(.small)
        }
    }
}

// MARK: - Menu bar

/// What the menu bar will show, drawn with the real icon.
private struct CalendarLookRow: View {
    @Binding var shape: String
    @Binding var style: String
    let month: Bool
    let weekday: Bool
    let format: String

    var body: some View {
        let now = Date()
        let image = MenuBarCalendar.icon(MenuBarCalendar.IconShape(rawValue: shape) ?? .outline, date: now, month: month, weekday: weekday)
        let text = MenuBarCalendar.text(for: now, style: .init(stored: style), custom: format)
        HStack(spacing: 6) {
            Spacer()
            if let image { Image(nsImage: image).renderingMode(.template) }
            if let text { Text(text).font(.system(size: 13, weight: .medium)) }
            if image == nil, text == nil, let fallback = MenuBarCalendar.icon(.outline, date: now, month: false, weekday: false) {
                Image(nsImage: fallback).renderingMode(.template)
            }
            Text(now.formatted(.dateTime.hour().minute())).font(.system(size: 13, weight: .medium)).opacity(0.35)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 14).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .animation(.spring(duration: 0.25), value: [shape, style, format])
    }
}

/// Itsycal-style choice of glyph, each option drawn as it will look.
private struct IconShapePicker: View {
    @Binding var selection: String
    let month: Bool
    let weekday: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MenuBarCalendar.IconShape.allCases, id: \.rawValue) { shape in
                let on = selection == shape.rawValue
                Button { withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = shape.rawValue } } label: {
                    Group {
                        if let image = MenuBarCalendar.icon(shape, date: Date(), month: false, weekday: false) {
                            Image(nsImage: image).renderingMode(.template)
                        } else {
                            Text("Text only".loc).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(on ? Palette.canvas : Palette.ink)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background { if on { Capsule().fill(Palette.ink).matchedGeometryEffect(id: "shape", in: ns) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.raised))
    }
}

struct MenuBarPage: View {
    @AppStorage(Pref.calendarEnabled) private var calendar = true
    @AppStorage(Pref.calendarStyle) private var style = "date"
    @AppStorage(Pref.calendarIcon) private var iconShape = "none"
    @AppStorage(Pref.calendarIconMonth) private var iconMonth = false
    @AppStorage(Pref.calendarIconWeekday) private var iconWeekday = false
    @AppStorage(Pref.calendarFormat) private var format = ""
    @AppStorage(Pref.calendarEvents) private var events = true
    @AppStorage(Pref.calendarWeekStart) private var monday = false
    @AppStorage(Pref.hiderEnabled) private var hider = false
    @AppStorage(Pref.hiderAutoCollapse) private var autoCollapse = 10
    @AppStorage(Pref.hiderStyle) private var hiderStyle = "bar"
    @AppStorage(Pref.hideSystemOverflow) private var hideOverflow = true
    @AppStorage(Pref.hiderIcon) private var hiderIcon = "sparkle"
    @AppStorage(Pref.hideNewItems) private var hideNew = true
    @Bindable private var removal = MenuBarRemoval.shared

    private var barbeeRunning: Bool { NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Barbee" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Menu Bar", subtitle: "Hide and arrange menu bar icons, and keep a calendar up there.")

            if hider, !removal.permitted { FullDiskAccessCard(removal: removal) }

            SettingsGroup(title: "Hide icons", footer: removal.active
                          ? "Hidden icons are switched off in macOS itself — gone from the menu bar, in full screen and on every Space. Click Orbit’s button to use one for a moment."
                          : "Hold ⌘ and drag icons to the left of the divider. Click the arrow to show or hide them.") {
                SettingsRow(title: "Hide menu bar icons", subtitle: removal.active ? "Adds one button to the menu bar for the hidden icons." : "Adds an arrow and a divider to the menu bar.", symbol: "chevron.compact.left") {
                    Toggle("", isOn: $hider).toggleStyle(.switch).labelsHidden()
                        .onChange(of: hider) { MenuBarHider.shared.apply() }
                }
                if hider, !removal.active {
                    RowDivider()
                    SettingsRow(title: "Show hidden icons", subtitle: hiderStyle == "bar" ? "In a bar under the menu bar — handy with the notch." : "Unfolded in the menu bar.", symbol: "rectangle.topthird.inset.filled") {
                        ChipPicker(selection: $hiderStyle, options: [("bar", "Below"), ("inline", "In place")])
                            .onChange(of: hiderStyle) { MenuBarHider.shared.foldForBar() }
                    }
                    RowDivider()
                    SettingsRow(title: "Hide macOS’s « button", subtitle: "macOS shows it when icons don’t fit. Orbit covers it, and clicking there opens Orbit’s bar — including icons macOS tucked away.", symbol: "chevron.left.2") {
                        Toggle("", isOn: $hideOverflow).toggleStyle(.switch).labelsHidden()
                            .onChange(of: hideOverflow) { OverflowCover.shared.apply() }
                    }
                }
                if hider {
                    RowDivider()
                    SettingsRow(title: "Button", subtitle: "What you click in the menu bar to see hidden icons.", symbol: "cursorarrow.click") {
                        HStack(spacing: 4) {
                            ForEach(MenuBarHider.icons, id: \.self) { icon in
                                Button { hiderIcon = icon } label: {
                                    Group {
                                        if let image = MenuBarHider.image(for: icon, collapsed: true) {
                                            Image(nsImage: image).renderingMode(.template)
                                        }
                                    }
                                    .foregroundStyle(hiderIcon == icon ? Palette.canvas : Palette.ink)
                                    .frame(width: 28, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hiderIcon == icon ? Palette.ink : Palette.raised))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                            }
                        }
                        .animation(.spring(duration: 0.25), value: hiderIcon)
                        .onChange(of: hiderIcon) { MenuBarHider.shared.updateToggleImage() }
                    }
                    if removal.active {
                        RowDivider()
                        SettingsRow(title: "Hide new icons automatically", subtitle: "When an app puts an icon in the menu bar for the first time, it goes straight to Hidden.", symbol: "eye.slash") {
                            Toggle("", isOn: $hideNew).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    if !removal.active {
                        RowDivider()
                        SettingsRow(title: "Hide again after", symbol: "timer") {
                            ChipPicker(selection: $autoCollapse, options: [(0, "Never"), (5, "5s"), (10, "10s"), (30, "30s")])
                        }
                    }
                    RowDivider()
                    SettingsRow(title: "Show hidden icons now", symbol: "eye") {
                        Button("Show") { MenuBarHider.shared.showHidden() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: hider)
            .onAppear { removal.checkPermission() }

            if hider {
                MenuBarLayoutEditor()
            } else {
                HiderDiagram()
            }

            if barbeeRunning {
                SettingsGroup {
                    SettingsRow(title: "Barbee is managing the menu bar", subtitle: "It hides new icons — including Orbit’s calendar — in its own bar, and fights Orbit over the same icons. Quit it to let Orbit take over.", symbol: "exclamationmark.triangle") {
                        Button("Quit Barbee") {
                            NSWorkspace.shared.runningApplications.filter { $0.localizedName == "Barbee" }.forEach { $0.terminate() }
                        }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            SettingsGroup(title: "Calendar") {
                SettingsRow(title: "Show calendar", subtitle: "Click it for the month and your events.", symbol: "calendar") {
                    Toggle("", isOn: $calendar).toggleStyle(.switch).labelsHidden()
                        .onChange(of: calendar) { MenuBarCalendar.shared.apply() }
                }
                if calendar {
                    RowDivider()
                    CalendarLookRow(shape: $iconShape, style: $style, month: iconMonth, weekday: iconWeekday, format: format)
                    RowDivider()
                    SettingsRow(title: "Icon", symbol: "calendar") {
                        IconShapePicker(selection: $iconShape, month: iconMonth, weekday: iconWeekday)
                    }
                    if iconShape == "filled" || iconShape == "outline" {
                        RowDivider()
                        SettingsRow(title: "Month in the icon", symbol: "m.square") {
                            Toggle("", isOn: $iconMonth).toggleStyle(.switch).labelsHidden()
                        }
                        RowDivider()
                        SettingsRow(title: "Weekday in the icon", symbol: "w.square") {
                            Toggle("", isOn: $iconWeekday).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    RowDivider()
                    SettingsRow(title: "Text beside it", symbol: "textformat") {
                        ChipPicker(selection: $style, options: [("none", "None"), ("weekday", "Day"), ("date", "Date"), ("dateTime", "Date & time"), ("custom", "Custom")])
                    }
                    if style == "custom" {
                        RowDivider()
                        SettingsRow(title: "Format", subtitle: "Date pattern, e.g. M월 d일 (E) a h:mm", symbol: "curlybraces") {
                            HStack(spacing: 6) {
                                TextField("M월 d일 (E)", text: $format)
                                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 10).frame(width: 190, height: 28)
                                    .background(Capsule().fill(Palette.raised))
                                Menu {
                                    ForEach(["M월 d일 (E)", "M/d E", "E a h:mm", "HH:mm", "yyyy.MM.dd", "MMM d, E HH:mm"], id: \.self) { p in
                                        Button("\(p)   →   \(MenuBarCalendar.text(for: Date(), style: .custom, custom: p) ?? "")") { format = p }
                                    }
                                } label: {
                                    Image(systemName: "questionmark").font(.system(size: 11, weight: .bold))
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Examples".loc)
                            }
                        }
                    }
                    RowDivider()
                    SettingsRow(title: "Show events", subtitle: "From the calendars in the Calendar app.", symbol: "list.bullet.rectangle") {
                        Toggle("", isOn: $events).toggleStyle(.switch).labelsHidden()
                            .onChange(of: events) { if events { MenuBarCalendar.shared.requestAccess() } }
                    }
                    RowDivider()
                    SettingsRow(title: "Week starts on Monday", symbol: "calendar.day.timeline.left") {
                        Toggle("", isOn: $monday).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: calendar)
            .animation(.spring(duration: 0.3), value: iconShape)
            .animation(.spring(duration: 0.3), value: style)
            .onChange(of: [iconShape, style, format]) {
                // Text only with no text would leave nothing to click.
                if iconShape == "none", style == "none" { style = "date" }
                MenuBarCalendar.shared.render()
            }
            .onChange(of: [iconMonth, iconWeekday]) { MenuBarCalendar.shared.render() }
        }
    }
}

/// How the divider works, drawn as a little menu bar.
private struct HiderDiagram: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(["cloud", "bolt.horizontal", "music.note"], id: \.self) { s in
                    Image(systemName: s).foregroundStyle(Palette.inkSecondary.opacity(0.5))
                }
                Capsule().fill(Palette.ink.opacity(0.5)).frame(width: 1.5, height: 14)
                Image(systemName: "chevron.compact.right").foregroundStyle(Palette.accent)
                ForEach(["wifi", "battery.75percent", "calendar"], id: \.self) { s in
                    Image(systemName: s).foregroundStyle(Palette.ink)
                }
                Spacer()
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            HStack(spacing: 6) {
                Text("Hidden").foregroundStyle(Palette.inkSecondary)
                Text("·")
                Text("Always visible").foregroundStyle(Palette.ink)
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(16)
        .card()
    }
}

/// The one step real hiding needs: Full Disk Access. Up top and impossible to miss while it's
/// missing; Orbit notices the grant by itself (checking only while this card is on screen).
private struct FullDiskAccessCard: View {
    let removal: MenuBarRemoval

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.open.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 34, height: 34).background(Circle().fill(Palette.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("One step to remove icons completely").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("Allow Full Disk Access and hidden icons are switched off in macOS itself — no « button, nothing to flicker in full screen or across Spaces.")
                        .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open Full Disk Access")
                step(2, "Turn Orbit on (or drag it into the list)")
                step(3, "Come back — Orbit switches over by itself")
            }
            HStack(spacing: 8) {
                Button("Open Full Disk Access") { MenuBarAgentPrefs.openFullDiskAccessSettings() }
                    .buttonStyle(PillButtonStyle())
                Button("Show Orbit in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.accent.opacity(0.55), lineWidth: 1))
        .task {
            while !Task.isCancelled, !removal.permitted {
                try? await Task.sleep(for: .seconds(1))
                removal.checkPermission()
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.canvas)
                .frame(width: 16, height: 16).background(Circle().fill(Palette.ink))
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.ink)
        }
    }
}
