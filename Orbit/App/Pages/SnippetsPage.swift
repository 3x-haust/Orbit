import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class SnippetsPageModel {
    static let shared = SnippetsPageModel()
    var selection: UUID?
    var query = ""
    var folder: String?
}

struct SnippetsPage: View {
    @Bindable private var store = SnippetStore.shared
    @Bindable private var page = SnippetsPageModel.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Snippets", subtitle: "Type a short keyword anywhere and it turns into the text you saved.") {
                HStack(spacing: Space.related) {
                    Button { SnippetPanel.shared.show() } label: { Label("Search Snippets", systemImage: "magnifyingglass") }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    Toggle("", isOn: $store.enabled.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
                }
            }

            if store.enabled, !trusted {
                HStack(spacing: Space.related) {
                    Image(systemName: "hand.raised.fill").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Accessibility to expand keywords").font(.orbitBodyEmphasized)
                        Text("Orbit watches for your keywords and types the snippet in their place.").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    Button("Open Permissions") { MainWindow.show(.setup) }.buttonStyle(PillButtonStyle(prominent: false))
                }
                .padding(Space.standard)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            }

            HStack(alignment: .top, spacing: 0) {
                SnippetList(store: store, page: page)
                    .frame(width: 250)
                Rectangle().fill(Palette.hairline).frame(width: 1)
                if let id = page.selection, store.snippet(id: id) != nil {
                    SnippetEditor(id: id, store: store).id(id)
                } else {
                    VStack(spacing: Space.compact) {
                        Image(systemName: "text.badge.plus").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                        Text("Pick a snippet, or make a new one.").font(.orbitBody).foregroundStyle(Palette.inkSecondary)
                        Button("New Snippet") { newSnippet() }.buttonStyle(PillButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 470)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(store.enabled ? 1 : 0.6)

            SettingsGroup(title: "Expansion", footer: "In 한글 mode, keywords ending in a letter expand when you press space — the syllable has to finish first.") {
                SettingsRow(title: "Expand", subtitle: "Right away, or once you press space after the keyword.", symbol: "bolt") {
                    ChipPicker(selection: $store.trigger, options: [(.immediate, "As I type"), (.delimiter, "After space")])
                }
                RowDivider()
                SettingsRow(title: "In terminals", subtitle: "Terminal, iTerm, Warp, Ghostty and kitty.", symbol: "terminal") {
                    Toggle("", isOn: $store.inTerminals).toggleStyle(.switch).labelsHidden()
                }
            }

            ExcludedApps(store: store)

            SettingsGroup(title: "Placeholders", footer: "Put these anywhere in a snippet.") {
                ForEach(Array(Self.placeholders.enumerated()), id: \.offset) { i, p in
                    if i > 0 { RowDivider() }
                    SettingsRow(title: p.1) {
                        Text(p.0).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Palette.accent)
                            .textSelection(.enabled)
                    }
                }
            }

            SettingsGroup(title: "Import & Export") {
                SettingsRow(title: "Import snippets", subtitle: "From Raycast or Alfred (JSON), or TextExpander (CSV).", symbol: "square.and.arrow.down") {
                    Button("Choose…") { importSnippets() }.buttonStyle(PillButtonStyle(prominent: false))
                }
                RowDivider()
                SettingsRow(title: "Export snippets", subtitle: "A JSON file Raycast can read too.", symbol: "square.and.arrow.up") {
                    Button("Export…") { exportSnippets() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .onAppear {
            trusted = AXIsProcessTrusted()
            if page.selection == nil { page.selection = store.snippets.first?.id }
        }
        .onChange(of: store.snippets.count) { SnippetEngine.shared.start() }
    }

    static let placeholders: [(String, String)] = [
        ("{cursor}", "Where the caret ends up"),
        ("{clipboard}", "What’s on the clipboard"),
        ("{date}", "Today’s date"),
        ("{time}", "The time now"),
        ("{date:yyyy-MM-dd}", "A date in your own format"),
        ("{input:Name}", "Asks for it when the snippet goes in"),
        ("{snippet:;sig}", "Another snippet, by keyword or name"),
        ("{uuid}", "A fresh unique ID"),
    ]

    private func newSnippet() {
        let s = store.add(Snippet(name: "", keyword: "", content: "", folder: page.folder ?? ""))
        page.selection = s.id
    }

    private func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let n = store.importFile(url)
        Toast.show(n > 0 ? "Imported %ld snippets".loc(n) : "Nothing new to import", symbol: "square.and.arrow.down")
    }

    private func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Orbit Snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.exportJSON(to: url)
        Toast.show("Exported", symbol: "square.and.arrow.up")
    }
}

private struct SnippetList: View {
    let store: SnippetStore
    @Bindable var page: SnippetsPageModel

    var body: some View {
        let shown = store.search(page.query).filter { page.folder == nil || $0.folder == page.folder }
        VStack(spacing: 0) {
            HStack(spacing: Space.compact) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                TextField("Search", text: $page.query).textFieldStyle(.plain).font(.orbitBody)
                Button {
                    let s = store.add(Snippet(name: "", keyword: "", content: "", folder: page.folder ?? ""))
                    page.query = ""
                    page.selection = s.id
                } label: { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .hoverHint("New Snippet".loc)
            }
            .padding(.horizontal, Space.related).frame(height: 40)

            if !store.folders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.tight + 2) {
                        Chip(title: "All", isOn: page.folder == nil) { page.folder = nil }
                        ForEach(store.folders, id: \.self) { f in
                            Chip(title: f, isOn: page.folder == f) { page.folder = page.folder == f ? nil : f }
                        }
                    }
                    .padding(.horizontal, Space.related)
                }
                .padding(.bottom, Space.compact)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { s in
                        let on = page.selection == s.id
                        HStack(spacing: Space.compact) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name.isEmpty ? "Untitled".loc : s.name).font(.orbitBodyEmphasized).lineLimit(1)
                                Text(s.content.isEmpty ? " " : s.content.replacingOccurrences(of: "\n", with: " "))
                                    .font(.orbitCaption).lineLimit(1)
                                    .foregroundStyle(on ? Palette.canvas.opacity(0.7) : Palette.inkSecondary)
                            }
                            Spacer(minLength: 4)
                            if !s.keyword.isEmpty {
                                Text(s.keyword).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                                    .padding(.horizontal, 6).frame(height: 20)
                                    .background(Capsule().fill(on ? Palette.canvas.opacity(0.18) : Palette.raised))
                            }
                        }
                        .foregroundStyle(on ? Palette.canvas : Palette.ink)
                        .opacity(s.enabled ? 1 : 0.5)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(on ? Palette.ink : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Motion.hover) { page.selection = s.id } }
                        .contextMenu {
                            Button(s.enabled ? "Turn Off" : "Turn On") { var c = s; c.enabled.toggle(); store.update(c) }
                            Button("Duplicate") {
                                var c = s; c.id = UUID(); c.keyword = ""; c.name = s.name + " " + "copy".loc
                                page.selection = store.add(c).id
                            }
                            Divider()
                            Button("Delete", role: .destructive) { delete(s) }
                        }
                    }
                    if shown.isEmpty {
                        Text(page.query.isEmpty ? "No snippets here." : "No matches.").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                            .padding(.top, Space.group)
                    }
                }
                .padding(Space.compact)
            }
        }
    }

    private func delete(_ s: Snippet) {
        if page.selection == s.id { page.selection = nil }
        store.delete(s.id)
    }
}

