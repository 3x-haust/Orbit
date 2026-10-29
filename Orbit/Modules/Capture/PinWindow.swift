import AppKit
import SwiftUI

/// A screenshot floating above everything. Drag to move, scroll to change opacity,
/// pinch or drag the corner to resize, double-click or Esc to close; Unpin puts it back
/// among the capture previews.
@MainActor
final class PinWindow: NSPanel {
    private static var open: Set<PinWindow> = []

    static func pin(_ image: NSImage, fileURL: URL? = nil) {
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
        window.makeKeyAndOrderFront(nil)
    }

    private let image: NSImage
    private let fileURL: URL?

    private init(image: NSImage, fileURL: URL?, frame: NSRect) {
        self.image = image
        self.fileURL = fileURL
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = image.size
        minSize = NSSize(width: 60, height: 60)
        contentView = MovableHostingView(rootView: PinView(image: image, close: { [weak self] in self?.close() },
                                                           unpin: { [weak self] in self?.unpin() }).orbitTint())
    }

    override var canBecomeKey: Bool { true }
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
        alphaValue = min(1, max(0.2, alphaValue + event.scrollingDeltaY * 0.01))
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
        super.close()
        Self.open.remove(self)
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
