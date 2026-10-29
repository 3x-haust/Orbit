import AVFoundation
import AppKit
import SwiftUI
import KeyboardShortcuts
import ServiceManagement

// MARK: - Capture

struct CapturePage: View {
    @AppStorage(Pref.captureAutoCopy) private var autoCopy = true
    @AppStorage(Pref.captureSound) private var sound = true
    @AppStorage(Pref.captureThumbnailSeconds) private var seconds = 8.0
    @AppStorage(Pref.captureThumbnailCorner) private var corner = "bottomLeft"
    @AppStorage(Pref.captureSaveFolder) private var folder = ""
    @AppStorage(Pref.recordFPS) private var fps = 60
    @AppStorage(Pref.recordCursor) private var recordCursor = true
    @AppStorage(Pref.recordClicks) private var recordClicks = true
    @AppStorage(Pref.recordSystemAudio) private var systemAudio = false
    @AppStorage(Pref.recordMic) private var mic = false
    @AppStorage(Pref.recordCountdown) private var countdown = 3
    @AppStorage(Pref.recordOpen) private var openAfter = "none"
    @AppStorage(Pref.timedCaptureSeconds) private var timerSeconds = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Capture", subtitle: "Screenshots, annotation, pinning and text recognition.")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach([OrbitAction.captureArea, .captureWindow, .captureScreen, .captureText]) { ActionCard(action: $0) }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Recent")
                    Spacer()
                    Button { CaptureLibrary.shared.show() } label: {
                        Label("Show All", systemImage: "photo.stack").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .hoverHint("Every recent screenshot and recording — drag one into any app to attach it".loc)
                }
                RecentCaptures()
            }

            SettingsGroup(title: "Before capture") {
                SettingsRow(title: "Capture timer", subtitle: "“Capture Area with Timer” counts down this long, then lets you pick the area — open a menu in the meantime and it’s in the shot.", symbol: "timer") {
                    ChipPicker(selection: $timerSeconds, options: [(3, "3s"), (5, "5s"), (10, "10s")])
                }
            }

            SettingsGroup(title: "After capture") {
                SettingsRow(title: "Copy to clipboard", symbol: "doc.on.doc") { Toggle("", isOn: $autoCopy).toggleStyle(.switch).labelsHidden() }
                RowDivider()
                SettingsRow(title: "Play sound", symbol: "speaker.wave.2") { Toggle("", isOn: $sound).toggleStyle(.switch).labelsHidden() }
                RowDivider()
                SettingsRow(title: "Keep preview on screen", subtitle: "Hovering keeps it open.", symbol: "hourglass") {
                    ChipPicker(selection: $seconds, options: [(5.0, "5s"), (8.0, "8s"), (15.0, "15s"), (0.0, "Until closed")])
                }
                RowDivider()
                SettingsRow(title: "Preview position", subtitle: "Pick a corner. Swipe a preview toward the screen edge to dismiss it.", symbol: "rectangle.inset.bottomright.filled") {
                    HStack(spacing: 12) {
                        PreviewCornerPicker(corner: $corner)
                        Button("Preview") { QuickAccess.shared.showSample() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .hoverHint("Shows a preview in that corner for a moment".loc)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Record")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach([OrbitAction.recordArea, .recordWindow, .recordScreen]) { ActionCard(action: $0) }
                }
            }

            SettingsGroup(title: "Recording", footer: "Click the red timer in the menu bar, or press Esc in the controls, to stop. Orbit’s own controls never appear in the video.") {
                SettingsRow(title: "Frame rate", symbol: "speedometer") {
                    ChipPicker(selection: $fps, options: [(30, "30 fps"), (60, "60 fps")])
                }
                RowDivider()
                SettingsRow(title: "Show the pointer", symbol: "cursorarrow") { Toggle("", isOn: $recordCursor).toggleStyle(.switch).labelsHidden() }
                RowDivider()
                SettingsRow(title: "Highlight clicks", symbol: "cursorarrow.click.2") {
                    Toggle("", isOn: $recordClicks).toggleStyle(.switch).labelsHidden().disabled(!recordCursor)
                }
                RowDivider()
                SettingsRow(title: "Record system audio", subtitle: "Sound from your apps, without Orbit’s own.", symbol: "speaker.wave.2") {
                    Toggle("", isOn: $systemAudio).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Record microphone", subtitle: "Mute it any time from the controls.", symbol: "mic") {
                    Toggle("", isOn: $mic).toggleStyle(.switch).labelsHidden()
                        .onChange(of: mic) { _, on in
                            if on, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                            }
                        }
                }
                RowDivider()
                SettingsRow(title: "Countdown", symbol: "timer") {
                    ChipPicker(selection: $countdown, options: [(0, "Off"), (3, "3s"), (5, "5s")])
                }
                RowDivider()
                SettingsRow(title: "After recording", symbol: "play.rectangle") {
                    ChipPicker(selection: $openAfter, options: [("none", "Show preview"), ("quicktime", "Open in QuickTime")])
                }
            }

            SettingsGroup(title: "Saving") {
                SettingsRow(title: "Save to", subtitle: (folder as NSString).abbreviatingWithTildeInPath, symbol: "folder") {
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.directoryURL = URL(fileURLWithPath: folder)
                        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            SettingsGroup(title: "While selecting") {
                tip("Space", "Switch between area and window")
                RowDivider()
                tip("⇧", "Hold while dragging for a perfect square")
                RowDivider()
                tip("↩", "Capture the whole display")
                RowDivider()
                tip("Click", "Capture the window under the pointer")
            }
        }
    }

    private func tip(_ key: String, _ text: String) -> some View {
        SettingsRow(title: text) { ShortcutKeys(text: key) }
    }
}

