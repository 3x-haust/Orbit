import AppKit
import SwiftUI

// MARK: - Spelling

struct SpellPage: View {
    @AppStorage(Pref.spellEnabled) private var enabled = true
    /// Empty: Apple Intelligence when it's available.
    @AppStorage(Pref.spellEngine) private var engine = ""
    /// Empty: Daum once the web checkers are allowed, until then as above.
    @AppStorage(Pref.spellKoreanEngine) private var koreanEngine = ""
    @AppStorage(Pref.spellWebConsent) private var webAllowed = false
    @AppStorage(Pref.spellCombine) private var combine = false
    @State private var asking: SpellEngine?
    @AppStorage(Pref.spellTripleCopy) private var tripleCopy = false
    @AppStorage(Pref.spellCloseAfterReplace) private var closeAfterReplace = true
    @AppStorage(Pref.translateDoubleCopy) private var doubleCopy = true
    @State private var ignored = SpellController.ignored
    @State private var newWord = ""
    @State private var ltUser = SpellController.languageToolAccount.user
    @State private var ltKey = SpellController.languageToolAccount.key
    @State private var sample = "안녕 하세요. 어제 친구랑 영화를 봤는데 너무 재밌었어요. 몇일 뒤에 또 보기로 했서요."

    private var current: SpellEngine { SpellController.pickedEngine }
    private var currentKorean: SpellEngine { SpellController.koreanEngine }
    /// Changes when anything that decides the check does, so the preview checks again.
    private var setupKey: String { "\(engine)|\(koreanEngine)|\(webAllowed)|\(combine)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Spelling", subtitle: "Select text anywhere and press the shortcut to fix spelling, spacing and grammar in place.")

            SpellPreview(sample: $sample, setupKey: setupKey, ignored: ignored)

