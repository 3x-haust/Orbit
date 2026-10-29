import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class ClipboardViewModel {
    enum Filter: Hashable { case all, pinned, kind(ClipItem.Kind) }

    var query = "" { didSet { selection = 0 } }
    var filter: Filter = .all { didSet { selection = 0 } }
    var selection = 0
    var focusToken = 0

    var results: [ClipItem] {
        let store = ClipboardStore.shared
        switch filter {
        case .all: return store.search(query)
        case .pinned: return store.search(query, pinnedOnly: true)
        case .kind(let k): return store.search(query, kind: k)
        }
    }

    var selected: ClipItem? {
        let r = results
        return r.indices.contains(selection) ? r[selection] : nil
    }

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selection = min(max(0, selection + delta), count - 1)
    }

    func cycleFilter(backward: Bool = false) {
        let all: [Filter] = [.all, .pinned] + ClipItem.Kind.allCases.map { .kind($0) }
        let i = all.firstIndex(of: filter) ?? 0
        filter = all[(i + (backward ? all.count - 1 : 1)) % all.count]
    }
}

/// Paste-style shelf that slides up from the bottom of the active screen.
@MainActor
final class ClipboardPanel {
    static let shared = ClipboardPanel()

    private let model = ClipboardViewModel()
    private let router = KeyRouter()
    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.setContent(ClipboardView(model: model, onPaste: { [weak self] item, plain in self?.paste(item, plain: plain) }))
        p.onResignKey = { [weak self] in self?.hide() }
        return p
    }()

    var isVisible: Bool { panel.isVisible }

    /// Builds the panel and its view once, out of sight, so the first open is as quick as the rest.
    func prewarm() {
        guard !panel.isVisible else { return }
        panel.setFrame(NSRect(origin: .zero, size: NSSize(width: NSScreen.active.visibleFrame.width - Space.group * 2, height: Size.shelfHeight)), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    func toggle() { isVisible ? hide() : show() }

    /// The app to paste into: whoever was in front when the panel opened.
    private var target: NSRunningApplication?

    func show() {
        Paster.start()
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? Paster.lastExternal : front
        model.query = ""
        model.filter = .all
        model.selection = 0
        let screen = NSScreen.active.visibleFrame
        let frame = NSRect(x: screen.minX + Space.group, y: screen.minY + Space.standard,
                           width: screen.width - Space.group * 2, height: Size.shelfHeight)
        panel.present(at: frame)
        model.focusToken += 1
        router.install(on: panel) { [weak self] key in self?.handle(key) ?? false }
    }

    func hide() {
        router.remove()
        panel.dismiss()
    }

    private func handle(_ key: KeyRouter.Key) -> Bool {
        switch key {
        case .left: model.move(-1)
        case .right: model.move(1)
        case .tab(let shift): model.move(shift ? -1 : 1)
        case .down: model.cycleFilter()
        case .up: model.cycleFilter(backward: true)
        case .escape:
            if !model.query.isEmpty { model.query = "" } else { hide() }
        case .enter(let shift, let command):
            guard let item = model.selected else { return true }
            if command { ClipboardStore.shared.copy(item, plain: shift); hide(); Toast.show("Copied") }
            else { paste(item, plain: shift) }
        case .commandDigit(let d):
            let r = model.results
            if r.indices.contains(d - 1) { paste(r[d - 1], plain: false) }
        case .command("c"):
            guard let item = model.selected else { return false }
            ClipboardStore.shared.copy(item)
            hide()
            Toast.show("Copied")
        case .command("p"):
            if let item = model.selected { ClipboardStore.shared.togglePin(item) }
        case .commandDelete:
            if let item = model.selected { ClipboardStore.shared.delete(item); model.move(0) }
        case .command(","):
            hide()
            MainWindow.show(.clipboard)
        default: return false
        }
        return true
    }

    func paste(_ item: ClipItem, plain: Bool) {
        ClipboardStore.shared.copy(item, plain: plain)
        guard Pref.defaults.bool(forKey: Pref.pasteDirectly) else { hide(); Toast.show("Copied"); return }
        // From the launcher the panel isn't open; then it's the app the user was last in.
        let into = panel.isVisible ? target : nil
        // Straight out, no fade: the panel must let go of the keyboard before ⌘V is sent.
        router.remove()
        panel.orderOut(nil)
        Paster.paste(into: into)
    }
}
