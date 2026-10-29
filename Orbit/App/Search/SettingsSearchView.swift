import AppKit
import SwiftUI

/// What the sidebar's search field is doing: the query, its results in the order shown, and the
/// keyboard (⌘F / ⌘K to focus, ↑↓ to pick, return to go, esc to clear).
@MainActor @Observable
final class SettingsSearchModel {
    var query = "" { didSet { if query != oldValue { update() } } }
    private(set) var sections: [Section] = []
    private(set) var flat: [SettingsSearch.Result] = []
    var selection = 0
    /// Bumped to put the caret in the field.
    var focusRequest = 0
    var fieldFocused = false
    /// The result last opened, still marked while you look around.
    var opened: String?

    struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let results: [SettingsSearch.Result]
    }

    var active: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var monitor: Any?
    private weak var router: AppRouter?

    private func update() {
        let results = SettingsSearch.search(query)
        // Grouped by page, pages in the order of their best result; actions get their own group.
        var order: [String] = []
        var byKey: [String: [SettingsSearch.Result]] = [:]
        for r in results {
            let key = r.entry?.page ?? "_actions"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(r)
        }
        sections = order.map { key in
            if key == "_actions" { return Section(id: key, title: "Actions".loc, symbol: "bolt", results: byKey[key]!) }
            let page = Page(rawValue: key)
            return Section(id: key, title: page?.title ?? key, symbol: page?.symbol ?? "square", results: byKey[key]!)
        }
        flat = sections.flatMap(\.results)
        selection = 0
        opened = nil
    }

    func move(_ delta: Int) {
        guard !flat.isEmpty else { return }
        selection = (selection + delta + flat.count) % flat.count
    }

    func choose(_ result: SettingsSearch.Result? = nil) {
        guard let result = result ?? (flat.indices.contains(selection) ? flat[selection] : nil), let router else { return }
        if let i = flat.firstIndex(of: result) { selection = i }
        opened = result.id
        switch result.target {
        case .action(let id):
            guard let action = OrbitAction(rawValue: id) else { return }
            MainWindow.shared.perform(action)
        case .entry:
            guard let e = result.entry, let page = Page(rawValue: e.page) else { return }
            let ids: [String] = switch e.kind {
            case .page: []
            case .group: e.anchors.map { "group:" + $0 }
            case .row: e.anchors.map { "row:" + $0 }
            }
            router.reveal(page, ids)
        }
    }

    // MARK: Keyboard

    func install(router: AppRouter) {
        self.router = router
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window?.frameAutosaveName == "OrbitMain" else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased()
        if flags == .command, key == "f" || key == "k" {
            focusRequest += 1
            return true
        }
        guard fieldFocused else { return false }
        switch Int(e.keyCode) {
        case 125: guard active else { return false }; move(1)  // ↓
        case 126: guard active else { return false }; move(-1) // ↑
        case 36, 76: guard active else { return false }; choose() // return
        case 53: // esc
            if active { query = "" } else { fieldFocused = false }
        default: return false
        }
        return true
    }
}

/// The search field at the top of the sidebar.
struct SettingsSearchField: View {
    @Bindable var model: SettingsSearchModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? Palette.ink : Palette.inkSecondary)
            TextField("Search settings", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if model.active {
                Button { model.query = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear".loc)
            } else if !focused {
                Text("⌘F").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(Palette.inkSecondary.opacity(0.8))
                    .padding(.horizontal, 5).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1))
        .animation(Motion.hover, value: focused)
        .onChange(of: model.focusRequest) { focused = true }
        .onChange(of: focused) { model.fieldFocused = focused }
        .onChange(of: model.fieldFocused) { if !model.fieldFocused { focused = false } }
    }
}

/// Results in place of the sidebar's page list.
struct SettingsSearchResults: View {
    @Bindable var model: SettingsSearchModel

    var body: some View {
        if model.flat.isEmpty {
            empty
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.sections) { section in
                            HStack(spacing: 5) {
                                Image(systemName: section.symbol).font(.system(size: 9, weight: .bold))
                                Text(section.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                            }
                            .foregroundStyle(Palette.inkSecondary.opacity(0.8))
                            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 5)
                            VStack(spacing: 2) {
                                ForEach(section.results) { row($0) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) {
                    guard model.flat.indices.contains(model.selection) else { return }
                    withAnimation(Motion.hover) { proxy.scrollTo(model.flat[model.selection].id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ r: SettingsSearch.Result) -> some View {
        let selected = model.flat.indices.contains(model.selection) && model.flat[model.selection] == r
        let opened = model.opened == r.id
        let (title, detail, symbol) = Self.describe(r)
        return Button { model.choose(r) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(opened ? Palette.accent : Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.raised))
                VStack(alignment: .leading, spacing: 1) {
                    Self.highlighted(title, query: model.query)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if case .action = r.target {
                    Image(systemName: "return").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                        .opacity(selected ? 1 : 0).padding(.top, 5)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .id(r.id)
    }

    /// Title, breadcrumb and symbol of a result.
    static func describe(_ r: SettingsSearch.Result) -> (String, String?, String) {
        switch r.target {
        case .action(let id):
            let action = OrbitAction(rawValue: id)
            return (action?.title ?? id, "Run now".loc, action?.symbol ?? "bolt")
        case .entry:
            let e = r.entry!
            let page = Page(rawValue: e.page)
            switch e.kind {
            case .page: return (page?.title ?? e.title.loc, "Open page".loc, page?.symbol ?? "square")
            case .group: return (e.title.loc, "Section".loc, "square.stack")
            case .row:
                let title = (e.anchors.first ?? e.title).loc
                return (title, e.group.isEmpty ? nil : e.group.loc, e.symbol.isEmpty ? (page?.symbol ?? "slider.horizontal.3") : e.symbol)
            }
        }
    }

    /// The title with the matched letters in the accent colour.
    static func highlighted(_ s: String, query: String) -> Text {
        let marks = SettingsSearch.marks(query, in: s)
        var text = Text("")
        var run = "", runMarked = false
        func flush() {
            guard !run.isEmpty else { return }
            let t = Text(verbatim: run)
            text = text + (runMarked ? t.foregroundColor(Palette.accent).bold() : t.foregroundColor(Palette.ink))
            run = ""
        }
        for (i, ch) in s.enumerated() {
            let m = marks.contains(i)
            if m != runMarked { flush(); runMarked = m }
            run.append(ch)
        }
        flush()
        return text
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No results for “%@”".loc(model.query))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Try another word — Korean, English, initials (ㅈㅈㄱ) or another app’s name all work.")
                .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Shortcuts", "Dark Mode", "Charge limit", "Split windows", "Keep awake"], id: \.self) { s in
                    Button { model.query = s.loc } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold))
                            Text(s.loc).font(.system(size: 12))
                        }
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(Capsule().fill(Palette.surface))
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