// MARK: - Clipboard

struct ClipboardPage: View {
    @AppStorage(Pref.historyLimit) private var limit = 500
    @AppStorage(Pref.pasteDirectly) private var pasteDirectly = true
    @AppStorage(Pref.shelfEdge) private var shelfEdge = true
    @State private var ignored = Pref.defaults.stringArray(forKey: Pref.ignoredApps) ?? []
    private var store: ClipboardStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Clipboard", subtitle: "Everything you copy, searchable and one keystroke away.") {
                Button { ClipboardPanel.shared.show() } label: {
                    Label("Open History", systemImage: "rectangle.bottomhalf.filled")
                }
                .buttonStyle(PillButtonStyle())
            }

            HStack(spacing: 12) {
                kind("Text", "text.alignleft", store.items.filter { $0.kind == .text }.count)
                kind("Links", "link", store.items.filter { $0.kind == .link }.count)
                kind("Images", "photo", store.items.filter { $0.kind == .image }.count)
                kind("Files", "doc", store.items.filter { $0.kind == .file }.count)
                kind("Pinned", "pin", store.items.filter(\.pinned).count)
            }

            SettingsGroup {
                SettingsRow(title: store.paused ? "Recording is paused" : "Recording",
                            subtitle: "%ld items, stored on this Mac only.".loc(store.items.count),
                            symbol: store.paused ? "pause.circle" : "record.circle") {
                    if store.paused {
                        Button("Resume") { store.resume() }.buttonStyle(PillButtonStyle())
                    } else {
                        Menu("Pause") {
                            Button("15 minutes") { store.pause(for: 900) }
                            Button("1 hour") { store.pause(for: 3600) }
                            Button("Until I resume") { store.pause(for: nil) }
                        }
                        .fixedSize()
                    }
                }
                RowDivider()
                SettingsRow(title: "Paste directly", subtitle: "Choosing an item pastes it. Off: it's only copied.", symbol: "arrow.down.doc") {
                    Toggle("", isOn: $pasteDirectly).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Keep history", subtitle: "Pinned items are always kept.", symbol: "clock.arrow.circlepath") {
                    ChipPicker(selection: $limit, options: [(100, "100"), (500, "500"), (1000, "1K"), (5000, "5K")])
                }
                RowDivider()
                SettingsRow(title: "Clear history", subtitle: "Pinned items stay.", symbol: "trash") {
                    Button("Clear…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Clear clipboard history?".loc
                        alert.informativeText = "Pinned items stay. This can’t be undone.".loc
                        alert.addButton(withTitle: "Clear".loc)
                        alert.addButton(withTitle: "Cancel".loc)
                        if alert.runModal() == .alertFirstButtonReturn { store.clear() }
                    }
                }
            }

            // The Shelf is the clipboard for files: drop things there, take them out later.
            SettingsGroup(title: "Shelf") {
                SettingsRow(title: "Open the shelf at the screen edge", subtitle: "Drag a file to that edge of any display and the shelf slides out of it.", symbol: "tray.full") {
                    Toggle("", isOn: $shelfEdge).toggleStyle(.switch).labelsHidden()
                        .onChange(of: shelfEdge) { Shelf.shared.startEdgeReveal() }
                }
                RowDivider()
                SettingsRow(title: "Shelf position", subtitle: "Which edge of the screen it comes out of.", symbol: "rectangle.righthalf.inset.filled") {
                    ShelfEdgePicker()
                }
                RowDivider()
                SettingsRow(title: "Open the Shelf", symbol: "tray") {
                    Button("Open") { OrbitAction.shelf.perform() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            SettingsGroup(title: "Never record from", footer: "Copies that password managers mark as concealed are always skipped.") {
                ForEach(ignored, id: \.self) { id in
                    SettingsRow(title: appName(id), subtitle: id, symbol: appIcon(id) == nil ? "app.dashed" : nil, icon: appIcon(id)) {
                        Button { withAnimation(.spring(duration: 0.3)) { ignored.removeAll { $0 == id } }; save() } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 15))
                        }
                        .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary)
                    }
                    RowDivider()
                }
                SettingsRow(title: "Add app…", symbol: "plus") {
                    Button("Choose") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.directoryURL = URL(fileURLWithPath: "/Applications")
                        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !ignored.contains(id) {
                            withAnimation(.spring(duration: 0.3)) { ignored.append(id) }
                            save()
                        }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
    }

    private func kind(_ title: String, _ symbol: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            Text("\(count)").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Text(title.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func save() { Pref.defaults.set(ignored, forKey: Pref.ignoredApps) }

    private func appIcon(_ id: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    private func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }
}

// MARK: - Windows

struct WindowsPage: View {
    @AppStorage(Pref.windowGap) private var gap = 0.0
    @AppStorage(Pref.windowStageManager) private var stageAware = true
    @AppStorage(Pref.windowStageWidth) private var stageWidth = 190.0

    private static let layouts: [(OrbitAction, CGRect)] = [
        (.winLeft, CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        (.winRight, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        (.winTop, CGRect(x: 0, y: 0, width: 1, height: 0.5)),
        (.winBottom, CGRect(x: 0, y: 0.5, width: 1, height: 0.5)),
        (.winTopLeft, CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
        (.winTopRight, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)),
        (.winBottomLeft, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
        (.winBottomRight, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
        (.winFirstThird, CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)),
        (.winCenterThird, CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)),
        (.winLastThird, CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)),
        (.winMaximize, CGRect(x: 0, y: 0, width: 1, height: 1)),
        (.winCenter, CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Windows", subtitle: "Snap the frontmost window with a shortcut, or the one under your pointer with the Ring.")

            if KeyboardShortcuts.getShortcut(for: .winLeft) != nil,
               NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.knollsoft.Rectangle" }) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rectangle is running").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        Text("It uses the same shortcuts. Quit it, or change Orbit’s.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    Button("Shortcuts") { MainWindow.show(.shortcuts) }.buttonStyle(PillButtonStyle(prominent: false))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.accent.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.accent.opacity(0.35), lineWidth: 1))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(Self.layouts, id: \.0) { action, rect in LayoutTile(action: action, rect: rect, gap: gap) }
            }

            SettingsGroup(footer: "Press a half’s shortcut again and again and the window gets wider or narrower: half the screen, then two thirds, then one third.") {
                SettingsRow(title: "Gap between windows", symbol: "square.split.2x1") {
                    GapPreview(gap: gap)
                    Slider(value: $gap.animation(.spring(duration: 0.25)), in: 0...24, step: 2).frame(width: 150)
                    Text("\(Int(gap)) pt").font(.orbitCaption.monospacedDigit()).foregroundStyle(Palette.inkSecondary).frame(width: 40)
                }
                RowDivider()
                SettingsRow(title: "Leave room for Stage Manager",
                            subtitle: WindowManager.stageStrip() != nil ? "Stage Manager’s strip is showing — layouts stop beside it." : "Applies when Stage Manager shows recent apps.",
                            symbol: "sidebar.squares.left") {
                    if stageAware {
                        ChipPicker(selection: $stageWidth, options: [(150.0, "S"), (190.0, "M"), (230.0, "L")])
                    }
                    Toggle("", isOn: $stageAware.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Move to next display", symbol: "rectangle.on.rectangle") {
                    ShortcutKeys(text: OrbitAction.winNextDisplay.shortcutLabel)
                }
                RowDivider()
                SettingsRow(title: "Move to previous display", symbol: "rectangle.on.rectangle") {
                    ShortcutKeys(text: OrbitAction.winPreviousDisplay.shortcutLabel)
                }
                RowDivider()
                SettingsRow(title: "Restore previous size", symbol: "arrow.uturn.backward") {
                    ShortcutKeys(text: OrbitAction.winRestore.shortcutLabel)
                }
            }
        }
    }
}

private struct LayoutTile: View {
    let action: OrbitAction
    let rect: CGRect
    let gap: Double
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let s = geo.size
                let g = gap / 6
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.raised)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? Palette.accent : Palette.ink)
                        .frame(width: max(4, rect.width * s.width - 6 - g * 2), height: max(4, rect.height * s.height - 6 - g * 2))
                        .offset(x: rect.minX * s.width + 3 + g, y: rect.minY * s.height + 3 + g)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            Text(action.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
            ShortcutKeys(text: action.shortcutLabel).scaleEffect(0.9, anchor: .leading)
        }
        .padding(12)
        .card(hovering: hovering)
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hovering = h } }
    }
}

