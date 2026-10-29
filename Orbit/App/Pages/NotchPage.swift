import AppKit
import CoreBluetooth
import SwiftUI

/// Notch: the camera housing as a place for music, timers, files and notices.
struct NotchPage: View {
    @AppStorage(NotchPrefs.enabled) private var enabled = true
    @AppStorage(NotchPrefs.hoverOpen) private var hoverOpen = true
    @AppStorage(NotchPrefs.openDelay) private var openDelay = 0.12
    @AppStorage(NotchPrefs.closeDelay) private var closeDelay = 0.35
    @AppStorage(NotchPrefs.swipe) private var swipe = true
    @AppStorage(NotchPrefs.haptics) private var haptics = true
    @AppStorage(NotchPrefs.scale) private var scale = 1.0
    @AppStorage(NotchPrefs.radius) private var radius = 22.0
    @AppStorage(NotchPrefs.shadow) private var shadow = true
    @AppStorage(NotchPrefs.screens) private var screens = "notch"
    @AppStorage(NotchPrefs.hideFullScreen) private var hideFullScreen = true
    @AppStorage(NotchPrefs.tabHome) private var tabHome = true
    @AppStorage(NotchPrefs.tabShelf) private var tabShelf = true
    @AppStorage(NotchPrefs.tabMirror) private var tabMirror = true
    @AppStorage(NotchPrefs.tabTimer) private var tabTimer = true
    @AppStorage(NotchPrefs.tabClipboard) private var tabClipboard = true
    @AppStorage(NotchPrefs.liveMusic) private var liveMusic = true
    @AppStorage(NotchPrefs.liveCharging) private var liveCharging = true
    @AppStorage(NotchPrefs.liveTimer) private var liveTimer = true
    @AppStorage(NotchPrefs.liveRecording) private var liveRecording = true
    @AppStorage(NotchPrefs.liveAwake) private var liveAwake = true
    @AppStorage(NotchPrefs.liveFocus) private var liveFocus = true
    @AppStorage(NotchPrefs.liveDownloads) private var liveDownloads = false
    @AppStorage(NotchPrefs.liveBluetooth) private var liveBluetooth = false
    @AppStorage(NotchPrefs.timerMinutes) private var timerMinutes = 25
    @AppStorage(NotchPrefs.hudPlace) private var hudPlace = "bottom"
    @AppStorage(NotchPrefs.openTab) private var openTab = "home"

