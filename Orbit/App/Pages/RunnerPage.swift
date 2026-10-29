import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RunnerPage: View {
    private var runner: MenuBarRunner { .shared }
    @AppStorage(Pref.runnerEnabled) private var enabled = false
    @AppStorage(Pref.runnerSelected) private var selected = RunnerArt.orbit.rawValue
    @AppStorage(Pref.runnerSource) private var source = "cpu"
    @AppStorage(Pref.runnerFPSCap) private var fpsCap = 0
    @AppStorage(Pref.runnerInvert) private var invert = false
    @AppStorage(Pref.runnerShowPercent) private var showPercent = false
    @AppStorage(Pref.runnerPaused) private var paused = false
    @AppStorage(Pref.runnerFlip) private var flip = false
    @AppStorage(Pref.runnerAccent) private var accent = false
    @AppStorage(Pref.runnerShuffle) private var shuffle = "off"
    @State private var importError: String?
    @State private var renaming: CustomRunner?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Runner", subtitle: "A little character in your menu bar that runs faster the busier your Mac gets.") {
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
            }

            RunnerHero(enabled: enabled)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Characters")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(RunnerArt.allCases) { art in
                        RunnerCard(id: art.rawValue, name: art.title.loc, selected: selected == art.rawValue) { pick(art.rawValue) }
                    }
                    ForEach(runner.customs) { custom in
                        let id = MenuBarRunner.id(custom)
                        RunnerCard(id: id, name: custom.name, selected: selected == id, remove: { runner.delete(custom) }) { pick(id) }
                            .contextMenu {
                                Button("Rename…") { newName = custom.name; renaming = custom }
                                Button(custom.template ? "Keep Its Colors" : "Match the Menu Bar") {
                                    var c = custom; c.template.toggle(); runner.update(c)
                                }
                                Divider()
                                Button("Delete", role: .destructive) { runner.delete(custom) }
                            }
                    }
                    AddRunnerCard(action: importFiles)
                }
                if let importError {
                    Text(importError).font(.system(size: 11)).foregroundStyle(Palette.accent).padding(.horizontal, 4)
                }
            }

            if let custom = runner.custom(selected) {
                SettingsGroup(title: "Your runner") {
                    SettingsRow(title: "Name", symbol: "character.cursor.ibeam") {
                        TextField("", text: Binding(get: { custom.name }, set: { var c = custom; c.name = $0; runner.update(c) }))
                            .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 180)
                    }
                    RowDivider()
                    SettingsRow(title: "Match the menu bar", subtitle: "One color, like the other icons. Turn off to keep the frames’ own colors.", symbol: "circle.lefthalf.filled") {
                        Toggle("", isOn: Binding(get: { custom.template }, set: { var c = custom; c.template = $0; runner.update(c) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "%ld frames".loc(custom.frameCount), symbol: "film.stack") {
                        Button("Delete") { runner.delete(custom) }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            SettingsGroup(title: "Speed", footer: "Idle is a slow walk at 2 frames a second; flat out is a sprint at 20.") {
                SettingsRow(title: "Runs with", symbol: "gauge.with.dots.needle.67percent") {
                    ChipPicker(selection: $source, options: MenuBarRunner.Source.allCases.map { ($0.rawValue, $0.title) })
                }
                RowDivider()
                SettingsRow(title: "Slower when busy", subtitle: "Turn it around: a sprint when idle, a stroll under load.", symbol: "arrow.left.arrow.right") {
                    Toggle("", isOn: $invert).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Frame rate limit", subtitle: "Lower is easier on the battery.", symbol: "speedometer") {
                    ChipPicker(selection: $fpsCap, options: [(0, "None"), (5, "5 fps"), (10, "10 fps"), (15, "15 fps")])
                }
            }

            SettingsGroup(title: "In the menu bar") {
                SettingsRow(title: "Show percentage", subtitle: "The reading next to the character, like “23%”.", symbol: "percent") {
                    Toggle("", isOn: $showPercent).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Pause animation", subtitle: "Stays put until you resume. Click it in the menu bar for stats.", symbol: "pause.circle") {
                    Toggle("", isOn: $paused).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Face the other way", subtitle: "Runs to the left instead of the right.", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    Toggle("", isOn: $flip).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Use accent color", subtitle: "One-color runners take your system accent color.", symbol: "paintpalette") {
                    Toggle("", isOn: $accent).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Switch runner every 10 minutes", subtitle: "Picks one at random.", symbol: "shuffle") {
                    ChipPicker(selection: $shuffle, options: [("off", "Off"), ("all", "Any runner"), ("mono", "One-color only")])
                }
            }

            SettingsGroup(title: "Status card", footer: "What shows when you click the runner in the menu bar.") {
                RunnerStatToggles()
            }

        }
        .onChange(of: flip) { runner.flushFrames() }
        .onChange(of: accent) { runner.refreshLook() }
        .onChange(of: shuffle) { runner.scheduleShuffle() }
        .onChange(of: enabled) { runner.apply() }
        .onChange(of: source) { runner.refreshLook() }
        .onChange(of: fpsCap) { runner.refreshLook() }
        .onChange(of: invert) { runner.refreshLook() }
        .onChange(of: showPercent) { runner.refreshLook() }
        .onChange(of: paused) { runner.setPaused(paused) }
        .onAppear { SystemMonitor.shared.watch(true) }
        .onDisappear { SystemMonitor.shared.watch(false) }
        .alert("Rename Runner", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if var c = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty { c.name = newName; runner.update(c) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func pick(_ id: String) {
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { selected = id }
        runner.select(id)
        if !enabled { enabled = true }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.gif, .png, .image]
        panel.message = "Choose an animated GIF, or several PNG frames in order.".loc
        panel.prompt = "Add Runner".loc
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            try runner.importRunner(panel.urls)
            importError = nil
            if !enabled { enabled = true }
            selected = runner.selected
        } catch {
            importError = error.localizedDescription
        }
    }
}

// MARK: - Pieces

/// Plays a runner's frames at `fps`.
struct RunnerAnimation: View {
    let id: String
    var fps: Double = 10
    var height: CGFloat = 36
    var paused = false

    /// Accumulated stride, so a pace change speeds the stride up instead of jumping to another frame.
    private final class Stride {
        var phase = 0.0
        var last: Date?
        func frame(at date: Date, fps: Double, count: Int) -> Int {
            if let last { phase += fps * min(0.1, max(0, date.timeIntervalSince(last))) }
            last = date
            return count == 0 ? 0 : Int(phase) % count
        }
    }
    @State private var stride = Stride()

    var body: some View {
        let frames = MenuBarRunner.shared.frames(for: id)
        TimelineView(.animation(minimumInterval: 1 / 40, paused: paused || frames.count < 2)) { context in
            let i = stride.frame(at: context.date, fps: fps, count: frames.count)
            if let frame = frames.indices.contains(i) ? frames[i] : nil {
                Image(nsImage: frame)
                    .renderingMode(frame.isTemplate ? .template : .original)
                    .resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Palette.ink)
                    .frame(height: height)
            }
        }
    }
}

private struct RunnerHero: View {
    let enabled: Bool
    private var runner: MenuBarRunner { .shared }
    @AppStorage(Pref.runnerSelected) private var selected = RunnerArt.orbit.rawValue
    @AppStorage(Pref.runnerSource) private var source = "cpu"
    @AppStorage(Pref.runnerFPSCap) private var fpsCap = 0
    @AppStorage(Pref.runnerInvert) private var invert = false
    @AppStorage(Pref.runnerPaused) private var paused = false

    var body: some View {
        let level = reading
        let fps = MenuBarRunner.pace(level: level, invert: invert, cap: fpsCap)
        HStack(spacing: 22) {
            ZStack(alignment: .bottom) {
                // A ground line so it reads as running, not floating.
                Capsule().fill(Palette.hairline).frame(height: 2).padding(.horizontal, 10).offset(y: -14)
                RunnerAnimation(id: selected, fps: fps, height: 54, paused: paused)
                    .padding(.bottom, 16)
            }
            .frame(width: 150, height: 96)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int((level * 100).rounded()))%")
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText(value: level))
                    Text((MenuBarRunner.Source(rawValue: source) ?? .cpu).title.loc)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                }
                Text(paused ? "Paused".loc : "Running at %ld frames a second".loc(Int(fps.rounded())))
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                if !enabled {
                    Text("Off — turn it on to put it in the menu bar.")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                }
            }
            .animation(.spring(duration: 0.4), value: level)
            Spacer()
        }
        .padding(16)
        .card()
    }

    private var reading: Double {
        let m = SystemMonitor.shared
        return switch MenuBarRunner.Source(rawValue: source) ?? .cpu {
        case .cpu: m.cpu.last ?? 0
        case .memory: m.memoryTotal > 0 ? m.memoryUsed / m.memoryTotal : 0
        case .gpu: runner.gpu ?? 0
        }
    }
}

private struct RunnerCard: View {
    let id: String
    let name: String
    let selected: Bool
    var remove: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                RunnerAnimation(id: id, fps: hovering || selected ? 12 : 6, height: 30)
                    .frame(height: 44)
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .card(active: selected, hovering: hovering, radius: 12)
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.accent).padding(8)
                } else if hovering, let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.inkSecondary)
                    }
                    .buttonStyle(.plain).padding(8).help("Delete")
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }
}

private struct AddRunnerCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).foregroundStyle(hovering ? Palette.accent : Palette.ink)
                    .frame(height: 44)
                VStack(spacing: 1) {
                    Text("Add your own").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("GIF or PNGs").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hovering ? Palette.accent : Palette.hairline, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .help("Choose an animated GIF, or several PNG frames in order.")
    }
}