private struct GapPreview: View {
    let gap: Double
    var body: some View {
        HStack(spacing: gap / 4) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.ink)
            RoundedRectangle(cornerRadius: 2).fill(Palette.ink)
        }
        .padding(gap / 8)
        .frame(width: 34, height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.raised))
        .padding(.trailing, 6)
    }
}

// MARK: - Shortcuts

struct ShortcutsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Shortcuts", subtitle: "Click a shortcut, then press the keys. esc cancels, ⌫ clears.") {
                Button("Reset All") { KeyboardShortcuts.resetAll() }.buttonStyle(PillButtonStyle(prominent: false))
            }
            group("Orbit", [(.ring, "Orbit Ring", "circle.dashed"), (.launcher, "Launcher", "command"), (.clipboard, "Clipboard history", "doc.on.clipboard")])
            group("Capture", [OrbitAction.captureArea, .captureWindow, .captureScreen, .captureText, .captureRepeat, .recentCaptures].map { ($0.shortcutName!, $0.title, $0.symbol) })
            group("Record Video", [OrbitAction.recordArea, .recordWindow, .recordScreen, .stopRecording].map { ($0.shortcutName!, $0.title, $0.symbol) })
            group("Windows", OrbitAction.allCases.filter { $0.windowLayout != nil }.map { ($0.shortcutName!, $0.title, $0.symbol) })
            group("Tools", [OrbitAction.translate, .colorPicker, .captureTimed, .shelf, .keepAwake, .pinLastCapture, .hideMenuBarIcons].map { ($0.shortcutName!, $0.title, $0.symbol) })
            group("Mac", OrbitAction.allCases.filter { $0.group == "System" }.map { ($0.shortcutName!, $0.title, $0.symbol) })
        }
    }

    private func group(_ title: String, _ rows: [(KeyboardShortcuts.Name, String, String)]) -> some View {
        SettingsGroup(title: title) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { RowDivider() }
                SettingsRow(title: row.1, symbol: row.2) { ShortcutRecorder(name: row.0) }
            }
        }
    }
}

