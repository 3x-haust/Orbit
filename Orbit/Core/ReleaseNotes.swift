import AppKit
import SwiftUI

/// What changed in each version, read in Orbit itself: the release notes from GitHub Releases, in
/// Orbit's language. After an update, the first launch of the new version shows what's new once.
@MainActor @Observable
final class ReleaseNotes {
    static let shared = ReleaseNotes()

    struct Entry: Identifiable, Equatable, Codable, Sendable {
        let version: String
        let date: Date?
        let notes: String
        let page: URL
        var id: String { version }
    }

    enum State: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var entries: [Entry] = []
    private(set) var state: State = .idle

    /// The version that ran last, to notice an update.
    private static let lastRunKey = "updates.lastRunVersion"

    private init() {
        if let data = try? Data(contentsOf: Self.cacheURL), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Fetches the latest notes (keeping what was saved if GitHub can't be reached).
    func load() {
        guard state != .loading else { return }
        state = .loading
        Task {
            do {
                let fresh = try await Self.fetch()
                entries = fresh
                state = .loaded
                if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: Self.cacheURL, options: .atomic) }
            } catch {
                state = entries.isEmpty ? .failed((error as? URLError)?.code == .notConnectedToInternet ? "You’re offline".loc : "Couldn’t load the release notes".loc) : .loaded
            }
        }
    }

    // MARK: After an update

    /// At launch: the first run of a newer version than last time shows what's new in it. A fresh
    /// install shows nothing.
    func launched() {
        let current = Updater.shared.currentVersion
        let last = Pref.defaults.string(forKey: Self.lastRunKey)
        Pref.defaults.set(current, forKey: Self.lastRunKey)
        guard let last, Updater.isNewer(current, than: last), !Updater.shared.isDevBuild else { return }
        Task {
            if let fresh = try? await Self.fetch() {
                entries = fresh
                state = .loaded
            }
            guard let entry = entries.first(where: { $0.version == current }), !ReleaseNotesText.section(entry.notes).isEmpty else { return }
            UpdateLog.write("updated \(last) → \(current); showing what's new")
            WhatsNewPrompt.show(entry)
        }
    }

    // MARK: GitHub

    private nonisolated static var cacheURL: URL { Storage.dir("Updates").appendingPathComponent("releases.json") }

    private nonisolated static func fetch() async throws -> [Entry] {
        struct Payload: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let published_at: Date?
        }
        let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases?per_page=30")!
        let (data, response) = try await URLSession.shared.data(for: Updater.request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Payload].self, from: data)
            .filter { !$0.draft && !$0.prerelease }
            .map { p in
                Entry(version: p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name,
                      date: p.published_at, notes: p.body ?? "", page: p.html_url)
            }
    }
}

/// Release notes are written English, `---`, then Korean, then an install table. Orbit shows the
/// part in its own language, without the install table, with headings as bold lines (inline Markdown
/// leaves "### " as it is).
enum ReleaseNotesText {
    static func section(_ markdown: String) -> String {
        let parts = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n---\n")
        let korean = Bundle.main.preferredLocalizations.first == "ko"
        var text = parts.count > 1 && korean ? parts[1] : parts[0]
        if let install = text.range(of: "### Install") { text = String(text[..<install.lowerBound]) }
        return text.components(separatedBy: "\n")
            // The "## Orbit 1.2.4" title: the version is shown above the notes already.
            .filter { !$0.hasPrefix("## Orbit") }
            .map { line in
                if line.hasPrefix("#") { return "**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**" }
                if line.hasPrefix("- ") { return "• " + line.dropFirst(2) }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributed(_ markdown: String) -> AttributedString {
        let text = section(markdown)
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: - Every version

/// The release notes of recent versions, newest first; `focus` scrolls to one.
struct ReleaseNotesView: View {
    var focus: String?
    @Bindable private var notes = ReleaseNotes.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Release Notes").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                Spacer()
                if notes.state == .loading { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider().overlay(Palette.hairline)
            content
        }
        .frame(width: 540, height: 600)
        .background(Palette.canvas)
        .onAppear { notes.load() }
    }

    @ViewBuilder private var content: some View {
        if notes.entries.isEmpty {
            VStack(spacing: 8) {
                if case .failed(let message) = notes.state {
                    Text(message).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                    Button("Try Again") { notes.load() }.buttonStyle(PillButtonStyle(prominent: false))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(notes.entries) { entry in
                            ReleaseCard(entry: entry, current: entry.version == Updater.shared.currentVersion)
                                .id(entry.version)
                        }
                    }
                    .padding(18)
                }
                .onAppear { if let focus { proxy.scrollTo(focus, anchor: .top) } }
            }
        }
    }
}

private struct ReleaseCard: View {
    let entry: ReleaseNotes.Entry
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Orbit %@".loc(entry.version)).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                if current {
                    Text("This version").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accent.opacity(0.14)))
                }
                Spacer()
                if let date = entry.date {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
            }
            Text(ReleaseNotesText.attributed(entry.notes))
                .font(.system(size: 12)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(current ? Palette.accent.opacity(0.4) : Palette.hairline, lineWidth: 1))
    }
}

// MARK: - What's new, once after an update

@MainActor
enum WhatsNewPrompt {
    private static var panel: FloatingPanel?

    static func show(_ entry: ReleaseNotes.Entry) {
        let panel = self.panel ?? FloatingPanel(contentRect: .zero, focusable: true)
        self.panel = panel
        panel.level = .statusBar
        panel.setContent(WhatsNewView(entry: entry))
        let size = NSSize(width: 360, height: 360)
        let screen = NSScreen.active.visibleFrame
        panel.present(at: NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12,
                                 width: size.width, height: size.height))
    }

    static func close() { panel?.dismiss() }
}

private struct WhatsNewView: View {
    let entry: ReleaseNotes.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: Brand.logo).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What’s new in Orbit %@".loc(entry.version))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Orbit was updated").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(ReleaseNotesText.attributed(entry.notes))
                    .font(.system(size: 12)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
            HStack(spacing: 8) {
                Button("All Release Notes") {
                    WhatsNewPrompt.close()
                    MainWindow.show(.general)
                    ReleaseNotesSheet.open(focus: entry.version)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                Spacer()
                Button("OK") { WhatsNewPrompt.close() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.canvas))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// Asks the General page to show the release notes, from anywhere (the update card, What's new).
@MainActor @Observable
final class ReleaseNotesSheet {
    static let shared = ReleaseNotesSheet()
    var presented = false
    var focus: String?

    static func open(focus: String? = nil) {
        shared.focus = focus
        shared.presented = true
    }
}
