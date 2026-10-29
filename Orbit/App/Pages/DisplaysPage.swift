import SwiftUI

/// MonitorControl, in Orbit: every screen's brightness, contrast and volume, and the keys for them.
struct DisplaysPage: View {
    @Bindable private var manager = DisplayManager.shared
    @State private var naming = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Displays", subtitle: "Brightness, contrast and volume for every screen — external monitors too.") {
                Toggle("", isOn: $manager.enabled.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
            }

            VStack(spacing: Space.related) {
                ForEach(manager.displays) { d in DisplayCard(display: d) }
                if manager.externals.isEmpty { NoMonitorCard() }
            }

            SettingsGroup(title: "Presets") {
                SettingsRow(title: "Quick levels", subtitle: "Every screen at once. Right-click one of yours to delete it.", symbol: "slider.horizontal.3") {
                    BrightnessPresetChips().frame(maxWidth: 300)
                }
                RowDivider()
                SettingsRow(title: "Save current levels", subtitle: "Keeps each screen's brightness as it is now.", symbol: "bookmark") {
                    if naming {
                        HStack(spacing: Space.tight) {
                            TextField("Name".loc, text: $presetName)
                                .textFieldStyle(.roundedBorder).frame(width: 140)
                                .onSubmit(save)
                            Button("Save", action: save).buttonStyle(PillButtonStyle(prominent: true))
                                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        Button("Save…") { naming = true }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            SettingsGroup(title: "Keyboard", footer: "Hold ⌥⇧ for finer steps. With the HUD off, the MacBook's own screen stays with macOS.") {
                if manager.enabled && manager.keysNeedAccessibility {
                    SettingsRow(title: "Orbit can't see the keys yet", subtitle: "Allow Orbit in Accessibility — the keys start working right away, no restart.", symbol: "exclamationmark.triangle") {
                        Button("Allow…") { Permissions.shared.requestAccessibility() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                    RowDivider()
                }
                SettingsRow(title: "Brightness keys control monitors", subtitle: "Orbit sets the monitor's brightness and shows its own HUD.", symbol: "sun.max") {
                    Toggle("", isOn: $manager.brightnessKeys).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Which screen", subtitle: "The screen the keys change.", symbol: "cursorarrow.rays") {
                    ChipPicker(selection: $manager.keyTarget, options: [(.pointer, "Under the pointer"), (.main, "Main"), (.all, "All")])
                }
                .opacity(manager.brightnessKeys ? 1 : 0.5)
                .disabled(!manager.brightnessKeys)
                RowDivider()
                SettingsRow(title: "Volume keys control monitor speakers", subtitle: "When sound plays through a monitor over HDMI or DisplayPort, which macOS can't turn up.", symbol: "speaker.wave.2") {
                    Toggle("", isOn: $manager.volumeKeys).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Volume keys show Orbit's HUD", subtitle: "For whatever's playing sound — MacBook speakers, AirPods, USB. Outputs macOS can't set stay with macOS.", symbol: "speaker.wave.3") {
                    Toggle("", isOn: $manager.speakerHUD).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Show the HUD", subtitle: "Orbit's brightness bar instead of macOS's, on the screen that changed — the MacBook's screen and keyboard light too.", symbol: "rectangle.bottomthird.inset.filled") {
                    Toggle("", isOn: $manager.showOSD).toggleStyle(.switch).labelsHidden()
                }
            }
            .opacity(manager.enabled ? 1 : 0.55)

            SettingsGroup(title: "Sync") {
                SettingsRow(title: "Match the MacBook's brightness", subtitle: "Monitors follow the built-in screen — which follows the room's light when Auto-Brightness is on.", symbol: "arrow.triangle.2.circlepath") {
                    Toggle("", isOn: $manager.syncWithBuiltIn).toggleStyle(.switch).labelsHidden()
                }
            }
            .opacity(manager.enabled ? 1 : 0.55)
        }
        .onAppear { manager.refresh() }
        .animation(.spring(duration: 0.3), value: manager.displays.count)
    }

    private func save() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        manager.saveCurrentAsPreset(named: name)
        presetName = ""
        naming = false
    }
}

/// One screen: what it is, how Orbit reaches it, and its sliders.
private struct DisplayCard: View {
    @Bindable var display: ManagedDisplay
    private var manager: DisplayManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.related) {
                Image(systemName: display.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name).font(.orbitBodyEmphasized).foregroundStyle(Palette.ink)
                    Text(detail).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.standard)
                if display.probing { ProgressView().controlSize(.small) }
                if !display.isBuiltIn {
                    menu
                    Toggle("", isOn: $display.enabled).toggleStyle(.switch).labelsHidden()
                        .hoverHint("Control this display".loc)
                }
            }

            VStack(spacing: Space.compact) {
                labeled("Brightness") {
                    LevelSlider(symbolLow: "sun.min", symbolHigh: "sun.max.fill",
                                value: Binding(get: { display.brightness }, set: { manager.setBrightnessShowingHUD(display, $0) }))
                }
                if display.hasContrast {
                    labeled("Contrast") {
                        LevelSlider(symbolLow: "circle.lefthalf.filled", symbolHigh: "circle.righthalf.filled",
                                    value: Binding(get: { display.contrast }, set: { manager.setContrast(display, $0) }))
                    }
                }
                if display.hasVolume {
                    labeled("Volume") {
                        LevelSlider(symbolLow: display.muted ? "speaker.slash.fill" : "speaker.fill", symbolHigh: "speaker.wave.3.fill",
                                    value: Binding(get: { display.muted ? 0 : display.volume }, set: { manager.setVolume(display, $0) }),
                                    onLowTap: { manager.setMuted(display, !display.muted) })
                    }
                }
                if display.hasInputs, let input = display.input {
                    labeled("Input") {
                        Picker("", selection: Binding(get: { input }, set: { manager.setInput(display, $0) })) {
                            ForEach(inputs(current: input), id: \.0) { code, name in Text(name.loc).tag(code) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 200, alignment: .leading)
                        Spacer()
                    }
                }
            }
            .disabled(!display.enabled || !manager.enabled && !display.isBuiltIn)
            .opacity(display.enabled ? 1 : 0.45)
        }
        .padding(Space.standard)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var detail: String {
        switch display.kind {
        case .builtIn: "Built-in · set by macOS".loc
        case .apple: "Apple display · set by macOS".loc
        case .ddc: "DDC/CI · Orbit talks to the monitor directly".loc
        case .software:
            if display.probing { "Asking the monitor…".loc }
            else if display.channel == nil || display.ddcBrightnessMax == nil {
                "Software dimming · this monitor didn't answer over DDC, so Orbit dims the picture instead".loc
            } else {
                "Software dimming · Orbit dims the picture instead of the backlight".loc
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Brightness control", selection: $display.method) {
                Text("Automatic".loc).tag(ManagedDisplay.Method.auto)
                Text("DDC/CI (the monitor's backlight)".loc).tag(ManagedDisplay.Method.ddc)
                Text("Software dimming".loc).tag(ManagedDisplay.Method.software)
            }
            Button("Ask the Monitor Again") { manager.refresh() }
            if display.kind == .ddc {
                Divider()
                Button("Put to Standby") { manager.standby(display) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(Palette.inkSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Space.related) {
            Text(title.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).frame(width: 72, alignment: .leading)
            content()
        }
    }

    private func inputs(current: UInt16) -> [(UInt16, String)] {
        var list = DisplayInputs.common
        if !list.contains(where: { $0.0 == current }) { list.insert((current, DisplayInputs.name(current)), at: 0) }
        return list
    }
}

/// Only the MacBook's screen right now: what this page does once a monitor is plugged in.
private struct NoMonitorCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: Space.standard) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 44, height: 30)
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            }
            .frame(width: 52, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("No external monitor connected".loc).font(.orbitBodyEmphasized).foregroundStyle(Palette.ink)
                Text("Plug one in and it shows up here. Orbit sets its real backlight over DDC/CI when the monitor allows it, and dims the picture otherwise — so the brightness keys work on every screen.".loc)
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}