// MARK: - Permissions

struct SetupPage: View {
    private var p: Permissions { .shared }

    var body: some View {
        let done = [p.screenCapture, p.accessibility].filter { $0 }.count
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Permissions", subtitle: "Orbit works without these — only the features that need them will ask.")

            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Palette.raised, lineWidth: 8)
                    Circle().trim(from: 0, to: CGFloat(done) / 2)
                        .stroke(done == 2 ? Palette.ink : Palette.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(done)/2").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                }
                .frame(width: 76, height: 76)
                .animation(.spring(duration: 0.6, bounce: 0.2), value: done)
                VStack(alignment: .leading, spacing: 4) {
                    Text(done == 2 ? "You’re all set".loc : "Almost there".loc).font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.ink)
                    Text(done == 2 ? "Every Orbit feature is ready to use.".loc : "Allow access in System Settings. Orbit notices right away — no restart.".loc)
                        .font(.system(size: 13)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
            }
            .padding(20)
            .card(radius: 18)

            PermissionList()
        }
    }
}

/// Shared by the Permissions page and onboarding.
struct PermissionList: View {
    private var p: Permissions { .shared }

    var body: some View {
        VStack(spacing: 12) {
            PermissionCard(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                           detail: "Screenshots and copying text from the screen.",
                           granted: p.screenCapture, request: p.requestScreenCapture)
            PermissionCard(symbol: "accessibility", title: "Accessibility",
                           detail: "Window snapping, direct paste and the mouse-button Ring.",
                           granted: p.accessibility, request: p.requestAccessibility)
            PermissionCard(symbol: "doc.on.clipboard", title: "Paste from other apps",
                           detail: pasteboardText, granted: p.pasteboard == .alwaysAllow,
                           actionTitle: "Open Settings", request: { p.open(.pasteboard) })
        }
    }

