import AppKit
import SwiftUI
import Observation

// MARK: - {input:…} prompt

/// A small card that asks for a snippet's `{input:…}` fields before it goes in.
@MainActor
enum SnippetInputPrompt {
    private static var panel: FloatingPanel?
    private static var pending: CheckedContinuation<[String: String]?, Never>?

    static func ask(title: String, fields: [String]) async -> [String: String]? {
        finish(nil) // one at a time
        return await withCheckedContinuation { c in
            pending = c
            let p = panel ?? FloatingPanel(contentRect: .zero)
            panel = p
            p.onResignKey = { finish(nil) }
            p.onEscape = { finish(nil); return true }
            p.setContent(InputPromptView(title: title, fields: fields, onDone: { finish($0) }))
            let size = CGSize(width: 360, height: CGFloat(118 + fields.count * 54))
            let screen = NSScreen.active.visibleFrame
            p.present(at: NSRect(x: screen.midX - size.width / 2, y: screen.midY + screen.height * 0.12, width: size.width, height: size.height))
        }
    }

    private static func finish(_ values: [String: String]?) {
        guard let c = pending else { return }
        pending = nil
        panel?.onResignKey = nil
        panel?.orderOut(nil)
        c.resume(returning: values)
    }
}

private struct InputPromptView: View {
    let title: String
    let fields: [String]
    let onDone: ([String: String]?) -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.compact) {
                Image(systemName: "text.badge.plus").foregroundStyle(Palette.accent)
                Text(title).font(.orbitSection).lineLimit(1)
            }
            ForEach(fields, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    TextField("", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .textFieldStyle(.plain)
                        .font(.orbitBody)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                        .focused($focused, equals: name)
                        .onSubmit { advance(from: name) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Insert") { onDone(values) }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(Space.standard + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelShell()
        .onAppear { focused = fields.first }
    }

    /// ↩ moves to the next field; on the last one it inserts.
    private func advance(from name: String) {
        if let i = fields.firstIndex(of: name), i + 1 < fields.count { focused = fields[i + 1] } else { onDone(values) }
    }
}

// MARK: - Picker

@MainActor @Observable
final class SnippetPickerModel {
    var query = "" { didSet { selection = 0 } }
    var selection = 0
    var focusToken = 0

    var results: [Snippet] { SnippetStore.shared.search(query) }
    var selected: Snippet? { let r = results; return r.indices.contains(selection) ? r[selection] : nil }

    func move(_ d: Int) {
        let n = results.count
        guard n > 0 else { return }
        selection = min(max(0, selection + d), n - 1)
    }
}

/// Search every snippet and drop one in where you're typing — for the ones without a keyword, or
/// when you've forgotten it.
@MainActor
final class SnippetPanel {
    static let shared = SnippetPanel()

    private let model = SnippetPickerModel()
    private let router = KeyRouter()
    private var target: NSRunningApplication?
    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.setContent(SnippetPickerView(model: model, onPick: { [weak self] in self?.pick($0) }))
        p.onResignKey = { [weak self] in self?.hide() }
        return p
    }()

    var isVisible: Bool { panel.isVisible }
    func toggle() { isVisible ? hide() : show() }

    func show() {
        Paster.start()
        let front = NSWorkspace.shared.frontmostApplication
        target = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? Paster.lastExternal : front
        model.query = ""
        model.selection = 0
        let screen = NSScreen.active.visibleFrame
        let size = CGSize(width: 640, height: 400)
        panel.present(at: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.08,
                                 width: size.width, height: size.height))
        model.focusToken += 1
        router.install(on: panel) { [weak self] key in self?.handle(key) ?? false }
    }

    func hide() {
        router.remove()
        panel.dismiss()
    }

    private func handle(_ key: KeyRouter.Key) -> Bool {
        switch key {
        case .up: model.move(-1)
        case .down: model.move(1)
        case .tab(let shift): model.move(shift ? -1 : 1)
        case .escape:
            if !model.query.isEmpty { model.query = "" } else { hide() }
        case .enter(_, let command):
            guard let s = model.selected else { return true }
            if command { copy(s) } else { pick(s) }
        case .command("c"):
            guard let s = model.selected else { return false }
            copy(s)
        case .command("n"), .command(","):
            hide()
            MainWindow.show(.snippets)
        default: return false
        }
        return true
    }

    private func pick(_ s: Snippet) {
        router.remove()
        panel.orderOut(nil)
        let app = target
        Task { await SnippetEngine.shared.insert(s, into: app) }
    }

    private func copy(_ s: Snippet) {
        var ctx = SnippetTemplate.Context()
        ctx.clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        ctx.lookup = { SnippetStore.shared.content(named: $0) }
        let text = SnippetTemplate.render(s.content, ctx).text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hide()
        Toast.show("Copied")
    }
}

