import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Trim, mute and export a recording: player on top, a filmstrip with trim handles below.
@MainActor @Observable
final class VideoEditorModel {
    let url: URL
    let player: AVPlayer
    private(set) var duration: Double = 0
    private(set) var size: CGSize = CGSize(width: 1280, height: 720)
    private(set) var hasAudio = false
    private(set) var frames: [CGImage] = []
    var start: Double = 0 { didSet { exported = nil } }
    var end: Double = 0 { didSet { exported = nil } }
    var muted = false { didSet { player.isMuted = muted; exported = nil } }
    private(set) var current: Double = 0
    private(set) var playing = false
    private(set) var working: String?

    /// The last export of the current edit, reused for copy / drag until something changes.
    @ObservationIgnored private var exported: URL?
    @ObservationIgnored private var observer: Any?

    var edited: Bool { start > 0.05 || end < duration - 0.05 || muted }
    var range: ClosedRange<Double> { start...max(start + 0.1, end) }

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        Task { await load() }
    }

    func tearDown() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        end = duration
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = CGRect(origin: .zero, size: natural).applying(t)
            size = CGSize(width: abs(r.width), height: abs(r.height))
        }
        hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        exported = nil
        await loadFrames(asset)
    }

    private func loadFrames(_ asset: AVURLAsset) async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let count = 14
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { images.append(image) }
        }
        withAnimation(.easeOut(duration: 0.2)) { frames = images }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        current = seconds
        if playing, seconds >= end - 0.01 {
            player.pause()
            playing = false
            seek(end)
        }
        if playing, player.rate == 0 { playing = false }
    }

    func togglePlay() {
        if playing {
            player.pause()
            playing = false
        } else {
            if current >= end - 0.05 || current < start { seek(start) }
            player.play()
            playing = true
        }
    }

    func seek(_ seconds: Double) {
        let t = min(max(0, seconds), duration)
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func reset() {
        start = 0
        end = duration
        muted = false
    }

    // MARK: Export

    enum Format { case mp4, gif }

    /// The edited clip as a file: the original when nothing changed.
    func render(_ format: Format = .mp4) async -> URL? {
        if format == .mp4, !edited { return url }
        if format == .mp4, let exported, FileManager.default.fileExists(atPath: exported.path) { return exported }
        let suffix = edited ? " (Edited)" : ""
        let name = url.deletingPathExtension().lastPathComponent + suffix
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        working = format == .gif ? "Making a GIF…".loc : "Exporting…".loc
        defer { working = nil }
        switch format {
        case .gif:
            return await VideoTools.exportGIF(url, range: range, to: out.appendingPathComponent(name + ".gif"))
        case .mp4:
            let dest = out.appendingPathComponent(name + ".mp4")
            do {
                try await VideoTools.exportMP4(url, range: range, muted: muted, to: dest)
                exported = dest
                return dest
            } catch {
                Toast.show("Couldn’t export the video", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
                return nil
            }
        }
    }

    func copy() {
        Task {
            guard let file = await render() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([file as NSURL])
            ClipboardStore.shared.markOwnWrite()
            Toast.show("Copied")
        }
    }

    /// Into the capture folder; `ask` lets you pick the place and name.
    func save(_ format: Format, ask: Bool, in window: NSWindow?) {
        Task {
            guard let file = await render(format) else {
                if format == .gif { Toast.show("Couldn’t make a GIF", symbol: "exclamationmark.triangle.fill") }
                return
            }
            let folder = URL(fileURLWithPath: Pref.defaults.string(forKey: Pref.captureSaveFolder) ?? NSHomeDirectory())
            let name = file.lastPathComponent
            if ask {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.directoryURL = folder
                panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
                let response: NSApplication.ModalResponse
                if let window { response = await panel.beginSheetModal(for: window) } else { response = panel.runModal() }
                guard response == .OK, let dest = panel.url else { return }
                Self.place(file, at: dest)
            } else {
                let dest = folder.appendingPathComponent(name)
                Self.place(file, at: dest)
                Toast.show("Saved", symbol: "arrow.down.circle.fill", detail: dest.lastPathComponent)
            }
        }
    }

    private static func place(_ file: URL, at dest: URL) {
        guard file.standardizedFileURL != dest.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: file, to: dest)
    }

    /// A drag of the edited clip: ready at once when nothing changed or it was exported already,
    /// otherwise written when it's dropped.
    func dragProvider() -> NSItemProvider {
        if !edited { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        if let exported, FileManager.default.fileExists(atPath: exported.path) {
            return NSItemProvider(contentsOf: exported) ?? NSItemProvider()
        }
        let provider = NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent + " (Edited)"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.mpeg4Movie.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                let file = await self.render()
                done(file, false, file == nil ? CocoaError(.fileWriteUnknown) : nil)
            }
            return nil
        }
        return provider
    }
}