    private var pasteboardText: String {
        switch p.pasteboard {
        case .alwaysAllow: "Allowed — clipboard history is recording."
        case .alwaysDeny: "Denied — clipboard history can’t see new copies."
        default: "If macOS asks, choose “Allow” so history can record."
        }
    }
}

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    var actionTitle = "Allow…"
    let request: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(granted ? Palette.canvas : Palette.ink)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(granted ? Palette.ink : Palette.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(detail.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(actionTitle.loc, action: request).buttonStyle(PillButtonStyle())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(16)
        .card(active: false)
        .animation(.spring(duration: 0.4, bounce: 0.3), value: granted)
    }
}

// MARK: - General

struct GeneralPage: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(Pref.showOrbitIcon) private var showOrbitIcon = false
    @State private var language = AppLanguage.current
    @AppStorage(Pref.systemAccent) private var systemAccent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "General")

            SettingsGroup(title: "Language", footer: language == AppLanguage.current ? nil : "Relaunch Orbit to switch languages.") {
                SettingsRow(title: "App language", symbol: "globe") {
                    ChipPicker(selection: $language, options: [("system", "System"), ("en", "English"), ("ko", "한국어")])
                        .onChange(of: language) { AppLanguage.set(language) }
                    if language != AppLanguage.current {
                        Button("Relaunch") { AppLanguage.relaunch() }.buttonStyle(PillButtonStyle())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(duration: 0.3), value: language)

            SettingsGroup(title: "Appearance", footer: "Orbit follows Light and Dark mode automatically.") {
                SettingsRow(title: "Accent color", subtitle: systemAccent ? "Following System Settings." : "Orbit orange.", symbol: "paintpalette") {
                    HStack(spacing: 8) {
                        swatch(Palette.brand, "Orbit", on: !systemAccent) { systemAccent = false }
                        swatch(Color(nsColor: .controlAccentColor), "System", on: systemAccent) { systemAccent = true }
                    }
                }
            }

            SettingsGroup(title: "Startup") {
                SettingsRow(title: "Open at login", subtitle: "Orbit lives in the menu bar and starts with your Mac.", symbol: "power") {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                        .onChange(of: launchAtLogin) { _, on in
                            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        }
                }
                RowDivider()
                SettingsRow(title: "Show Orbit icon in the menu bar", subtitle: "Off: right-click ✦, the ring or a shortcut opens Orbit.", symbol: "menubar.rectangle") {
                    Toggle("", isOn: $showOrbitIcon).toggleStyle(.switch).labelsHidden()
                        .onChange(of: showOrbitIcon) { OrbitPlanet.apply() }
                }
                RowDivider()
                SettingsRow(title: "Welcome tour", subtitle: "See the introduction again.", symbol: "sparkles") {
                    Button("Show") { OnboardingWindow.show() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            UpdatesGroup()

            HStack(spacing: 16) {
                Image(nsImage: Brand.logo).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Orbit").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    Text("Every Mac utility, all in one.")
                        .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Button("Quit Orbit") { AppQuit.now() }.buttonStyle(PillButtonStyle(prominent: false))
            }
            .padding(18)
            .card(radius: 18)
        }
    }

    private func swatch(_ color: Color, _ name: String, on: Bool, tap: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(duration: 0.3)) { tap() } } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: on ? 2 : 0).padding(-1))
                Text(name.loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(on ? Palette.canvas : Palette.ink)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(on ? Palette.ink : Palette.raised))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Updates

