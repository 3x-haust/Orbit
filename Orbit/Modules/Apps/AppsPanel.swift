import AppKit
import SwiftUI

/// The Apps grid: every app on the Mac over a blurred desktop, like macOS's Apps view — but it
/// searches in Korean and English (and by initials, ㅋㅋㅇㅌ), sorts by category, and remembers what
/// you use and what you pinned.
@MainActor
final class AppsPanel {
    static let shared = AppsPanel()

    let model = AppsModel()
    private let router = KeyRouter()
    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        // Over the menu bar and the Dock, the way Launchpad was.
        p.level = .statusBar
        p.hasShadow = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.setContent(AppsView(model: model))
        p.onResignKey = { [weak self] in self?.hide() }
        return p
    }()

    var isVisible: Bool { panel.isVisible && !closing }
    private var closing = false

    /// Builds the panel and its view once, out of sight, so the first open is as quick as the rest.
    func prewarm() {
        guard !panel.isVisible else { return }
        panel.setFrame(NSRect(origin: .zero, size: NSScreen.active.frame.size), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        AppsCatalog.shared.start() // keeps what's running current from launch and quit notices
        model.reset()
        closing = false
        panel.setFrame(NSScreen.active.frame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.08 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().alphaValue = 1
        }
        // Next runloop, so the cascade animates from the hidden state.
        DispatchQueue.main.async { [model] in
            withAnimation(reduce ? .easeOut(duration: 0.1) : .spring(duration: 0.42, bounce: 0.16)) { model.shown = true }
            model.focusToken += 1
        }
        router.install(on: panel) { [weak self] key in self?.handle(key) ?? false }
    }

    func hide(completion: (() -> Void)? = nil) {
        guard panel.isVisible, !closing else { completion?(); return }
        closing = true
        router.remove()
        withAnimation(.easeIn(duration: 0.14)) { model.shown = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.closing = false
                completion?()
            }
        })
    }

    private func handle(_ key: KeyRouter.Key) -> Bool {
        switch key {
        case .up: model.move(dx: 0, dy: -1)
        case .down: model.move(dx: 0, dy: 1)
        case .left: model.move(dx: -1, dy: 0)
        case .right: model.move(dx: 1, dy: 0)
        case .enter(_, let command):
            guard let app = model.selectedApp ?? model.firstApp else { return true }
            command ? reveal(app) : open(app)
        case .tab(let shift): model.cycleCategory(backward: shift)
        case .escape:
            // Escape hierarchy: info card → query → category → window.
            if model.info != nil { withAnimation(.spring(duration: 0.25)) { model.info = nil } }
            else if !model.query.isEmpty { model.query = "" }
            else if model.category != nil { withAnimation(.spring(duration: 0.3)) { model.category = nil } }
            else { hide() }
        case .command("p"):
            if let app = model.selectedApp { withAnimation(.spring(duration: 0.3)) { AppsCatalog.shared.togglePin(app) } }
        case .command("i"):
            if let app = model.selectedApp { withAnimation(.spring(duration: 0.25)) { model.info = app } }
        case .command(","):
            hide()
            MainWindow.show(.apps)
        default: return false
        }
        return true
    }

    // MARK: Actions

    func open(_ app: AppsCatalog.App) {
        AppsCatalog.shared.noteUse(app.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if error != nil {
                DispatchQueue.main.async { Toast.show("Couldn’t open %@".loc(app.name), symbol: "exclamationmark.triangle.fill") }
            }
        }
        hide()
    }

    func reveal(_ app: AppsCatalog.App) {
        hide { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
    }

    func uninstall(_ app: AppsCatalog.App) {
        hide { AppUninstaller.shared.present(app: app.url) }
    }
}

/// What the grid is showing and where the keyboard selection is.
@MainActor @Observable
final class AppsModel {
    struct Selection: Hashable {
        let section: String
        let path: String
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let apps: [AppsCatalog.App]
        var pinned: Bool { id == "pinned" }
    }

    var query = "" { didSet { if query != oldValue { selection = nil; if !query.isEmpty { selectFirst() } } } }
    var category: AppsCatalog.Category? { didSet { selection = nil } }
    var selection: Selection?
    var info: AppsCatalog.App?
    var shown = false
    var focusToken = 0
    var columns = 7

    private var catalog: AppsCatalog { .shared }

    /// Only what changed: every assignment, even of the same value, re-lays out the grid.
    func reset() {
        if !query.isEmpty { query = "" }
        if category != nil { category = nil }
        if selection != nil { selection = nil }
        if info != nil { info = nil }
        if shown { shown = false }
    }

    var sections: [Section] {
        if !query.isEmpty { return [Section(id: "results", title: nil, apps: catalog.search(query, in: category))] }
        if let category { return [Section(id: "category", title: nil, apps: catalog.search("", in: category))] }
        var s: [Section] = []
        let pinned = catalog.pinnedApps
        if !pinned.isEmpty { s.append(Section(id: "pinned", title: "Pinned", apps: pinned)) }
        if catalog.showFrequent {
            let frequent = catalog.frequent(limit: columns)
            if frequent.count >= 3 { s.append(Section(id: "frequent", title: "Frequently Used", apps: frequent)) }
        }
        s.append(Section(id: "all", title: s.isEmpty ? nil : "All Apps", apps: catalog.apps))
        return s
    }

    /// Categories that actually have apps, always in the same order (sorting by size reshuffled the
    /// chips whenever two were tied or an app came or went); "Other" last.
    var categories: [AppsCatalog.Category] {
        let present = Set(catalog.apps.map(\.category))
        return Self.chipOrder.filter(present.contains)
    }

    private static let chipOrder: [AppsCatalog.Category] = [.utilities, .productivity, .developer, .creativity, .social,
                                                            .entertainment, .lifestyle, .games, .education, .business, .other]

    var selectedApp: AppsCatalog.App? {
        guard let selection else { return nil }
        return sections.first { $0.id == selection.section }?.apps.first { $0.path == selection.path }
    }

    var firstApp: AppsCatalog.App? { sections.first?.apps.first }

    private func selectFirst() {
        if let s = sections.first, let a = s.apps.first { selection = Selection(section: s.id, path: a.path) }
    }

    /// Rows as they're laid out: each section starts on a fresh row.
    private var rows: [[Selection]] {
        sections.flatMap { s in
            stride(from: 0, to: s.apps.count, by: max(1, columns)).map { i in
                s.apps[i..<min(i + columns, s.apps.count)].map { Selection(section: s.id, path: $0.path) }
            }
        }
    }

    func move(dx: Int, dy: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        guard let selection, let r = rows.firstIndex(where: { $0.contains(selection) }),
              let c = rows[r].firstIndex(of: selection) else {
            self.selection = rows[0][0]
            return
        }
        if dy != 0 {
            let nr = min(max(0, r + dy), rows.count - 1)
            self.selection = rows[nr][min(c, rows[nr].count - 1)]
        } else {
            let flat = rows.flatMap { $0 }
            let i = flat.firstIndex(of: selection) ?? 0
            self.selection = flat[min(max(0, i + dx), flat.count - 1)]
        }
    }

    func cycleCategory(backward: Bool) {
        let all: [AppsCatalog.Category?] = [nil] + categories.map { $0 }
        let i = all.firstIndex(of: category) ?? 0
        withAnimation(.spring(duration: 0.3)) { category = all[(i + (backward ? all.count - 1 : 1)) % all.count] }
    }
}