private struct SnippetEditor: View {
    let id: UUID
    let store: SnippetStore
    @State private var draft = Snippet(name: "", keyword: "", content: "")
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.related) {
                field("Name", text: $draft.name, prompt: "Address")
                field("Keyword", text: $draft.keyword, prompt: ";addr", mono: true).frame(width: 150)
            }
            if let other = store.clash(for: draft) {
                Label(other.keyword == draft.keyword ? "“%@” uses this keyword too.".loc(other.name.isEmpty ? other.keyword : other.name)
                      : "Clashes with “%@” — the shorter keyword expands first.".loc(other.keyword), systemImage: "exclamationmark.triangle.fill")
                    .font(.orbitCaption).foregroundStyle(Palette.accent)
            } else if !draft.keyword.isEmpty, let first = draft.keyword.first, first.isLetter {
                Label("Tip: start keywords with ; or ! so ordinary words never expand.", systemImage: "lightbulb")
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Snippet").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Menu {
                        ForEach(SnippetsPage.placeholders, id: \.0) { p in
                            Button(p.1.loc + "  " + p.0) { draft.content += p.0 }
                        }
                    } label: { Label("Insert placeholder", systemImage: "curlybraces").font(.orbitCaption) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                TextEditor(text: $draft.content)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
                    .frame(maxHeight: .infinity)
            }

            if draft.content.contains("{") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    Text(preview).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                }
            }

            HStack(spacing: Space.related) {
                field("Folder", text: $draft.folder, prompt: "Work").frame(width: 150)
                Toggle("On", isOn: $draft.enabled).toggleStyle(.switch).controlSize(.small)
                Spacer()
                if draft.used > 0 {
                    Text("Used %ld times".loc(draft.used)).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
                Button {
                    SnippetsPageModel.shared.selection = nil
                    store.delete(id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary)
                    .hoverHint("Delete".loc, below: false)
            }
        }
        .padding(Space.standard)
        .onAppear {
            if let s = store.snippet(id: id) { draft = s }
            loaded = true
        }
        .onChange(of: draft) { _, new in if loaded { store.update(new) } }
    }

    private var preview: String {
        var ctx = SnippetTemplate.Context()
        ctx.clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        ctx.lookup = { store.content(named: $0) }
        ctx.inputs = Dictionary(uniqueKeysWithValues: SnippetTemplate.inputs(in: draft.content, lookup: ctx.lookup).map { ($0, "‹\($0)›") })
        let r = SnippetTemplate.render(draft.content, ctx)
        guard r.cursorFromEnd > 0 else { return r.text }
        var t = r.text
        t.insert("|", at: t.index(t.endIndex, offsetBy: -r.cursorFromEnd))
        return t
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            TextField("", text: text, prompt: Text(prompt.loc))
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 13, design: .monospaced) : .orbitBody)
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
        }
    }
}

private struct ExcludedApps: View {
    @Bindable var store: SnippetStore

    var body: some View {
        SettingsGroup(title: "Never expand in", footer: "Password managers are left out from the start.") {
            ForEach(store.excludedApps, id: \.self) { id in
                SettingsRow(title: name(id), subtitle: id, icon: icon(id)) {
                    Button { withAnimation(.spring(duration: 0.3)) { store.excludedApps.removeAll { $0 == id } } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary)
                }
                RowDivider()
            }
            SettingsRow(title: "Add app…", symbol: "plus") {
                Button("Choose") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !store.excludedApps.contains(id) {
                        withAnimation(.spring(duration: 0.3)) { store.excludedApps.append(id) }
                    }
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    private func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    private func name(_ id: String) -> String { url(id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id }
    private func icon(_ id: String) -> NSImage? { url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } }
}
