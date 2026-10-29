import AppKit
import AVFoundation
import EventKit
import SwiftUI
import UniformTypeIdentifiers

/// The open notch: tabs beside the camera, the chosen tab below.
struct NotchOpenPanel: View {
    let notch: CGSize
    let display: CGDirectDisplayID
    private var center: NotchCenter { .shared }

    var body: some View {
        let tabs = center.config.tabs
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 3) {
                    ForEach(tabs) { tab in
                        NotchTabButton(tab: tab, selected: center.tab == tab) {
                            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { center.tab = tab }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                Color.clear.frame(width: notch.width)
                HStack(spacing: 8) {
                    NotchBatteryChip()
                    NotchIconButton(symbol: "gearshape.fill", help: "Notch Settings") {
                        center.close()
                        MainWindow.show(.notch)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
            }
            .frame(height: notch.height)

            Group {
                switch center.tab {
                case .home: NotchHomeTab()
                case .shelf: NotchShelfTab()
                case .mirror: NotchMirrorTab()
                case .timer: NotchTimerTab()
                case .clipboard: NotchClipboardTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .transition(.opacity)
            .id(center.tab)
        }
    }
}

private struct NotchTabButton: View {
    let tab: NotchCenter.Tab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(hover ? 0.8 : 0.5))
                .frame(width: 28, height: 22)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : hover ? 0.07 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.title.loc)
    }
}

struct NotchIconButton: View {
    let symbol: String
    var help: String?
    var size: CGFloat = 12
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint.opacity(hover ? 1 : 0.7))
                .frame(width: size + 14, height: size + 12)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help?.loc ?? "")
    }
}

