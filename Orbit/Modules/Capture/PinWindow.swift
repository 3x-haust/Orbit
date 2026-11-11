import AppKit
import SwiftUI
import Observation

/// A movable reference above other apps, with a separate control bar that stays interactive
/// even when clicks pass through the picture. Scroll changes opacity; pinch resizes.
@MainActor
final class PinWindow: NSPanel, NSWindowDelegate {
    private static var open: Set<PinWindow> = []

    @discardableResult
    static func pin(_ image: NSImage, fileURL: URL? = nil) -> PinWindow {
        let screen = NSScreen.active.visibleFrame
        var size = image.size
        let maxSide = min(screen.width, screen.height) * 0.6
        if max(size.width, size.height) > maxSide {
            let f = maxSide / max(size.width, size.height)
            size = CGSize(width: size.width * f, height: size.height * f)
        }
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        let window = PinWindow(image: image, fileURL: fileURL, frame: frame)
        open.insert(window)
        window.orderFront(nil)
        window.showControls()
        return window
    }

    private let image: NSImage
    private let fileURL: URL?
    private let reference = PinReferenceState()
    private var controls: FloatingPanel?
    private var textTask: Task<Void, Never>?

    private init(image: NSImage, fileURL: URL?, frame: NSRect) {
        self.image = image
        self.fileURL = fileURL
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = image.size
        minSize = NSSize(width: 60, height: 60)
        delegate = self
        let host = MovableHostingView(rootView: PinView(image: image, close: { [weak self] in self?.close() },
                                                      unpin: { [weak self] in self?.unpin() }).orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = []
        contentView = FloatingPanel.container(for: host)
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override func cancelOperation(_ sender: Any?) { close() }

    override func magnify(with event: NSEvent) {
        var f = frame
        let factor = 1 + event.magnification
        let size = NSSize(width: max(minSize.width, f.width * factor), height: max(minSize.height, f.height * factor))
        f.origin.x -= (size.width - f.width) / 2
        f.origin.y -= (size.height - f.height) / 2
        f.size = size
        setFrame(f, display: true)
    }

    override func scrollWheel(with event: NSEvent) {
        setOpacity(alphaValue + event.scrollingDeltaY * 0.01)
    }

    func setOpacity(_ value: CGFloat) {
        reference.opacity = min(1, max(0.2, value))
        alphaValue = reference.opacity
    }

    func setClickThrough(_ on: Bool) {
        reference.clickThrough = on
        ignoresMouseEvents = on
        if on, isKeyWindow { resignKey() }
    }

    private func showControls() {
        let panel = FloatingPanel(contentRect: .zero, focusable: true)
        panel.title = "Reference Controls".loc
        panel.setContent(PinControls(state: reference, opacity: { [weak self] in self?.setOpacity($0) },
                                    clickThrough: { [weak self] in self?.setClickThrough($0) },
                                    copyText: { [weak self] in self?.recognizeText(translate: false) },
                                    translate: { [weak self] in self?.recognizeText(translate: true) },
                                    unpin: { [weak self] in self?.unpin() }, close: { [weak self] in self?.close() }))
        // Never let FloatingPanel's default Esc hide the only way to unlock a reference.
        panel.onEscape = { [weak self] in
            guard let self else { return true }
            if self.ignoresMouseEvents { self.setClickThrough(false) } else { self.close() }
            return true
        }
        controls = panel
        positionControls()
        addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    /// Prefer below, then above the picture. On a crowded screen, overlap the picture rather
    /// than putting any controls off-screen. Use the screen containing most of the reference.
    static func controlsFrame(for frame: NSRect, in screen: NSRect) -> NSRect {
        let size = NSSize(width: 360, height: 82)
        let below = frame.minY - size.height - 8
        let y = below >= screen.minY + 8 ? below : frame.maxY + 8
        return NSRect(x: min(max(frame.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8),
                      y: min(max(y, screen.minY + 8), screen.maxY - size.height - 8),
                      width: size.width, height: size.height)
    }

    private func positionControls() {
        guard let controls else { return }
        let screen = screen ?? NSScreen.active
        controls.setFrame(Self.controlsFrame(for: frame, in: screen.visibleFrame), display: true)
    }

    func windowDidMove(_ notification: Notification) { positionControls() }
    func windowDidResize(_ notification: Notification) { positionControls() }
    func windowDidChangeScreen(_ notification: Notification) { positionControls() }

    /// Both text actions share one in-flight recognition. Closing a reference must not copy
    /// text or open a translator after Vision's non-cancellable request eventually finishes.
    func recognizeText(translate: Bool) {
        guard textTask == nil else { return }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("No text found", symbol: "text.viewfinder")
            return
        }
        reference.readingText = true
        textTask = Task { [weak self] in
            do {
                let text: String
                #if DEBUG
                if let recognize = self?.debugRecognize { text = try await recognize(cg) }
                else { text = try await OCR.recognize(cg) }
                #else
                text = try await OCR.recognize(cg)
                #endif
                guard !Task.isCancelled, let self else { return }
                defer { self.reference.readingText = false; self.textTask = nil }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    Toast.show("No text found", symbol: "text.viewfinder")
                    return
                }
                if translate {
                    TranslateController.shared.show(text)
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ClipboardStore.shared.markOwnWrite()
                    Toast.show("Text copied", symbol: "text.viewfinder", detail: text.replacingOccurrences(of: "\n", with: " "))
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.reference.readingText = false
                self.textTask = nil
                Toast.show("Couldn’t recognize text", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
            }
        }
    }

    /// Back into the preview stack, as a kept card, so it can be copied, saved, edited or pinned again.
    func unpin() {
        let url = fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Self.writeTemporary(image)
        close()
        guard let url else { return }
        QuickAccess.shared.add(Capture(image: image, fileURL: url), keep: true)
    }

    /// A pin from the clipboard or the editor has no file yet; the preview card needs one to share.
    private static func writeTemporary(_ image: NSImage) -> URL? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Orbit Pin \(UUID().uuidString.prefix(6)).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    override func close() {
        textTask?.cancel()
        textTask = nil
        reference.readingText = false
        if let controls {
            removeChildWindow(controls)
            controls.close()
            self.controls = nil
        }
        super.close()
        Self.open.remove(self)
    }

    #if DEBUG
    var debugRecognize: ((CGImage) async throws -> String)?
    var debugControls: FloatingPanel? { controls }
    var debugReadingText: Bool { reference.readingText }
    var debugOpacity: CGFloat { reference.opacity }
    var debugTextTask: Task<Void, Never>? { textTask }
    #endif
}

@MainActor @Observable
private final class PinReferenceState {
    var opacity: CGFloat = 1
    var clickThrough = false
    var readingText = false
}

private struct PinControls: View {
    let state: PinReferenceState
    let opacity: (CGFloat) -> Void
    let clickThrough: (Bool) -> Void
    let copyText: () -> Void
    let translate: () -> Void
    let unpin: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { clickThrough(!state.clickThrough) } label: {
                    Label((state.clickThrough ? "Move Reference" : "Work Behind Reference").loc,
                          systemImage: state.clickThrough ? "hand.draw" : "cursorarrow.rays")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.clickThrough ? Palette.accent : Palette.ink)
                }
                .buttonStyle(.plain)
                .help("Clicks pass through the image. Use this bar to move it again.".loc)
                Spacer(minLength: 0)
                if state.readingText { ProgressView().controlSize(.mini).accessibilityLabel("Reading text".loc) }
                action("Copy Text", symbol: "text.viewfinder", run: copyText).disabled(state.readingText)
                action("Translate", symbol: "character.bubble", run: translate).disabled(state.readingText)
                action("Unpin", symbol: "pin.slash", run: unpin)
                action("Close", symbol: "xmark", run: close)
            }
            HStack(spacing: 8) {
                Text("Opacity").font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                Slider(value: Binding(get: { Double(state.opacity) }, set: { opacity(CGFloat($0)) }), in: 0.2...1)
                    .controlSize(.small).accessibilityLabel("Opacity".loc)
                Text("\(Int((state.opacity * 100).rounded()))%")
                    .font(.orbitMicro).monospacedDigit().foregroundStyle(Palette.inkSecondary).frame(width: 32, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(width: 360, height: 82)
        .modifier(PanelShell())
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title.loc).accessibilityLabel(title.loc)
    }
}

final class MovableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private struct PinView: View {
    let image: NSImage
    let close: () -> Void
    let unpin: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(hovering ? 0.8 : 0), lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: 6) {
                        Button(action: unpin) {
                            Image(systemName: "pin.slash.fill").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .orbitGlass(interactive: true, in: Circle())
                        .hoverHint("Unpin — back to the previews".loc, below: true)
                        .accessibilityLabel("Unpin".loc)
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .orbitGlass(interactive: true, in: Circle())
                        .hoverHint("Close (Esc)".loc, below: true)
                        .accessibilityLabel("Close".loc)
                    }
                    .padding(6)
                }
            }
            .onHover { h in withAnimation(Motion.hover) { hovering = h } }
            .onTapGesture(count: 2, perform: close)
            .contextMenu {
                Button("Copy") { CaptureService.shared.copy(image); Toast.show("Copied") }
                Button("Annotate") { EditorWindow.open(image: image, fileURL: nil); close() }
                Button("Unpin", action: unpin)
                Divider()
                Button("Close", action: close)
            }
    }
}
