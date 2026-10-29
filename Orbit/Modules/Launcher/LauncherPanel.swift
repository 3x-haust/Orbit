import AppKit
import SwiftUI

/// Raycast-style command palette, top-anchored on the active screen.
@MainActor
final class LauncherPanel {
    static let shared = LauncherPanel()

    private let model = LauncherModel()
    private let router = KeyRouter()
    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.setContent(LauncherView(model: model))
        p.onResignKey = { [weak self] in self?.hide() }
        model.onDismiss = { [weak self] in self?.hide() }
        return p
    }()

    var isVisible: Bool { panel.isVisible }

    /// Builds the panel and its view once, out of sight, so the first open is as quick as the rest.
    func prewarm() {
        guard !panel.isVisible else { return }
        panel.setFrame(NSRect(origin: .zero, size: Size.launcher), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        model.query = ""
        model.refresh()
        let screen = NSScreen.active.visibleFrame
        let size = Size.launcher
        // Optical center: slightly above the middle, like Spotlight.
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.62 - size.height / 2,
                           width: size.width, height: size.height)
        panel.present(at: frame)
        model.focusToken += 1
        router.install(on: panel) { [weak self] key in self?.handle(key) ?? false }
    }

    #if DEBUG
    func debugType(_ text: String) {
        if !isVisible { show() }
        model.query = text
        model.refresh()
    }
    #endif

    func hide() {
        router.remove()
        model.actionsOpen = false
        panel.dismiss()
    }

    private func handle(_ key: KeyRouter.Key) -> Bool {
        switch key {
        case .up: model.move(-1)
        case .down: model.move(1)
        case .enter(_, let command):
            if command, !model.actionsOpen { model.runSecondary() } else { model.runPrimary() }
        case .command("k"):
            model.actionsOpen.toggle()
        case .escape:
            // Escape hierarchy: action panel → query → window.
            if model.actionsOpen { model.actionsOpen = false }
            else if !model.query.isEmpty { model.query = ""; model.refresh() }
            else { hide() }
        case .command(","):
            hide()
            MainWindow.show()
        default: return false
        }
        return true
    }
}