private struct SnippetPickerView: View {
    @Bindable var model: SnippetPickerModel
    let onPick: (Snippet) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            HStack(spacing: Space.compact) {
                Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
                TextField("Search snippets", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.orbitSearch)
                    .focused($searchFocused)
            }
            .padding(.horizontal, Space.standard)
            .frame(height: 52)
            Divider().opacity(0.5)
            if results.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    list(results).frame(width: 250)
                    Divider().opacity(0.5)
                    preview(model.selected)
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: Space.standard) {
                Spacer()
                ShortcutHint(title: "Insert", keys: ["↩"], emphasized: true)
                ShortcutHint(title: "Copy", keys: ["⌘", "↩"])
                ShortcutHint(title: "New", keys: ["⌘", "N"])
            }
            .padding(.horizontal, Space.standard)
            .frame(height: Size.footer)
        }
        .panelShell()
        .onChange(of: model.focusToken) { searchFocused = true }
        .onAppear { searchFocused = true }
    }

    private func list(_ results: [Snippet]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: Space.compact) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name.isEmpty ? "Untitled".loc : s.name).font(.orbitBodyEmphasized).lineLimit(1)
                                Text(s.content.replacingOccurrences(of: "\n", with: " ")).font(.orbitCaption)
                                    .foregroundStyle(i == model.selection ? Palette.canvas.opacity(0.7) : Palette.inkSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if !s.keyword.isEmpty {
                                Text(s.keyword).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 6).frame(height: 20)
                                    .background(Capsule().fill(i == model.selection ? Palette.canvas.opacity(0.18) : Palette.raised))
                            }
                        }
                        .foregroundStyle(i == model.selection ? Palette.canvas : Palette.ink)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(i == model.selection ? Palette.ink : .clear))
                        .contentShape(Rectangle())
                        .id(s.id)
                        .onTapGesture { model.selection = i; onPick(s) }
                    }
                }
                .padding(Space.compact)
            }
            .onChange(of: model.selection) { _, new in
                if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
            }
        }
    }

    @ViewBuilder private func preview(_ s: Snippet?) -> some View {
        ScrollView {
            if let s {
                Text(SnippetHighlight.attributed(s.content))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Space.standard)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: Space.compact) {
            Image(systemName: "text.badge.plus").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "No snippets yet".loc : "No matches for “%@”".loc(model.query)).font(.orbitSection)
            Text("Press ⌘N to make one.").font(.orbitCaption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Placeholders in a snippet shown as tinted tokens.
enum SnippetHighlight {
    static func attributed(_ content: String) -> AttributedString {
        var out = AttributedString()
        var rest = content[...]
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += AttributedString(String(rest[..<open]))
            var token = AttributedString(String(rest[open...close]))
            token.foregroundColor = Palette.accent
            token.font = .system(size: 12, weight: .semibold, design: .monospaced)
            out += token
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

// MARK: - Launcher

extension SnippetStore {
    /// Snippets for the launcher: only clear hits on a name or keyword.
    func launcherItems(for query: String) -> [LauncherItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count > 1 else { return [] }
        return snippets.compactMap { s -> (Snippet, Int)? in
            let score = max(Fuzzy.score(q, s.name) ?? 0, Fuzzy.score(q, s.keyword) ?? 0)
            return score >= Fuzzy.substring - 100 ? (s, score) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(3)
        .map { s, _ in
            LauncherItem(id: "snippet.\(s.id)", title: s.name.isEmpty ? s.keyword : s.name,
                         subtitle: s.content.replacingOccurrences(of: "\n", with: " "),
                         icon: .symbol("text.badge.plus", Tint.clipboard), accessory: s.keyword.isEmpty ? nil : s.keyword,
                         section: "Snippets", actions: [
                LauncherAction(title: "Insert Snippet", symbol: "text.insert") {
                    let app = Paster.lastExternal
                    Task { await SnippetEngine.shared.insert(s, into: app) }
                },
                LauncherAction(title: "Edit Snippet", symbol: "pencil", shortcut: ["⌘", "↩"]) {
                    SnippetsPageModel.shared.selection = s.id
                    MainWindow.show(.snippets)
                },
            ])
        }
    }
}
