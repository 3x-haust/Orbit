import AppKit
import SwiftUI

/// Small glass capsule confirming an action ("Text copied"). Never takes focus.
@MainActor
enum Toast {
    private static var panel: FloatingPanel?
    private static var hideWork: DispatchWorkItem?

    static func dismiss() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    /// `level`: above the capture overlay (screen-saver level) when shown from it.
    static func show(_ message: String, symbol: String = "checkmark.circle.fill", detail: String? = nil, level: NSWindow.Level = .statusBar) {
        let panel = self.panel ?? FloatingPanel(contentRect: .zero, focusable: false)
        self.panel = panel
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.hasShadow = false

        let view = ToastView(message: message.loc, symbol: symbol, detail: detail?.loc)
        let host = NSHostingView(rootView: view.orbitTint())
        let size = host.fittingSize
        // A fixed frame; letting the hosting view also size the window loops layout until AppKit aborts.
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = FloatingPanel.container(for: host)

        let screen = NSScreen.active.visibleFrame
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 64, width: size.width, height: size.height)
        panel.present(at: frame)

        hideWork?.cancel()
        let work = DispatchWorkItem { panel.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String
    let detail: String?

    var body: some View {
        HStack(spacing: Space.compact) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 0) {
                Text(message).font(.orbitBodyEmphasized)
                if let detail {
                    Text(detail).font(.orbitCaption).foregroundStyle(.secondary)
                }
            }
            // Measured at its natural width: a flexible frame here let the window come out too
            // narrow and cut Korean words down to "복…".
            .fixedSize()
        }
        .padding(.horizontal, Space.standard)
        .padding(.vertical, Space.compact + 2)
        .glassEffect(.regular, in: Capsule())
        .padding(Space.standard)
    }
}

#if DEBUG
extension Toast {
    private static var stage: NSWindow?

    /// Debug: the real toast in one window over `backdrop` (the stage under where it shows), so its glass
    /// picks that up; `bottom` is its usual 64pt from the screen's foot. For promo frames. Returns the window number.
    static func debugStage(_ message: String, symbol: String, detail: String?, backdrop: NSImage, bottom: CGFloat) -> Int {
        let size = backdrop.size
        let view = ZStack(alignment: .bottom) {
            Image(nsImage: backdrop).resizable().frame(width: size.width, height: size.height)
            if !message.isEmpty { // empty: the backdrop alone, to measure against
                ToastView(message: message.loc, symbol: symbol, detail: detail?.loc).orbitTint()
                    .padding(.bottom, bottom)
            }
        }
        .frame(width: size.width, height: size.height)
        let window = stage ?? NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        stage = window
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.safeAreaRegions = []
        window.contentView = FloatingPanel.container(for: host)
        window.setFrame(NSRect(origin: NSScreen.main?.frame.origin ?? .zero, size: size), display: true)
        window.orderFrontRegardless()
        return window.windowNumber
    }

    static func debugUnstage() {
        stage?.orderOut(nil)
    }
}
#endif