private struct NotchBatteryChip: View {
    var body: some View {
        if let b = NotchLive.shared.battery {
            HStack(spacing: 3) {
                Text("\(b.percent)%").font(.system(size: 10, weight: .semibold).monospacedDigit())
                Image(systemName: b.charging ? "battery.100percent.bolt" : b.percent < 20 ? "battery.25percent" : "battery.75percent")
                    .font(.system(size: 12))
                    .foregroundStyle(b.charging ? Color.green : b.percent < 20 ? Color.red : .white)
            }
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - Home

private struct NotchHomeTab: View {
    var body: some View {
        HStack(spacing: 14) {
            if NowPlaying.shared.track != nil { NotchMusicCard() } else { NotchNoMusic() }
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
            NotchCalendarCard().frame(width: 170)
        }
    }
}

private struct NotchNoMusic: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NotchMusicCard: View {
    @State private var scrub: Double?

    var body: some View {
        let np = NowPlaying.shared
        HStack(spacing: 14) {
            Group {
                if let art = np.artwork { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
                else { CoverPlaceholder(appIcon: np.appIcon, side: 92) }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: np.palette.accent.opacity(0.35), radius: 14, y: 4)
            .onTapGesture { np.openSource() }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.track?.title ?? "").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(np.track?.artist ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Equalizer(playing: np.playing, color: np.palette.accent).frame(width: 16, height: 14).padding(.top, 3)
                }
                scrubber(np)
                HStack(spacing: 10) {
                    NotchIconButton(symbol: np.liked ? "heart.fill" : "heart", help: "Like Song", size: 12, tint: np.liked ? Palette.brand : .white) { np.toggleLike() }
                    Spacer(minLength: 0)
                    NotchIconButton(symbol: "backward.fill", help: "Previous Song", size: 14) { np.previous() }
                    NotchIconButton(symbol: np.playing ? "pause.fill" : "play.fill", help: "Play/Pause", size: 20) { np.togglePlayPause() }
                    NotchIconButton(symbol: "forward.fill", help: "Next Song", size: 14) { np.next() }
                    Spacer(minLength: 0)
                    NotchIconButton(symbol: "arrow.up.forward.app", help: "Open", size: 12) { np.openSource() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scrubber(_ np: NowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let duration = max(np.duration, 1)
            let elapsed = scrub ?? min(np.elapsed(at: ctx.date), duration)
            VStack(spacing: 3) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white).frame(width: max(4, g.size.width * elapsed / duration))
                    }
                    .frame(height: scrub == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in scrub = min(max(v.location.x / g.size.width, 0), 1) * duration }
                        .onEnded { _ in
                            if let scrub { np.seek(to: scrub) }
                            scrub = nil
                        })
                }
                .frame(height: 10)
                HStack {
                    Text(NotchTimer.clock(elapsed))
                    Spacer()
                    Text("-" + NotchTimer.clock(max(0, duration - elapsed)))
                }
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

private struct NotchCalendarCard: View {
    private var model: NotchCalendar { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Date().formatted(.dateTime.day())).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text(Date().formatted(.dateTime.weekday(.wide))).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.brand)
            }
            switch model.access {
            case .fullAccess:
                if model.events.isEmpty {
                    Text("No more events today").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                } else {
                    ForEach(Array(model.events.prefix(3)), id: \.self) { e in
                        HStack(alignment: .top, spacing: 6) {
                            Capsule().fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.title ?? "").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                Text(NotchCalendar.when(e)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                        }
                    }
                }
            default:
                Text("See today's events here").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Button("Allow Calendar") { model.requestAccess() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.brand)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.load() }
    }
}

// MARK: - Shelf

private struct NotchShelfTab: View {
    private var shelf: Shelf { .shared }

    var body: some View {
        if shelf.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Text("Drop files on the notch").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text("They wait here until you drag them somewhere.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(NotchCenter.shared.dropTargeted ? 0.5 : 0.15), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("%ld items".loc(shelf.items.count)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    NotchIconButton(symbol: "airplayaudio", help: "AirDrop", size: 11) { NotchShelfActions.airDrop() }
                    NotchIconButton(symbol: "square.and.arrow.up", help: "Share", size: 11) { NotchShelfActions.share() }
                    NotchIconButton(symbol: "doc.on.doc", help: "Copy All", size: 11) { shelf.copyAll() }
                    NotchIconButton(symbol: "trash", help: "Clear", size: 11) { shelf.clear() }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { item in NotchShelfTile(item: item) }
                    }
                }
            }
            // While something's dragged over the notch: where it'll land.
            .overlay {
                if NotchCenter.shared.dropTargeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct NotchShelfTile: View {
    let item: Shelf.Item
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            thumbnail.frame(width: 48, height: 48)
            Text(item.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 72)
        }
        .frame(width: 80, height: 96)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0.05)))
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { Shelf.shared.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .onHover { hover = $0 }
        .onDrag { item.provider }
    }

    @ViewBuilder private var thumbnail: some View {
        switch item.content {
        case .file(let url): Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high)
        case .image(let img): Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 6))
        case .text: Image(systemName: "text.alignleft").font(.system(size: 22)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

@MainActor
enum NotchShelfActions {
    private static var objects: [Any] {
        Shelf.shared.items.map {
            switch $0.content {
            case .file(let url): url as Any
            case .image(let img): img as Any
            case .text(let s): s as Any
            }
        }
    }

    static func airDrop() {
        guard let service = NSSharingService(named: .sendViaAirDrop), !objects.isEmpty else { return }
        NotchCenter.shared.close()
        service.perform(withItems: objects)
    }

    /// The share menu, under the notch.
    static func share() {
        guard !objects.isEmpty, let screen = NSScreen.screens.first(where: { $0.displayID == NotchCenter.shared.primary }) ?? NSScreen.main else { return }
        let picker = NSSharingServicePicker(items: objects)
        // A tiny window to anchor the menu, where the notch is.
        let anchor = NSWindow(contentRect: NSRect(x: screen.notchMidX, y: screen.frame.maxY - 60, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        anchor.level = .statusBar
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.isReleasedWhenClosed = false
        anchor.orderFrontRegardless()
        if let view = anchor.contentView { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { anchor.orderOut(nil) }
    }
}

// MARK: - Mirror

/// The camera only starts when you ask, and stops the moment the tab or the notch closes.
private struct NotchMirrorTab: View {
    @State private var on = false
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06))
                if on {
                    CameraMirror().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Image(systemName: denied ? "video.slash.fill" : "person.crop.square").font(.system(size: 26)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 200, height: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text("Mirror").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(denied ? "Allow Orbit to use the camera in System Settings." : "Check your hair before the call. Nothing is recorded.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                Button(on ? "Turn Off" : "Turn On Camera") { toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? .white : .black)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(on ? .white.opacity(0.16) : .white))
                    .disabled(denied)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle() {
        if on { on = false; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: on = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    on = ok
                    denied = !ok
                }
            }
        default: denied = true
        }
    }
}

private struct CameraMirror: NSViewRepresentable {
    func makeNSView(context: Context) -> MirrorView { MirrorView() }
    func updateNSView(_ view: MirrorView, context: Context) {}
    static func dismantleNSView(_ view: MirrorView, coordinator: ()) { view.stop() }
}

final class MirrorView: NSView {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "orbit.notch.mirror")
    private var preview: AVCaptureVideoPreviewLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        session.sessionPreset = .medium
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let p = AVCaptureVideoPreviewLayer(session: session)
        p.videoGravity = .resizeAspectFill
        if let c = p.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        layer?.addSublayer(p)
        preview = p
        let session = self.session
        queue.async { session.startRunning() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        preview?.frame = bounds
    }

    func stop() {
        let session = self.session
        queue.async { session.stopRunning() }
    }
}

// MARK: - Timer

private struct NotchTimerTab: View {
    private var timer: NotchTimer { .shared }

    var body: some View {
        if timer.isRunning { running } else { presets }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach([1, 5, 10, 25], id: \.self) { m in
                    Button { timer.start(minutes: Double(m)) } label: {
                        VStack(spacing: 0) {
                            Text("\(m)").font(.system(size: 22, weight: .semibold).monospacedDigit())
                            Text("min").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 62)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(NotchPressStyle())
                }
            }
            Button { timer.startPomodoro() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill").foregroundStyle(Palette.brand)
                    Text("Pomodoro").font(.system(size: 12, weight: .semibold))
                    Text("25 + 5 min").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Image(systemName: "play.fill").font(.system(size: 10))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(NotchPressStyle())
        }
    }

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = timer.remaining(at: ctx.date)
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 6)
                    Circle().trim(from: 0, to: timer.total > 0 ? max(0.001, left / timer.total) : 0)
                        .stroke(timer.kind == .rest ? Color.green : Palette.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: left)
                    Text(NotchTimer.clock(left)).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .contentTransition(.numericText())
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 10) {
                    Text(timer.label.loc).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    if timer.pomodoro {
                        Text("Round %ld".loc(timer.round)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    HStack(spacing: 6) {
                        NotchIconButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", help: timer.isPaused ? "Resume" : "Pause", size: 14) {
                            timer.isPaused ? timer.resume() : timer.pause()
                        }
                        NotchIconButton(symbol: "goforward.plus", help: "Add a Minute", size: 14) { timer.add(minutes: 1) }
                        NotchIconButton(symbol: "stop.fill", help: "Stop", size: 14) { timer.stop() }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct NotchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

// MARK: - Clipboard

private struct NotchClipboardTab: View {
    var body: some View {
        let items = Array(ClipboardStore.shared.items.prefix(5))
        if items.isEmpty {
            Text("Nothing copied yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 2) {
                ForEach(items) { item in NotchClipRow(item: item) }
            }
        }
    }
}

private struct NotchClipRow: View {
    let item: ClipItem
    @State private var hover = false

    var body: some View {
        Button { paste() } label: {
            HStack(spacing: 9) {
                thumb.frame(width: 20, height: 20)
                Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 4)
                if let app = item.appName {
                    Text(app).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
                Image(systemName: "return").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(hover ? 0.6 : 0))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var text: String {
        switch item.kind {
        case .image: item.ocrText.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? "Image".loc
        case .file: (item.filePaths ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default: (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        }
    }

    @ViewBuilder private var thumb: some View {
        if item.kind == .image, let url = item.imageURL, let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 4))
        } else if item.kind == .color, let hex = item.text, let c = NSColor(hexString: hex) {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c))
        } else {
            Image(systemName: item.kind.symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }

    /// Back into the app in front, like picking it in Clipboard History.
    private func paste() {
        ClipboardStore.shared.copy(item)
        NotchCenter.shared.close()
        let front = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { _ = Paster.paste(into: front) }
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