// MARK: - Window

@MainActor
final class VideoEditorWindow: NSWindow, NSWindowDelegate {
    private static var open: Set<VideoEditorWindow> = []
    private let model: VideoEditorModel
    private var monitor: Any?
    private var onClose: (() -> Void)?

    static func open(_ url: URL, onClose: (() -> Void)? = nil) {
        if let existing = open.first(where: { $0.model.url == url }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = VideoEditorWindow(model: VideoEditorModel(url: url))
        window.onClose = onClose
        open.insert(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private init(model: VideoEditorModel) {
        self.model = model
        let screen = NSScreen.active.visibleFrame
        let w = min(1100, screen.width * 0.8), h = min(760, screen.height * 0.82)
        super.init(contentRect: NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = model.url.deletingPathExtension().lastPathComponent
        isReleasedWhenClosed = false
        minSize = NSSize(width: 680, height: 460)
        delegate = self
        let host = NSHostingView(rootView: VideoEditorView(model: model, window: { [weak self] in self }).orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = []
        contentView = FloatingPanel.container(for: host)
        installKeys()
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        model.tearDown()
        Self.open.remove(self)
        onClose?()
        onClose = nil
    }

    /// Space plays, ←/→ step, I/O set the trim points, ⌘S / ⌘⇧S save, ⌘C copies, Esc closes.
    private func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.contains(.command) {
                switch chars {
                case "s": self.model.save(.mp4, ask: flags.contains(.shift), in: self); return nil
                case "c": self.model.copy(); return nil
                default: return event
                }
            }
            switch event.keyCode {
            case 49: self.model.togglePlay(); return nil
            case 123: self.model.seek(self.model.current - (flags.contains(.shift) ? 1 : 1 / 30)); return nil
            case 124: self.model.seek(self.model.current + (flags.contains(.shift) ? 1 : 1 / 30)); return nil
            case 53: self.close(); return nil
            default: break
            }
            switch chars {
            case "i": self.model.start = min(self.model.current, self.model.end - 0.1); return nil
            case "o": self.model.end = max(self.model.current, self.model.start + 0.1); return nil
            case "m" where self.model.hasAudio: self.model.muted.toggle(); return nil
            default: return event
            }
        }
    }
}

// MARK: - Views

private struct VideoEditorView: View {
    @Bindable var model: VideoEditorModel
    let window: () -> NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            PlayerSurface(player: model.player)
                .aspectRatio(model.size, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { model.togglePlay() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            controls
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
        }
        .background(Palette.canvas)
        .overlay {
            if let working = model.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                }
                .padding(.horizontal, 14).frame(height: 34)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.working)
        .focusEffectDisabled()
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(model.url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)
            if model.hasAudio {
                ToolIcon(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                         hint: (model.muted ? "Sound off · M" : "Sound on · M").loc, active: model.muted) { model.muted.toggle() }
            }
            ToolIcon(symbol: "arrow.uturn.backward", hint: "Undo edits".loc, active: false) { withAnimation(Motion.reflow) { model.reset() } }
                .disabled(!model.edited).opacity(model.edited ? 1 : 0.4)
            DragChip(model: model)
            Button("Copy") { model.copy() }
                .buttonStyle(PillButtonStyle(prominent: false))
                .hoverHint("Copy the video · ⌘C".loc)
            Menu {
                Button("Save as MP4") { model.save(.mp4, ask: false, in: window()) }
                Button("Save as MP4…") { model.save(.mp4, ask: true, in: window()) }
                Divider()
                Button("Save as GIF") { model.save(.gif, ask: false, in: window()) }
                Button("Save as GIF…") { model.save(.gif, ask: true, in: window()) }
            } label: {
                Text("Save").font(.system(size: 13, weight: .semibold))
            } primaryAction: {
                model.save(.mp4, ask: false, in: window())
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle(prominent: true))
            .fixedSize()
            .hoverHint("Save to Folder · ⌘S".loc)
        }
        // Clear of the traffic lights.
        .padding(.leading, 86).padding(.trailing, 16)
        .frame(height: 52)
        .zIndex(1)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.canvas)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.ink))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .hoverHint((model.playing ? "Pause · Space" : "Play · Space").loc, below: false)
                Text("\(Self.clock(model.current)) / \(Self.clock(model.duration))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                Spacer()
                Text(model.edited ? "Keeping %@".loc(Self.clock(model.range.upperBound - model.range.lowerBound)) : "Drag the ends to trim".loc)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(model.edited ? Palette.accent : Palette.inkSecondary)
                    .contentTransition(.opacity)
            }
            Timeline(model: model)
                .frame(height: 56)
        }
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        let s = max(0, seconds)
        return String(format: "%d:%02d.%d", Int(s) / 60, Int(s) % 60, Int((s * 10).truncatingRemainder(dividingBy: 10)))
    }
}