private struct UpdatesGroup: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        SettingsGroup(title: "Updates", footer: updater.isDevBuild ? "Development build — installing is off" : nil) {
            SettingsRow(title: "Version %@".loc(updater.currentVersion), subtitle: summary, symbol: "arrow.down.circle") {
                if case .available(let release) = updater.status {
                    Button("Release Notes") { NSWorkspace.shared.open(release.page) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    Button("Install %@".loc(release.version)) { updater.install(release) }
                        .buttonStyle(PillButtonStyle())
                        .disabled(updater.isDevBuild)
                } else {
                    Button("Check Now") { updater.checkNow(userInitiated: true) }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .disabled(updater.busy)
                }
            }
            if case .downloading = updater.status {
                UpdateStatusLine().padding(.horizontal, 16).padding(.bottom, 10)
            }
            RowDivider()
            SettingsRow(title: "Check for updates automatically", subtitle: "Looks at GitHub Releases at launch and every 6 hours.", symbol: "clock.arrow.circlepath") {
                Toggle("", isOn: $updater.autoCheck).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingsRow(title: "Install updates automatically", subtitle: "Off: Orbit asks first and shows what’s new.", symbol: "arrow.down.app") {
                Toggle("", isOn: $updater.autoInstall).toggleStyle(.switch).labelsHidden()
                    .disabled(!updater.autoCheck)
            }
        }
        .animation(.spring(duration: 0.3), value: updater.status)
    }

    private var summary: String {
        switch updater.status {
        case .checking: "Checking…".loc
        case .upToDate: "Orbit is up to date".loc
        case .noReleases: "No releases yet".loc
        case .available(let r): "Orbit %@ is available".loc(r.version)
        case .downloading(let f): "Downloading %ld%%".loc(Int(f * 100))
        case .installing: "Installing…".loc
        case .failed(let message): message
        case .idle:
            if let d = updater.lastChecked { "Last checked %@".loc(d.formatted(.relative(presentation: .named))) }
            else { "Not checked yet".loc }
        }
    }
}

