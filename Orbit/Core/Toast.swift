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

    static func show(_ message: String, symbol: String = "checkmark.circle.fill", detail: String? = nil) {
        let panel = self.panel ?? FloatingPanel(contentRect: .zero, focusable: false)
        self.panel = panel
        panel.level = .statusBar
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