/// The filmstrip: drag the orange handles to trim, anywhere else to scrub.
private struct Timeline: View {
    @Bindable var model: VideoEditorModel
    @State private var grabbing: Handle?

    private enum Handle { case start, end }
    private let handle: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - handle * 2)
            let x = { (t: Double) in handle + CGFloat(model.duration > 0 ? t / model.duration : 0) * width }
            ZStack(alignment: .topLeading) {
                // Frames.
                HStack(spacing: 0) {
                    ForEach(Array(model.frames.enumerated()), id: \.offset) { _, frame in
                        Image(decorative: frame, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(max(1, model.frames.count)), height: geo.size.height)
                            .clipped()
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .background(Palette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .offset(x: handle)

                // Dimmed outside the kept part.
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, x(model.start) - handle), height: geo.size.height).offset(x: handle)
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, handle + width - x(model.end)), height: geo.size.height).offset(x: x(model.end))

                // The kept part's frame with its two handles.
                let keptWidth = max(0, x(model.end) - x(model.start))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.accent, lineWidth: 3)
                    .frame(width: keptWidth + handle * 2, height: geo.size.height)
                    .offset(x: x(model.start) - handle)
                    .allowsHitTesting(false)
                grip.offset(x: x(model.start) - handle)
                grip.offset(x: x(model.end))

                // Playhead.
                Capsule().fill(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .frame(width: 3, height: geo.size.height + 8)
                    .offset(x: x(model.current) - 1.5, y: -4)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let t = Double((g.location.x - handle) / width) * model.duration
                if grabbing == nil {
                    let startX = x(model.start), endX = x(model.end)
                    if abs(g.startLocation.x - startX) < 16, abs(g.startLocation.x - startX) <= abs(g.startLocation.x - endX) {
                        grabbing = .start
                    } else if abs(g.startLocation.x - endX) < 16 {
                        grabbing = .end
                    }
                }
                switch grabbing {
                case .start:
                    model.start = min(max(0, t), model.end - 0.1)
                    model.seek(model.start)
                case .end:
                    model.end = max(min(model.duration, t), model.start + 0.1)
                    model.seek(model.end)
                case nil:
                    model.seek(min(max(model.start, t), model.end))
                }
            }.onEnded { _ in grabbing = nil })
        }
    }

    private var grip: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Palette.accent)
            .frame(width: handle)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 16))
            .allowsHitTesting(false)
    }
}

/// Drag it into a chat or Finder to share the edited clip.
private struct DragChip: View {
    let model: VideoEditorModel

    var body: some View {
        Image(systemName: "hand.draw")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Palette.raised))
            .contentShape(Circle())
            .onDrag { model.dragProvider() }
            .hoverHint("Drag to share".loc)
    }
}

private struct ToolIcon: View {
    let symbol: String
    let hint: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Palette.accent : Palette.ink)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Palette.raised.opacity(hovering ? 1 : 0.7)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .hoverHint(hint)
        .accessibilityLabel(hint)
    }
}

/// A bare AVPlayerLayer — Orbit draws its own controls.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