// MARK: - Shared controls

/// Inline segmented chips — quicker to scan than a popup for a handful of options.
struct ChipPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { withAnimation(.spring(duration: 0.3, bounce: 0.2)) { selection = value } } label: {
                    Text(title.loc).font(.system(size: 11, weight: .semibold))
                        .fixedSize() // a chip is never cut short; the row's text wraps instead
                        .foregroundStyle(on ? Palette.canvas : Palette.inkSecondary)
                        .padding(.horizontal, 10).frame(height: 24)
                        .background { if on { Capsule().fill(Palette.ink).matchedGeometryEffect(id: "chip", in: ns) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.raised))
    }
}


/// A little screen with a preview card on it: drag the card and it snaps to the nearest corner.
/// Click a corner to put it there too.
struct PreviewCornerPicker: View {
    @Binding var corner: String
    @State private var drag: CGSize = .zero
    @State private var dragging = false

    private let screen = CGSize(width: 150, height: 94)
    private let card = CGSize(width: 34, height: 23)
    private let inset: CGFloat = 7
    private let menuBar: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.raised)
            // Menu bar with the notch.
            UnevenRoundedRectangle(topLeadingRadius: 9, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 9, style: .continuous)
                .fill(Palette.ink.opacity(0.10))
                .frame(height: menuBar)
            Capsule().fill(Palette.ink.opacity(0.55))
                .frame(width: 26, height: 5)
                .offset(x: (screen.width - 26) / 2, y: 0)

            // Corner targets: faint until dragging, then the nearest one lights up.
            ForEach(QuickAccess.corners, id: \.self) { c in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(c == target ? Palette.accent : Palette.ink.opacity(dragging ? 0.3 : 0.12))
                    .frame(width: card.width, height: card.height)
                    .offset(origin(for: c))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(duration: 0.35, bounce: 0.3)) { corner = c } }
            }

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.ink)
                .overlay(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Palette.canvas.opacity(0.35))
                        .padding(4)
                )
                .frame(width: card.width, height: card.height)
                .shadow(color: .black.opacity(dragging ? 0.3 : 0.15), radius: dragging ? 6 : 2, y: dragging ? 3 : 1)
                .scaleEffect(dragging ? 1.08 : 1)
                .offset(x: origin(for: corner).width + drag.width, y: origin(for: corner).height + drag.height)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            dragging = true
                            drag = value.translation
                        }
                        .onEnded { _ in
                            let pick = target
                            withAnimation(.spring(duration: 0.38, bounce: 0.32)) {
                                corner = pick
                                drag = .zero
                                dragging = false
                            }
                        }
                )
                .onHover { h in if h { NSCursor.openHand.push() } else { NSCursor.pop() } }
        }
        .frame(width: screen.width, height: screen.height)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Preview position".loc)
        .accessibilityValue(name(for: corner).loc)
        .accessibilityAdjustableAction { direction in
            let all = QuickAccess.corners
            guard let i = all.firstIndex(of: corner) else { return }
            corner = all[(i + (direction == .increment ? 1 : all.count - 1)) % all.count]
        }
    }

    /// The corner the card would land in right now.
    private var target: String {
        let o = origin(for: corner)
        let x = o.width + drag.width + card.width / 2
        let y = o.height + drag.height + card.height / 2
        let top = y < (screen.height + menuBar) / 2
        return (top ? "top" : "bottom") + (x > screen.width / 2 ? "Right" : "Left")
    }

    private func origin(for c: String) -> CGSize {
        let x = c.hasSuffix("Right") ? screen.width - card.width - inset : inset
        let y = c.hasPrefix("top") ? menuBar + inset - 2 : screen.height - card.height - inset
        return CGSize(width: x, height: y)
    }

    private func name(for c: String) -> String {
        switch c {
        case "bottomRight": "Bottom right"
        case "topLeft": "Top left"
        case "topRight": "Top right"
        default: "Bottom left"
        }
    }
}
