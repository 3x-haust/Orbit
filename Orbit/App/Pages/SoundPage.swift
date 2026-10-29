import AppKit
import SwiftUI

/// Per-app volume and EQ — FineTune-style, built into Orbit.
struct SoundPage: View {
    private var mixer: AudioMixer { .shared }
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Sound", subtitle: "An EQ for everything, and volume and EQ for each app.")

            if mixer.permission == .denied && (!mixer.settings.isEmpty || mixer.global.isActive) {
                PermissionNotice()
            }

            SettingsGroup(title: "Output") {
                SystemVolumeRow()
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("All Sound")
                GlobalEQCard()
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Apps")
                if mixer.apps.isEmpty {
                    EmptyApps()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(mixer.apps.enumerated()), id: \.element.id) { i, app in
                            if i > 0 { RowDivider() }
                            AppAudioRow(app: app, expanded: expanded == app.id) {
                                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { expanded = expanded == app.id ? nil : app.id }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                }
                Text("Orbit only reroutes apps you change. Everything else plays exactly as before.")
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).padding(.horizontal, 4)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: mixer.apps)
        .onAppear { mixer.watch(true) }
        .onDisappear { mixer.watch(false) }
    }
}

// MARK: - System output

private struct SystemVolumeRow: View {
    private var mixer: AudioMixer { .shared }

    var body: some View {
        SettingsRow(title: mixer.systemOutputName.isEmpty ? "System output" : mixer.systemOutputName,
                    subtitle: mixer.hasSystemVolume ? nil : "This device sets its own volume.",
                    symbol: mixer.systemMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
            if mixer.hasSystemVolume {
                Slider(value: Binding(get: { Double(mixer.systemVolume) }, set: { mixer.setSystemVolume(Float($0)) }), in: 0...1)
                    .frame(width: 200)
                    .tint(Palette.ink)
                Text("\(Int((mixer.systemVolume * 100).rounded()))%")
                    .font(.orbitCaption.monospacedDigit()).foregroundStyle(Palette.inkSecondary).frame(width: 38, alignment: .trailing)
            }
            MuteButton(muted: mixer.systemMuted) { mixer.setSystemMuted(!mixer.systemMuted) }
        }
    }
}

// MARK: - App rows

private struct AppAudioRow: View {
    let app: AudioApp
    let expanded: Bool
    let toggleEQ: () -> Void
    private var mixer: AudioMixer { .shared }
    @State private var hovering = false

    var body: some View {
        let s = mixer.settings(for: app.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if let icon = app.icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.dashed").font(.system(size: 18)).foregroundStyle(Palette.inkSecondary) }
                }
                .frame(width: 30, height: 30)
                .opacity(s.muted ? 0.45 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.orbitBody).foregroundStyle(Palette.ink).lineLimit(1)
                    HStack(spacing: 6) {
                        if mixer.routed.contains(app.id) {
                            LevelMeter(level: mixer.levels[app.id] ?? 0)
                        } else {
                            PlayingDot(active: app.isPlaying)
                        }
                        Text(status(s)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                            .help(mixer.routed.contains(app.id) ? "" : "The app has its audio output open. Whether it's actually making sound — or a video in it is muted or paused — only shows once you change its volume or EQ here.".loc)
                    }
                }
                .frame(width: 170, alignment: .leading)

                Spacer(minLength: 8)

                VolumeSlider(value: s.volume, muted: s.muted) { mixer.setVolume($0, for: app.id) }
                    .frame(width: 220)
                Text("\(Int((s.volume * 100).rounded()))%")
                    .font(.orbitCaption.monospacedDigit())
                    .foregroundStyle(s.volume > 1.005 ? Palette.accent : Palette.inkSecondary)
                    .frame(width: 40, alignment: .trailing)
                MuteButton(muted: s.muted) { mixer.setMuted(!s.muted, for: app.id) }
                Button(action: toggleEQ) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(expanded ? Palette.canvas : (s.eqIsFlat ? Palette.ink : Palette.accent))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(expanded ? Palette.ink : Palette.raised))
                }
                .buttonStyle(.plain)
                .help("Equalizer".loc)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Palette.ink.opacity(hovering ? 0.025 : 0))
            .onHover { h in withAnimation(Motion.hover) { hovering = h } }

            if expanded {
                EQEditor(appID: app.id)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func status(_ s: AudioAppSettings) -> String {
        if let failure = mixer.failures[app.id] { return failure }
        if s.muted { return "Muted".loc }
        if !app.isPlaying { return "Not playing".loc }
        // Without a tap Orbit only knows the app has an output open, not that it's making sound.
        guard mixer.routed.contains(app.id) else { return "Audio open".loc }
        if !mixer.isAudible(app.id) { return "Silent".loc }
        if !s.eqIsFlat { return (EQPreset.all.first { $0.id == s.preset }?.title ?? "Custom EQ").loc }
        return "Playing".loc
    }
}

