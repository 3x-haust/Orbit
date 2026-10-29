import AppKit
import SwiftUI
import Observation

/// CleanShot-style floating results in the bottom-left corner. Never steals focus.
@MainActor @Observable
final class QuickAccess {
    static let shared = QuickAccess()

    private(set) var items: [Capture] = []
    var hovering: Set<UUID> = []
    /// Slid off to the left edge, leaving a small tab; nothing auto-dismisses while tucked.
    private(set) var tucked = false
    /// Came back from the editor: stays until closed by hand.
    private var kept: Set<UUID> = []
    private var timers: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero, focusable: false)
        p.level = .statusBar
        p.hasShadow = false
        p.setContent(QuickAccessStack(model: self))
        return p
    }()

    private static let maxVisible = 3

    /// The corner previews live in, from settings.
    var onLeft: Bool { !(Pref.defaults.string(forKey: Pref.captureThumbnailCorner) ?? "").hasSuffix("Right") }
    var onTop: Bool { (Pref.defaults.string(forKey: Pref.captureThumbnailCorner) ?? "").hasPrefix("top") }

    func add(_ capture: Capture, keep: Bool = false) {
        if keep { kept.insert(capture.id) }
        withAnimation(Motion.adaptive(Motion.panelEnter)) {
            items.removeAll { $0.id == capture.id }
            items.insert(capture, at: 0)
            if items.count > Self.maxVisible { items.removeLast() }
        }
        layout()
        scheduleDismiss(capture)
    }

    func setTucked(_ on: Bool) {
        tucked = on
        if on { timers.values.forEach { $0.cancel() }; timers.removeAll() }
        else { items.forEach(scheduleDismiss) }
        layout()
    }

    func dismiss(_ capture: Capture) {
        timers[capture.id]?.cancel()
        timers[capture.id] = nil
        kept.remove(capture.id)
        withAnimation(Motion.adaptive(Motion.reflow)) { items.removeAll { $0.id == capture.id } }
        if items.isEmpty { tucked = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.layout() }
    }

    func setHover(_ capture: Capture, _ on: Bool) {
        if on {
            hovering.insert(capture.id)
            timers[capture.id]?.cancel()
        } else {
            hovering.remove(capture.id)
            scheduleDismiss(capture)
        }
    }

    private func scheduleDismiss(_ capture: Capture) {
        timers[capture.id]?.cancel()
        let seconds = Pref.defaults.double(forKey: Pref.captureThumbnailSeconds)
        guard seconds > 0, !tucked, !kept.contains(capture.id) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering.contains(capture.id) else { return }
            self.dismiss(capture)
        }
        timers[capture.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Corner

    /// The four corners previews can live in (the `capture.thumbnailCorner` pref).
    static let corners = ["bottomLeft", "bottomRight", "topLeft", "topRight"]

    /// "Preview" in settings: a real card at the chosen corner for a couple of seconds.
    func showSample() {
        let capture: Capture
        if let recent = CaptureService.shared.recent.first(where: { !$0.opensExternally }) {
            capture = Capture(image: recent.image, fileURL: recent.fileURL)
        } else {
            let image = NSApp.applicationIconImage ?? NSImage(size: NSSize(width: 64, height: 64))
            capture = Capture(image: image, fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("Orbit preview.png"))
        }
        add(capture, keep: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.hovering.contains(capture.id) else { return }
            self.dismiss(capture)
        }
    }

    static func height(for capture: Capture) -> CGFloat {
        let s = capture.image.size
        guard s.width > 0 else { return Size.thumbnailMaxHeight }
        return min(max(Size.thumbnailWidth * s.height / s.width, 96), Size.thumbnailMaxHeight)
    }

    /// Resizes the panel to its content so the empty area never blocks clicks.
    private func layout(animated: Bool = false) {
        guard !items.isEmpty else { panel.orderOut(nil); return }
        let pad = Space.standard
        let screen = NSScreen.active.visibleFrame
        let frame: NSRect
        if tucked {
            // A tab flush with the side edge.
            let t = Self.tabSize
            frame = NSRect(x: onLeft ? screen.minX : screen.maxX - t.width,
                           y: onTop ? screen.maxY - Size.edgeOffset - t.height : screen.minY + Size.edgeOffset,
                           width: t.width, height: t.height)
        } else {
            let height = items.map(Self.height).reduce(0, +) + CGFloat(items.count - 1) * Space.related + pad * 2
            let width = Size.thumbnailWidth + pad * 2
            frame = NSRect(x: onLeft ? screen.minX + Size.edgeOffset - pad : screen.maxX - Size.edgeOffset + pad - width,
                           y: onTop ? screen.maxY - Size.edgeOffset + pad - height : screen.minY + Size.edgeOffset - pad,
                           width: width, height: height)
        }
        if panel.isVisible {
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true, animate: false)
            }
        } else {
            panel.present(at: frame)
        }
    }

    // MARK: Actions

    func copy(_ c: Capture) {
        if c.opensExternally {
            // Recordings and GIFs go on the clipboard as the file, ready to paste into a chat or Finder.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([c.fileURL as NSURL])
            ClipboardStore.shared.markOwnWrite()
        } else {
            CaptureService.shared.copy(c.image)
        }
        Toast.show("Copied")
        dismiss(c)
    }

    /// Recordings play in QuickTime; GIFs open in their default app.
    func play(_ c: Capture) { VideoTools.open(c.fileURL) }

    /// Opens a recording in Orbit's video editor; closing it brings the thumbnail back, kept.
    func editVideo(_ c: Capture) {
        dismiss(c)
        VideoEditorWindow.open(c.fileURL) { QuickAccess.shared.add(c, keep: true) }
    }

    /// Click on a thumbnail: edit a screenshot or recording, open a GIF.
    func open(_ c: Capture) {
        if c.isVideo { editVideo(c) } else if c.opensExternally { play(c) } else { annotate(c) }
    }

    func makeGIF(_ c: Capture) {
        Toast.show("Making a GIF…", symbol: "photo.stack")
        Task {
            guard let gif = await VideoTools.exportGIF(c.fileURL) else {
                Toast.show("Couldn’t make a GIF", symbol: "exclamationmark.triangle.fill")
                return
            }
            add(Capture(image: c.image, fileURL: gif))
        }
    }

    func save(_ c: Capture) {
        if let url = CaptureService.shared.save(c) {
            Toast.show("Saved", symbol: "arrow.down.circle.fill", detail: url.deletingLastPathComponent().lastPathComponent)
        }
        dismiss(c)
    }

    /// Throws the capture away: its file goes to the Trash (where it can still be put back), the card goes.
    func delete(_ c: Capture) {
        if FileManager.default.fileExists(atPath: c.fileURL.path) {
            do {
                try FileManager.default.trashItem(at: c.fileURL, resultingItemURL: nil)
            } catch {
                Toast.show("Couldn’t move it to the Trash", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
                return
            }
        }
        CaptureService.shared.remove(c)
        dismiss(c)
        Toast.show("Moved to Trash", symbol: "trash", detail: "You can put it back from the Trash in Finder.".loc)
    }

    static let tabSize = CGSize(width: 30, height: 64)

    /// Opens the editor; closing the editor brings the thumbnail back, kept, so it can sit at the side.
    func annotate(_ c: Capture) {
        dismiss(c)
        EditorWindow.open(image: c.image, fileURL: c.fileURL) { QuickAccess.shared.add(c, keep: true) }
    }
    func pin(_ c: Capture) { dismiss(c); PinWindow.pin(c.image, fileURL: c.fileURL) }

    func reveal(_ c: Capture) {
        if FileManager.default.fileExists(atPath: c.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([c.fileURL])
        } else if let url = CaptureService.shared.save(c) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The card's right-click menu: the actions that used to crowd it as buttons.
    func menu(for c: Capture) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            menu.addItem(ActionMenuItem(title: title.loc, symbol: symbol, action: action))
        }
        if c.isVideo {
            item("Trim & Edit", "scissors") { self.editVideo(c) }
            item("Open in QuickTime", "play.rectangle") { self.play(c) }
            item("Export as GIF", "photo.stack") { self.makeGIF(c) }
        } else if c.isGIF {
            item("Open", "play.fill") { self.play(c) }
        } else {
            item("Edit", "pencil.tip.crop.circle") { self.annotate(c) }
            item("Copy Text", "text.viewfinder") { self.recognize(c) }
            item("Pin to Screen", "pin") { self.pin(c) }
        }
        menu.addItem(.separator())
        item("Copy", "doc.on.doc") { self.copy(c) }
        item("Save to Folder", "arrow.down.circle") { self.save(c) }
        item("Show in Finder", "folder") { self.reveal(c) }
        menu.addItem(.separator())
        item("Tuck to the Side", "arrow.left.to.line") {
            withAnimation(Motion.adaptive(Motion.reflow)) { self.setTucked(true) }
        }
        item("Close", "xmark") { self.dismiss(c) }
        menu.addItem(.separator())
        item("Move to Trash", "trash") { self.delete(c) }
        return menu
    }
    func recognize(_ c: Capture) {
        guard let cg = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task {
            let text = (try? await OCR.recognize(cg)) ?? ""
            guard !text.isEmpty else { Toast.show("No text found", symbol: "text.viewfinder"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Text copied", symbol: "text.viewfinder", detail: text.replacingOccurrences(of: "\n", with: " "))
        }
    }
}

#if DEBUG
extension QuickAccess {
    /// Debug: shows one real thumbnail of `image`, kept, for promo frames. Returns its panel's window number.
    func debugShow(_ image: NSImage, fileURL: URL) -> Int {
        items.removeAll()
        tucked = false
        add(Capture(image: image, fileURL: fileURL), keep: true)
        return panel.windowNumber
    }

    func debugClear() {
        items.forEach(dismiss)
    }
}
#endif

private struct QuickAccessStack: View {
    let model: QuickAccess

    var body: some View {
        if model.tucked { TuckTab(model: model) } else { stack }
    }

    private var stack: some View {
        // Newest nearest the corner.
        let ordered = model.onTop ? model.items : model.items.reversed()
        return VStack(spacing: Space.related) {
            if !model.onTop { Spacer(minLength: 0) }
            ForEach(ordered) { capture in
                ThumbnailCard(capture: capture, model: model)
                    .transition(.asymmetric(insertion: .move(edge: model.onLeft ? .leading : .trailing).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
            if model.onTop { Spacer(minLength: 0) }
        }
        .padding(Space.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.onTop ? .top : .bottom)
    }
}

/// What's left of the thumbnails when tucked: a tab on the left edge with the newest one in it.
private struct TuckTab: View {
    let model: QuickAccess
    @State private var hovering = false

    var body: some View {
        Button { withAnimation(Motion.adaptive(Motion.panelEnter)) { model.setTucked(false) } } label: {
            VStack(spacing: 4) {
                if let c = model.items.first {
                    Image(nsImage: c.image).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Image(systemName: model.onLeft ? "chevron.compact.right" : "chevron.compact.left").font(.system(size: 12, weight: .bold))
                if model.items.count > 1 {
                    Text("\(model.items.count)").font(.system(size: 9, weight: .bold).monospacedDigit())
                }
            }
            .foregroundStyle(Palette.ink)
            .frame(width: QuickAccess.tabSize.width, height: QuickAccess.tabSize.height)
            .background(tabShape
                .fill(hovering ? Palette.raised : Palette.surface))
            .overlay(tabShape
                .strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Show screenshots".loc)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }

    /// Square on the screen-edge side, rounded on the other.
    private var tabShape: UnevenRoundedRectangle {
        let r: CGFloat = 10
        return model.onLeft
            ? UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
    }
}

private struct ThumbnailCard: View {
    let capture: Capture
    let model: QuickAccess
    @State private var hovering = false
    /// How far it's been swiped toward the screen edge.
    @State private var swipe: CGFloat = 0
    /// Out with the pointer as a file drag; the card itself is what's being carried.
    @State private var carried = false

    var body: some View {
        ZStack {
            // Whole picture, never cropped or blown up — a small capture shows at its real size.
            Rectangle().fill(Color(white: 0.12))
            Image(nsImage: capture.image)
                .resizable()
                .interpolation(isSmall ? .none : .high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: min(Size.thumbnailWidth - 16, capture.image.size.width),
                       maxHeight: min(QuickAccess.height(for: capture) - 16, capture.image.size.height))
            if capture.opensExternally, !hovering {
                mediaBadge
            }
            if isSmall, !capture.opensExternally, !hovering {
                Text("\(Int(capture.image.size.width)) × \(Int(capture.image.size.height))")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            // Click to edit, swipe toward the edge to dismiss, drag anywhere else to share the file.
            SwipeOrDrag(edge: model.onLeft ? -1 : 1, fileURL: capture.fileURL, image: capture.image,
                        tap: { model.open(capture) },
                        menu: { model.menu(for: capture) },
                        swiping: { swipe = $0 },
                        swiped: { gone in
                            if gone { model.dismiss(capture) }
                            else { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { swipe = 0 } }
                        },
                        carrying: { on in
                            carried = on
                            on ? model.setHover(capture, true) : model.setHover(capture, false)
                        },
                        dropped: { model.dismiss(capture) })

            if hovering {
                Rectangle().fill(.black.opacity(0.32)).allowsHitTesting(false)
                overlayControls
                    .transition(.opacity)
            }
        }
        .frame(width: Size.thumbnailWidth, height: QuickAccess.height(for: capture))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .offset(x: swipe)
        .opacity(carried ? 0 : 1 - min(0.7, abs(swipe) / 260))
        .onHover { h in
            withAnimation(Motion.hover) { hovering = h }
            model.setHover(capture, h)
        }
        .accessibilityLabel(capture.isVideo ? "Recording" : "Screenshot")
    }

    /// Play button and length for a recording; a "GIF" tag for a GIF.
    private var mediaBadge: some View {
        ZStack {
            if capture.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.black.opacity(0.5)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
            Text(capture.isVideo ? (VideoTools.durationText(capture.fileURL) ?? "") : "GIF")
                .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }

    private var isSmall: Bool {
        capture.image.size.width < Size.thumbnailWidth * 0.8 && capture.image.size.height < QuickAccess.height(for: capture) * 0.8
    }

    /// Just the essentials, so most of the card is free to drag out; the rest is on right-click.
    private var overlayControls: some View {
        VStack {
            HStack {
                if !capture.opensExternally {
                    GlassIcon(symbol: "pin.fill", help: "Pin to Screen") { model.pin(capture) }
                }
                Spacer()
                GlassIcon(symbol: "trash", help: "Move to Trash") { model.delete(capture) }
                GlassIcon(symbol: "xmark", help: "Close") { model.dismiss(capture) }
            }
            Spacer()
            HStack(spacing: Space.compact) {
                GlassButton(title: "Copy", help: "Copy") { model.copy(capture) }
                GlassButton(title: "Save", help: "Save to Folder") { model.save(capture) }
            }
            Spacer()
            Text(hint)
                .font(.orbitMicro).foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .allowsHitTesting(false)
        }
        .padding(Space.compact)
    }

    private var hint: String {
        (capture.isVideo ? "Click to trim · right-click for more" : capture.isGIF ? "Click to play · right-click for more" : "Click to edit · right-click for more").loc
    }
}

private struct GlassButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.loc)
                .font(.orbitBodyEmphasized)
                .foregroundStyle(.white)
                .frame(width: 76, height: 30)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help(help.loc)
    }
}

private struct GlassIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help.loc)
        .accessibilityLabel(help)
    }
}

/// One mouse gesture, three meanings, like macOS's own screenshot preview: a click, a swipe toward
/// the screen edge (dismiss), or a drag in any other direction (a real file drag to share it).
private struct SwipeOrDrag: NSViewRepresentable {
    /// -1 when the nearest screen edge is on the left, 1 on the right.
    let edge: CGFloat
    let fileURL: URL
    let image: NSImage
    let tap: () -> Void
    /// Right-click: everything the card doesn't show as a button.
    let menu: () -> NSMenu
    let swiping: (CGFloat) -> Void
    let swiped: (Bool) -> Void
    let carrying: (Bool) -> Void
    let dropped: () -> Void

    func makeNSView(context: Context) -> GestureView { GestureView() }
    func updateNSView(_ view: GestureView, context: Context) { view.config = self }

    final class GestureView: NSView, NSDraggingSource {
        var config: SwipeOrDrag?
        private enum Mode { case pending, swipe, drag }
        private var start: NSPoint?
        private var mode = Mode.pending

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            mode = .pending
        }

        override func menu(for event: NSEvent) -> NSMenu? { config?.menu() }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let config else { return }
            let p = NSEvent.mouseLocation
            let dx = p.x - start.x, dy = p.y - start.y
            if mode == .pending, hypot(dx, dy) > 5 {
                mode = dx * config.edge > 0 && abs(dx) > abs(dy) ? .swipe : .drag
                if mode == .drag { beginDrag(event) }
            }
            if mode == .swipe { config.swiping(dx * config.edge > 0 ? dx : dx * 0.2) }
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil; mode = .pending }
            guard let start, let config else { return }
            switch mode {
            case .pending: config.tap()
            case .swipe:
                let dx = NSEvent.mouseLocation.x - start.x
                config.swiped(dx * config.edge > 70)
            case .drag: break
            }
        }

        /// The drag image is the whole card at its place, so it looks like the card lifts off and follows
        /// the pointer; the real card hides until the drop (or slides back if there's none).
        private func beginDrag(_ event: NSEvent) {
            guard let config else { return }
            let item = NSDraggingItem(pasteboardWriter: config.fileURL as NSURL)
            item.setDraggingFrame(bounds, contents: Self.card(config.image, size: bounds.size))
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            config.carrying(true)
        }

        private static func card(_ image: NSImage, size: NSSize) -> NSImage {
            NSImage(size: size, flipped: false) { rect in
                let clip = NSBezierPath(roundedRect: rect, xRadius: Radius.card, yRadius: Radius.card)
                clip.addClip()
                NSColor(white: 0.12, alpha: 1).setFill()
                rect.fill()
                let s = image.size
                let k = min(rect.width / max(1, s.width), rect.height / max(1, s.height), 1)
                let w = s.width * k, h = s.height * k
                image.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
                return true
            }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if operation != [] { config?.dropped() }
            else {
                // Wait for the slide back before the real card reappears in its place.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.config?.carrying(false) }
            }
        }
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