    private var hasNotch: Bool { NSScreen.screens.contains(where: \.hasCameraHousing) }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Notch", subtitle: "The camera notch grows into music, timers, files and notices — and shrinks back out of the way.") {
                Toggle("", isOn: applied($enabled)).toggleStyle(.switch).labelsHidden()
            }

            NotchPreviewStage(scale: scale, radius: radius, shadow: shadow)

            Group {
                SettingsGroup(title: "Opening", footer: "Drop files on the notch to keep them on its shelf.") {
                    SettingsRow(title: "Open on hover", subtitle: "Point at the notch to open it. Clicking it always works.", symbol: "cursorarrow.motionlines") {
                        Toggle("", isOn: applied($hoverOpen)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    NotchSlider(title: "Hover delay", symbol: "timer", value: applied($openDelay), range: 0...0.6, step: 0.02)
                        .opacity(hoverOpen ? 1 : 0.5)
                        .disabled(!hoverOpen)
                    RowDivider()
                    NotchSlider(title: "Close delay", symbol: "arrow.up.to.line", value: applied($closeDelay), range: 0.1...1.5, step: 0.05)
                    RowDivider()
                    SettingsRow(title: "Tab when it opens", subtitle: "Dragging a file in, or the Shelf shortcut, always opens the Shelf.", symbol: "square.on.square") {
                        ChipPicker(selection: applied($openTab), options: [("home", "Home"), ("last", "Last viewed")])
                    }
                    RowDivider()
                    SettingsRow(title: "Swipe down to open", subtitle: "Two fingers down on the notch open it; up closes it.", symbol: "hand.draw") {
                        Toggle("", isOn: applied($swipe)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Haptic feedback", subtitle: "A light tap on the trackpad as it opens.", symbol: "hand.tap") {
                        Toggle("", isOn: applied($haptics)).toggleStyle(.switch).labelsHidden()
                    }
                }

                SettingsGroup(title: "Tabs", footer: "The mirror turns the camera on only when you ask it to, and off as soon as the notch closes.") {
                    SettingsRow(title: "Home", subtitle: "What's playing, with controls, and what's left on today's calendar.", symbol: "house") {
                        Toggle("", isOn: applied($tabHome)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Shelf", subtitle: "Files you dropped on the notch, ready to drag out, AirDrop or share.", symbol: "tray.full") {
                        Toggle("", isOn: applied($tabShelf)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Mirror", subtitle: "A quick look at yourself through the camera.", symbol: "person.crop.square") {
                        Toggle("", isOn: applied($tabMirror)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Timer tab", subtitle: "1, 5, 10 and 25 minute timers and pomodoro, counting down beside the notch.", symbol: "timer") {
                        Toggle("", isOn: applied($tabTimer)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Recent clipboard", subtitle: "The last five things you copied. Click one to paste it.", symbol: "doc.on.clipboard") {
                        Toggle("", isOn: applied($tabClipboard)).toggleStyle(.switch).labelsHidden()
                    }
                }

                SettingsGroup(title: "Live activities", footer: "Shown beside the closed notch while they're going on. macOS's own AirPods “Connected” banner has no setting apps can change, so it still appears too — turn it off yourself if macOS offers it in Notifications.") {
                    SettingsRow(title: "Music", subtitle: "The cover and moving bars while something plays.", symbol: "music.note") {
                        Toggle("", isOn: applied($liveMusic)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Charging", subtitle: "The battery level when you plug in or unplug.", symbol: "bolt") {
                        Toggle("", isOn: applied($liveCharging)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Timer countdown", symbol: "timer") {
                        Toggle("", isOn: applied($liveTimer)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Screen recording", subtitle: "A red dot and the time while Orbit records.", symbol: "record.circle") {
                        Toggle("", isOn: applied($liveRecording)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Keep Awake", subtitle: "A cup while your Mac stays awake, with the time left.", symbol: "cup.and.saucer") {
                        Toggle("", isOn: applied($liveAwake)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Focus", subtitle: "A notice when Do Not Disturb turns on or off.", symbol: "moon") {
                        Toggle("", isOn: applied($liveFocus)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Downloads", subtitle: "Files still downloading into Downloads, and a notice when they finish.", symbol: "arrow.down.circle") {
                        Toggle("", isOn: applied($liveDownloads)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "AirPods and Bluetooth", subtitle: "A notice when a device connects, with each AirPod's and the case's battery. macOS asks for Bluetooth access.", symbol: "airpods") {
                        HStack(spacing: 8) {
                            if liveBluetooth, CBManager.authorization != .allowedAlways {
                                Button("Allow Bluetooth") { NotchBluetoothAccess.request() }
                                    .buttonStyle(PillButtonStyle(prominent: true))
                            }
                            Toggle("", isOn: applied($liveBluetooth)).toggleStyle(.switch).labelsHidden()
                        }
                    }
                }

                SettingsGroup(title: "Volume and brightness", footer: "The same setting as on the Displays page. Orbit's HUD needs Displays turned on.") {
                    SettingsRow(title: "Show the HUD", subtitle: "Volume, brightness and keyboard light — grown out of the notch, at the bottom of the screen, or macOS's own.", symbol: "speaker.wave.2") {
                        ChipPicker(selection: hudBinding, options: [("notch", "Notch"), ("bottom", "Bottom"), ("off", "Off")])
                    }
                }

                SettingsGroup(title: "Look") {
                    NotchSlider(title: "Size", symbol: "arrow.up.left.and.arrow.down.right", value: applied($scale), range: 0.85...1.25, step: 0.05, percent: true)
                    RowDivider()
                    NotchSlider(title: "Corners", symbol: "app", value: applied($radius), range: 10...34, step: 1)
                    RowDivider()
                    SettingsRow(title: "Shadow", symbol: "shadow") {
                        Toggle("", isOn: applied($shadow)).toggleStyle(.switch).labelsHidden()
                    }
                    RowDivider()
                    SettingsRow(title: "Screens", subtitle: hasNotch ? "Other screens get a drawn notch at the top." : "This Mac has no notch, so Orbit draws one.", symbol: "display.2") {
                        ChipPicker(selection: applied($screens), options: [("notch", "Notch screen"), ("all", "All screens")])
                    }
                    RowDivider()
                    SettingsRow(title: "Hide in full screen", subtitle: "Out of the way of full-screen videos and games.", symbol: "arrow.up.left.and.arrow.down.right.rectangle") {
                        Toggle("", isOn: applied($hideFullScreen)).toggleStyle(.switch).labelsHidden()
                    }
                }

                SettingsGroup(title: "Timer shortcut") {
                    SettingsRow(title: "Length", subtitle: "For the Start Notch Timer shortcut.", symbol: "keyboard") {
                        ChipPicker(selection: $timerMinutes, options: [(5, "5 min"), (10, "10 min"), (25, "25 min"), (50, "50 min")])
                    }
                }
            }
            .opacity(enabled ? 1 : 0.55)
            .disabled(!enabled)
        }
    }

    /// Writes the setting, then has the notch pick it up.
    private func applied<T>(_ b: Binding<T>) -> Binding<T> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; NotchCenter.shared.apply() })
    }

    /// One setting with Displays: off is Orbit's HUD off; notch or bottom is where it shows.
    private var hudBinding: Binding<String> {
        let dm = DisplayManager.shared
        return Binding(
            get: { !dm.showOSD && !dm.speakerHUD ? "off" : hudPlace },
            set: { v in
                if v == "off" {
                    dm.showOSD = false
                    dm.speakerHUD = false
                } else {
                    hudPlace = v
                    if !dm.showOSD { dm.showOSD = true }
                    if !dm.speakerHUD { dm.speakerHUD = true }
                }
            })
    }
}

private struct NotchSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var percent = false

    var body: some View {
        SettingsRow(title: title, symbol: symbol) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).frame(width: 160)
                Text(percent ? "\(Int((value * 100).rounded()))%" : range.upperBound <= 2 ? String(format: "%.2fs", value) : "\(Int(value.rounded()))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - Preview

/// A menu bar with the notch going through its shapes. It only animates while the page is open.
private struct NotchPreviewStage: View {
    let scale: Double
    let radius: Double
    let shadow: Bool

    enum Demo: String, CaseIterable, Identifiable {
        case idle, music, hud, notice, open
        var id: String { rawValue }
        var title: String {
            switch self {
            case .idle: "Resting"
            case .music: "Music"
            case .hud: "Volume"
            case .notice: "Notice"
            case .open: "Open"
            }
        }
    }

    @State private var demo: Demo = .idle
    @State private var auto = true
    @State private var volume = 0.45

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.18, green: 0.22, blue: 0.36), Color(red: 0.42, green: 0.26, blue: 0.34), Color(red: 0.14, green: 0.1, blue: 0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.14)).frame(height: 24).frame(maxHeight: .infinity, alignment: .top)
                HStack {
                    HStack(spacing: 14) {
                        Image(systemName: "apple.logo").font(.system(size: 12, weight: .semibold))
                        Text("Finder").font(.system(size: 12, weight: .bold))
                        Text("File").font(.system(size: 12))
                        Text("Edit").font(.system(size: 12))
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75percent")
                        Text("9:41").font(.system(size: 12, weight: .medium))
                    }
                    .font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14)
                .frame(height: 24)
                NotchDemoShape(demo: demo, scale: scale, radius: radius, shadow: shadow, volume: volume)
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .environment(\.colorScheme, .dark)

            HStack(spacing: 8) {
                ChipPicker(selection: Binding(get: { auto ? nil : demo }, set: { if let v = $0 { auto = false; demo = v } }),
                           options: Demo.allCases.map { (Optional($0), $0.title) })
                Spacer()
                Button(auto ? "Pause" : "Play") { auto.toggle() }
                    .buttonStyle(PillButtonStyle())
            }
        }
        .task(id: auto) {
            guard auto else { return }
            let steps: [Demo] = [.idle, .music, .hud, .music, .notice, .open, .idle]
            var i = steps.firstIndex(of: demo) ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(demo == .open ? 3.2 : 2))
                guard !Task.isCancelled else { return }
                i = (i + 1) % steps.count
                withAnimation(NotchCenter.morph) { demo = steps[i] }
                if demo == .hud {
                    for v in [0.5, 0.56, 0.62, 0.68] {
                        try? await Task.sleep(for: .milliseconds(180))
                        withAnimation(.spring(duration: 0.18, bounce: 0)) { volume = v }
                    }
                    volume = 0.45
                }
            }
        }
    }
}

/// The same geometry as the real notch, with sample content.
private struct NotchDemoShape: View {
    let demo: NotchPreviewStage.Demo
    let scale: Double
    let radius: Double
    let shadow: Bool
    let volume: Double

    private let notch = CGSize(width: 150, height: 24)

    private var phase: NotchCenter.Phase {
        switch demo {
        case .idle: .idle
        case .music: .ears(.music)
        case .hud: .hud
        case .notice: .peek
        case .open: .expanded
        }
    }

    var body: some View {
        var c = NotchCenter.Config()
        c.scale = scale * 0.78
        c.radius = radius
        c.shadow = shadow
        let size = NotchGeometry.shape(phase, notch: notch, config: c)
        let r = NotchGeometry.radius(phase, config: c)
        let ear = NotchGeometry.ear(phase)
        let shape = NotchBezelShape(radius: r, ear: ear.width, earDepth: ear.depth, minBody: notch)
        let art = WidgetContent.sampleArtwork
        return ZStack(alignment: .top) {
            shape.fill(.black).shadow(color: .black.opacity(shadow && !phase.collapsed ? 0.5 : 0), radius: 14, y: 6)
            Group {
                switch demo {
                case .idle: Color.clear
                case .music:
                    HStack {
                        Image(nsImage: art).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4))
                        Spacer()
                        Equalizer(playing: true, color: Color(red: 1, green: 0.5, blue: 0.3)).frame(width: 14, height: 11)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: notch.height)
                case .hud:
                    HStack {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Spacer()
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.16))
                            Capsule().fill(.white).frame(width: 52 * volume)
                        }
                        .frame(width: 52, height: 4)
                    }
                    .padding(.horizontal, 30)
                    .frame(height: notch.height)
                case .notice:
                    VStack(spacing: 0) {
                        Color.clear.frame(height: notch.height)
                        NotchPeekRow(peek: .init(symbol: "bolt.fill", tint: .green, title: "Charging", detail: nil, trailing: "82%"))
                    }
                case .open:
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            ForEach(NotchCenter.Tab.allCases) { t in
                                Image(systemName: t.symbol).font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white.opacity(t == .home ? 1 : 0.45))
                                    .frame(width: 20, height: 16)
                                    .background(Capsule().fill(.white.opacity(t == .home ? 0.16 : 0)))
                            }
                            Spacer()
                        }
                        .padding(.leading, 14)
                        .frame(height: notch.height)
                        HStack(spacing: 12) {
                            Image(nsImage: art).resizable().frame(width: 70, height: 70)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Night Drive").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                Text("Orbit").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                                Capsule().fill(.white.opacity(0.15)).frame(height: 3)
                                    .overlay(alignment: .leading) { Capsule().fill(.white).frame(width: 60, height: 3) }
                                HStack(spacing: 14) {
                                    Image(systemName: "backward.fill")
                                    Image(systemName: "pause.fill").font(.system(size: 15))
                                    Image(systemName: "forward.fill")
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                            }
                            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("29").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                                HStack(spacing: 5) {
                                    Capsule().fill(Color.blue).frame(width: 3, height: 20)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text("Design review").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                        Text("3:00 PM").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                                    }
                                }
                            }
                            .frame(width: 100, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, ear.width)
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
            .transition(.notchContent)
            .id(demo)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .animation(NotchCenter.morph, value: demo)
    }
}

/// Without Bluetooth access IOBluetooth stays silent about connections, so the notch never hears of
/// the AirPods. Asking once shows macOS's prompt; after a refusal only System Settings can change it.
@MainActor
enum NotchBluetoothAccess {
    private static var manager: CBCentralManager?

    static func request() {
        if CBManager.authorization == .notDetermined {
            manager = CBCentralManager(delegate: nil, queue: nil)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
        }
    }
}