private struct MuteButton: View {
    let muted: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(muted ? Palette.accent : Palette.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
        }
        .buttonStyle(.plain)
        .help(muted ? "Unmute".loc : "Mute".loc)
    }
}

/// 0–200 % with a soft detent at 100 % — the point where Orbit steps out of the way.
private struct VolumeSlider: View {
    let value: Float
    let muted: Bool
    let set: (Float) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = CGFloat(value / 2) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.raised).frame(height: 6)
                Capsule().fill(muted ? Palette.inkSecondary.opacity(0.4) : (value > 1.005 ? Palette.accent : Palette.ink))
                    .frame(width: max(6, x), height: 6)
                Rectangle().fill(Palette.inkSecondary.opacity(0.5)).frame(width: 1.5, height: 12).offset(x: w / 2 - 0.75)
                Circle().fill(Palette.canvas)
                    .overlay(Circle().strokeBorder(Palette.ink.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: dragging ? 18 : 16, height: dragging ? 18 : 16)
                    .offset(x: min(max(0, x - 8), w - 16))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragging = true
                    var next = Float(max(0, min(1, v.location.x / w))) * 2
                    if abs(next - 1) < 0.04 { next = 1 }
                    set((next * 100).rounded() / 100)
                }
                .onEnded { _ in dragging = false })
            .onTapGesture(count: 2) { set(1) }
        }
        .frame(height: 22)
        .animation(.spring(duration: 0.2), value: dragging)
        .accessibilityElement()
        .accessibilityLabel("Volume".loc)
        .accessibilityValue("\(Int(value * 100))%")
        .accessibilityAdjustableAction { dir in set(max(0, min(2, value + (dir == .increment ? 0.05 : -0.05)))) }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let lit = level > Float(i) / 8 * 0.9 + 0.02
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? (i >= 7 ? Palette.accent : Palette.ink) : Palette.raised)
                    .frame(width: 4, height: 8)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