            SettingsGroup {
                SettingsRow(title: "Spell check", subtitle: "The shortcut, the Ring and the launcher check the selected text.",
                            symbol: "textformat.abc.dottedunderline") {
                    Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                        .onChange(of: enabled) { TranslateController.shared.start() }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Korean")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(SpellEngine.korean) { e in
                        SpellEngineCard(engine: e, selected: currentKorean == e && !(combine && e.isWeb && webAllowed),
                                        combined: combine && e.isWeb && webAllowed) {
                            if e.isWeb, !webAllowed { asking = e; return }
                            withAnimation(.spring(duration: 0.3)) { koreanEngine = e.rawValue }
                        }
                    }
                }
                if webAllowed {
                    SettingsGroup(footer: "If a checker doesn’t answer within 4 seconds, the next one checks: Daum → Naver → Apple Intelligence → Apple Spelling.") {
                        SettingsRow(title: "Combine Daum and Naver", subtitle: "Both check at once. Where they disagree, you pick.", symbol: "square.on.square") {
                            Toggle("", isOn: $combine).toggleStyle(.switch).labelsHidden()
                        }
                        RowDivider()
                        SettingsRow(title: "Korean web spell checkers", subtitle: "Unofficial. Off: Korean is checked on this Mac only.", symbol: "network") {
                            Toggle("", isOn: Binding(get: { webAllowed }, set: { on in
                                withAnimation(.spring(duration: 0.3)) {
                                    webAllowed = on
                                    if !on, SpellEngine(rawValue: koreanEngine)?.isWeb == true { koreanEngine = "" }
                                }
                            })).toggleStyle(.switch).labelsHidden()
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Other languages")
                HStack(spacing: 12) {
                    ForEach(SpellEngine.others) { e in
                        SpellEngineCard(engine: e, selected: current == e) {
                            withAnimation(.spring(duration: 0.3)) { engine = e.rawValue }
                        }
                    }
                }
                if current == .languageTool {
                    SettingsGroup(footer: "Leave empty for the free plan. With LanguageTool Premium, add your account email and API key; they stay in your keychain.") {
                        SettingsRow(title: "LanguageTool username", symbol: "person") {
                            TextField("you@example.com", text: $ltUser)
                                .textFieldStyle(.roundedBorder).frame(width: 240)
                                .onChange(of: ltUser) { saveAccount() }
                        }
                        RowDivider()
                        SettingsRow(title: "LanguageTool API key", symbol: "key") {
                            SecureField("API key", text: $ltKey)
                                .textFieldStyle(.roundedBorder).frame(width: 240)
                                .onChange(of: ltKey) { saveAccount() }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            SettingsGroup(title: "Trigger") {
                SettingsRow(title: "Shortcut", subtitle: "Checks the text selected in any app.", symbol: "keyboard") {
                    ShortcutRecorder(name: .spellCheck)
                }
                RowDivider()
                SettingsRow(title: "⌘C three times", subtitle: doubleCopy
                            ? "⌘C twice still translates; a third press checks spelling instead."
                            : "Checks whatever you just copied.", symbol: "command") {
                    Toggle("", isOn: $tripleCopy).toggleStyle(.switch).labelsHidden()
                        .onChange(of: tripleCopy) { TranslateController.shared.start() }
                }
            }

            SettingsGroup(title: "After replacing") {
                SettingsRow(title: "Close the card after Replace", subtitle: "Off: the card stays up and checks the new text again.", symbol: "xmark.circle") {
                    Toggle("", isOn: $closeAfterReplace).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: "Ignored words", footer: "Names, product words and slang spell check should never change.") {
                SettingsRow(title: "Never flag", symbol: "nosign") {
                    TextField("Add a word", text: $newWord)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                        .onSubmit(addWord)
                    Button("Add", action: addWord).buttonStyle(PillButtonStyle(prominent: false))
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !ignored.isEmpty {
                    RowDivider()
                    WordChips(words: ignored) { word in
                        withAnimation(.spring(duration: 0.25)) { ignored.removeAll { $0 == word } }
                        SpellController.ignored = ignored
                    }
                    .padding(.horizontal, Space.standard).padding(.vertical, 12)
                }
            }

            Label("Text goes only to the engine you pick, and to the next one if it fails. Apple Intelligence and Apple Spelling never leave this Mac. Orbit keeps no copy of what you check.", systemImage: "lock")
                .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                .padding(.horizontal, Space.tight)
        }
        .animation(.spring(duration: 0.3), value: engine)
        .animation(.spring(duration: 0.3), value: webAllowed)
        .alert("Check Korean with Daum and Naver?".loc, isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button("Not Now".loc, role: .cancel) { asking = nil }
            Button("Allow".loc) {
                let e = asking
                withAnimation(.spring(duration: 0.3)) { webAllowed = true; koreanEngine = e?.rawValue ?? "" }
                asking = nil
            }
        } message: {
            Text(["This text is sent to Daum’s or Naver’s spell checker.", "It’s an unofficial connection, so it may stop working if they change it.",
                  "For personal use. Orbit keeps no copy of what you check."].map(\.loc).joined(separator: "\n"))
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if !ignored.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            withAnimation(.spring(duration: 0.25)) { ignored.append(word) }
            SpellController.ignored = ignored
        }
        newWord = ""
    }

    private func saveAccount() {
        SpellController.languageToolAccount = .init(user: ltUser.trimmingCharacters(in: .whitespaces), key: ltKey.trimmingCharacters(in: .whitespaces))
    }
}

private struct SpellEngineCard: View {
    let engine: SpellEngine
    let selected: Bool
    var combined = false
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        let status = engine.status
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(engine.title.loc).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                        Text(engine.tag.loc).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                            .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Palette.raised))
                    }
                    Spacer()
                    Image(systemName: combined ? Self.combinedSymbol : selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(selected || combined ? Palette.accent : Palette.inkSecondary.opacity(0.5))
                }
                Text(engine.detail.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = status.note {
                    Label(note, systemImage: engine.isWeb ? "hand.raised" : "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .card(active: selected || combined)
            .scaleEffect(hovering ? 1.015 : 1)
            .opacity(status.ready ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!status.ready)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }

    /// checkmark.circle.badge.plus only ships with macOS 26.
    private static var combinedSymbol: String {
        if #available(macOS 26, *) { return "checkmark.circle.badge.plus" }
        return "plus.circle.fill"
    }
}

/// The ignore list as removable chips, wrapping onto more lines.
private struct WordChips: View {
    let words: [String]
    let remove: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(words, id: \.self) { w in
                HStack(spacing: 4) {
                    Text(w).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                    Button { remove(w) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                            .frame(width: 14, height: 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 10).padding(.trailing, 6).frame(height: 24)
                .background(Capsule().fill(Palette.raised))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays children out in rows, starting a new row when one is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let height = rows.map { $0.map { $0.size.height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map { r in r.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, r.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            let h = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += h + spacing
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }
}

/// Type something and watch it get checked, with the same markup as the card.
struct SpellPreview: View {
    @Binding var sample: String
    let setupKey: String
    let ignored: [String]
    @State private var result: SpellResult?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "textformat.abc.dottedunderline").font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
                TextField("Type something to check…", text: $sample, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .lineLimit(1...4)
                    .padding(.top, 10)
                Button("Open Card") { SpellController.shared.show(sample, from: .current) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.top, 4)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Group {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                } else if let result, !working {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SpellMarkup.text(result, accepted: Set(result.edits.filter(\.confident).map(\.id))))
                            .font(.system(size: 14)).foregroundStyle(Palette.ink).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        if result.edits.isEmpty {
                            Text("Nothing to fix ✓".loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                        } else {
                            WrapLayout(spacing: 6) {
                                ForEach(result.edits) { e in
                                    HStack(spacing: 4) {
                                        KindChip(kind: e.kind)
                                        Text(e.replacement.trimmingCharacters(in: .whitespacesAndNewlines))
                                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                                    }
                                }
                            }
                        }
                        if let notice = result.notice {
                            Label(notice, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Shimmer().frame(height: 13)
                        Shimmer().frame(width: 200, height: 13)
                    }
                }
            }
            .frame(minHeight: 44, alignment: .topLeading)
        }
        .padding(14)
        .card()
        .task(id: "\(setupKey)|\(sample)|\(ignored.joined(separator: ","))") { await check() }
    }

    private func check() async {
        let text = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { result = nil; return }
        working = true
        // Waits for a pause in typing; the online engines shouldn't see every keystroke.
        let online = SpellController.engine(for: text).isWeb || SpellController.engine(for: text) == .languageTool
        try? await Task.sleep(for: .milliseconds(online ? 900 : 450))
        guard !Task.isCancelled else { return }
        do {
            let r = try await SpellChecker.check(text, setup: SpellController.setup)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { result = r; failure = nil; working = false }
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            working = false
        }
    }
}