private struct PlayingDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        Circle().fill(active ? Palette.ink : Palette.inkSecondary.opacity(0.4))
            .frame(width: 6, height: 6)
            .opacity(active && pulse ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

// MARK: - All Sound

/// One EQ over everything the Mac plays. Off (or flat) leaves macOS's audio untouched.
private struct GlobalEQCard: View {
    private var mixer: AudioMixer { .shared }
    @State private var hovering = false

    var body: some View {
        let g = mixer.global
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(g.enabled ? Palette.canvas : Palette.ink)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(g.enabled ? Palette.ink : Palette.raised))
                VStack(alignment: .leading, spacing: 4) {
                    Text("EQ for everything").font(.orbitBody).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        if mixer.globalRouted { LevelMeter(level: mixer.globalLevel) }
                        Text(status(g)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { g.enabled }, set: { on in
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) { mixer.setGlobalEnabled(on) }
                }))
                .toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Palette.ink.opacity(hovering ? 0.025 : 0))
            .onHover { h in withAnimation(Motion.hover) { hovering = h } }

            if g.enabled {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 6) {
                        ForEach(EQPreset.all) { preset in
                            let on = g.preset == preset.id && g.bands == preset.bands
                            Button { withAnimation(.spring(duration: 0.35, bounce: 0.15)) { mixer.applyGlobalPreset(preset) } } label: {
                                Text(preset.title.loc)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(on ? Palette.canvas : Palette.ink)
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(Capsule().fill(on ? Palette.ink : Palette.raised))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Button("Reset") { withAnimation(.spring(duration: 0.35)) { mixer.resetGlobal() } }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .disabled(g.eqIsFlat)
                    }
                    BandEditor(bands: g.bands) { band, db in mixer.setGlobalBand(band, db) }
                        .frame(height: 190)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.page))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .padding(.horizontal, 16).padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func status(_ g: GlobalEQSettings) -> String {
        if let failure = mixer.globalFailure { return failure }
        if !g.enabled { return "Off — macOS plays everything as usual".loc }
        if g.eqIsFlat { return "Flat — pick a preset or drag a band".loc }
        let name = (EQPreset.all.first { $0.id == g.preset }?.title ?? "Custom EQ").loc
        return mixer.globalRouted ? "%@ on everything you hear".loc(name) : name
    }
}

// MARK: - EQ

private struct EQEditor: View {
    let appID: String
    private var mixer: AudioMixer { .shared }

    var body: some View {
        let s = mixer.settings(for: appID)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(EQPreset.all) { preset in
                    let on = s.preset == preset.id && s.bands == preset.bands
                    Button { withAnimation(.spring(duration: 0.35, bounce: 0.15)) { mixer.applyPreset(preset, for: appID) } } label: {
                        Text(preset.title.loc)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(on ? Palette.canvas : Palette.ink)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(on ? Palette.ink : Palette.raised))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                OutputMenu(appID: appID, selected: s.deviceUID)
                Button("Reset") { withAnimation(.spring(duration: 0.35)) { mixer.reset(appID) } }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .disabled(s == AudioAppSettings())
            }

            BandEditor(bands: s.bands) { band, db in mixer.setBand(band, db, for: appID) }
                .frame(height: 190)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.page))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

private struct OutputMenu: View {
    let appID: String
    let selected: String?
    private var mixer: AudioMixer { .shared }

    var body: some View {
        Menu {
            Button { mixer.setDevice(nil, for: appID) } label: {
                if selected == nil { Label("System output", systemImage: "checkmark") } else { Text("System output") }
            }
            Divider()
            ForEach(mixer.outputs) { d in
                Button { mixer.setDevice(d.id, for: appID) } label: {
                    if selected == d.id { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
        } label: {
            Label(selected.flatMap { uid in mixer.outputs.first { $0.id == uid }?.name } ?? "System output".loc, systemImage: "hifispeaker")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Palette.inkSecondary)
    }
}

/// Ten draggable bands over the combined frequency-response curve.
private struct BandEditor: View {
    let bands: [Float]
    let set: (Int, Float) -> Void
    @State private var active: Int?

    private let labelHeight: CGFloat = 18
    private let valueHeight: CGFloat = 16

    var body: some View {
        GeometryReader { g in
            let column = g.size.width / CGFloat(GraphicEQ.bands)
            let top = valueHeight, plot = g.size.height - labelHeight - valueHeight
            ZStack(alignment: .topLeading) {
                // Grid: ±12, ±6 and 0 dB.
                ForEach([-12, -6, 0, 6, 12], id: \.self) { db in
                    Rectangle().fill(db == 0 ? Palette.ink.opacity(0.18) : Palette.hairline)
                        .frame(height: 1)
                        .offset(y: top + y(Float(db), plot))
                }
                ResponseCurve(bands: bands, column: column)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: g.size.width, height: plot)
                    .offset(y: top)
                    .animation(.spring(duration: 0.3), value: bands)

                ForEach(0..<GraphicEQ.bands, id: \.self) { i in
                    let db = bands[i]
                    VStack(spacing: 0) {
                        Text(String(format: db > 0 ? "+%.1f" : "%.1f", db))
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(active == i ? Palette.ink : Palette.inkSecondary)
                            .opacity(active == i || abs(db) > 0.05 ? 1 : 0)
                            .frame(height: valueHeight)
                        ZStack(alignment: .top) {
                            Capsule().fill(Palette.raised).frame(width: 4)
                            Circle()
                                .fill(Palette.ink)
                                .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 2))
                                .frame(width: active == i ? 16 : 13, height: active == i ? 16 : 13)
                                .offset(y: y(db, plot) - (active == i ? 8 : 6.5))
                        }
                        .frame(width: column, height: plot)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                active = i
                                let ratio = Float(max(0, min(1, v.location.y / plot)))
                                let value = (12 - ratio * 24)
                                set(i, abs(value) < 0.4 ? 0 : (value * 2).rounded() / 2)
                            }
                            .onEnded { _ in active = nil })
                        .onTapGesture(count: 2) { set(i, 0) }
                        Text(GraphicEQ.labels[i])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.inkSecondary)
                            .frame(height: labelHeight)
                    }
                    .frame(width: column)
                    .offset(x: CGFloat(i) * column)
                    .accessibilityElement()
                    .accessibilityLabel("%@ Hz".loc(GraphicEQ.labels[i]))
                    .accessibilityValue(String(format: "%.1f dB", db))
                    .accessibilityAdjustableAction { dir in set(i, db + (dir == .increment ? 1 : -1)) }
                }
            }
        }
        .animation(.spring(duration: 0.2), value: active)
    }

    private func y(_ db: Float, _ height: CGFloat) -> CGFloat {
        CGFloat((12 - max(-12, min(12, db))) / 24) * height
    }
}

private struct ResponseCurve: Shape {
    var bands: [Float]
    let column: CGFloat

    var animatableData: AnimatableVector {
        get { AnimatableVector(bands.map(Double.init)) }
        set { bands = newValue.values.map(Float.init) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let span = max(1, rect.width - column)
        let steps = 140
        for s in 0...steps {
            let x = CGFloat(s) / CGFloat(steps) * rect.width
            // Columns are octave-spaced, so x maps linearly onto log frequency.
            let octaves = Double((x - column / 2) / span) * 9
            let f = 31.25 * pow(2, octaves)
            let db = GraphicEQ.response(bands, at: max(15, min(22_000, f)))
            let y = CGFloat((12 - max(-12, min(12, db))) / 24) * rect.height
            if s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// Lets the curve morph between presets instead of jumping.
private struct AnimatableVector: VectorArithmetic {
    var values: [Double]
    init(_ values: [Double]) { self.values = values }

    static var zero: AnimatableVector { AnimatableVector([]) }
    static func + (a: Self, b: Self) -> Self { combine(a, b, +) }
    static func - (a: Self, b: Self) -> Self { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    private static func combine(_ a: Self, _ b: Self, _ op: (Double, Double) -> Double) -> Self {
        let n = max(a.values.count, b.values.count)
        return AnimatableVector((0..<n).map { op($0 < a.values.count ? a.values[$0] : 0, $0 < b.values.count ? b.values[$0] : 0) })
    }
}

// MARK: - States

private struct EmptyApps: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
            Text("Nothing is playing").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
            Text("Apps show up here as soon as they make a sound.")
                .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .card()
    }
}

private struct PermissionNotice: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text("Allow System Audio Recording").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Orbit needs it to change an app’s volume or EQ. Audio never leaves your Mac.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button("Open Settings") { AudioCapturePermission.openSettings() }.buttonStyle(PillButtonStyle())
        }
        .padding(16)
        .card(active: true)
    }
}
