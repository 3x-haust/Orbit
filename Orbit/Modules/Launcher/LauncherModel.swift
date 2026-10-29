import AppKit
import SwiftUI
import Observation

struct LauncherAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var shortcut: [String] = []
    let perform: () -> Void
}

struct LauncherItem: Identifiable {
    enum Icon { case symbol(String, Color), file(String), image(NSImage), mark }

    let id: String
    let title: String
    var subtitle: String?
    let icon: Icon
    var accessory: String?
    let section: String
    let actions: [LauncherAction] // first is primary
}

@MainActor @Observable
final class LauncherModel {
    var query = "" { didSet { selection = 0; actionsOpen = false; actionQuery = "" } }
    var selection = 0
    var actionsOpen = false { didSet { actionSelection = 0 } }
    var actionQuery = "" { didSet { actionSelection = 0 } }
    var actionSelection = 0
    var focusToken = 0

    private(set) var items: [LauncherItem] = []
    var onDismiss: () -> Void = {}

    func refresh() { items = build(query) }

    var selected: LauncherItem? { items.indices.contains(selection) ? items[selection] : nil }

    var filteredActions: [LauncherAction] {
        let actions = selected?.actions ?? []
        let q = actionQuery.lowercased()
        return q.isEmpty ? actions : actions.filter { $0.title.lowercased().contains(q) }
    }

    func move(_ delta: Int) {
        if actionsOpen {
            let n = filteredActions.count
            if n > 0 { actionSelection = (actionSelection + delta + n) % n }
        } else if !items.isEmpty {
            selection = min(max(0, selection + delta), items.count - 1)
        }
    }

    func runPrimary() {
        if actionsOpen {
            let a = filteredActions
            guard a.indices.contains(actionSelection) else { return }
            run(a[actionSelection])
        } else if let action = selected?.actions.first {
            run(action)
        }
    }

    func runSecondary() {
        guard let actions = selected?.actions, actions.count > 1 else { return }
        run(actions[1])
    }

    private func run(_ action: LauncherAction) {
        // Window titles come and go (every web page has one); remembering them would only grow the table.
        if let id = selected?.id, !id.hasPrefix("win.") { Frecency.bump(id) }
        onDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { action.perform() }
    }

    // MARK: Building results

    private func build(_ raw: String) -> [LauncherItem] {
        let q = raw.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        var result: [LauncherItem] = []

        if let value = Calculator.evaluate(q) {
            let text = Calculator.format(value)
            result.append(LauncherItem(id: "calc", title: text, subtitle: "= \(q)", icon: .symbol("equal", Tint.launcher),
                                       accessory: "Calculator", section: "Calculator", actions: [
                LauncherAction(title: "Copy Answer", symbol: "doc.on.doc") { Self.copy(text) },
            ]))
        }

        if q.isEmpty {
            result += suggestions()
            return result
        }

        result += SmartAnswers.answers(for: q)
        let answered = !result.isEmpty

        // Only what the query is really about: once something matches by name, keyword hits and
        // scattered-letter hits are noise ("orbit" used to list every command, since all of them
        // carry Orbit as a keyword). Looser matches are a fallback for when nothing else fits.
        let pageScores = Page.allCases.compactMap { p in Fuzzy.score(q, p.title).map { (p, $0) } }
        let commandScores = OrbitAction.allCases.compactMap { a in Fuzzy.score(q, a.title, keywords: a.keywords).map { (a, $0) } }
        let appScores = AppIndex.shared.apps.compactMap { app in Fuzzy.score(q, app.name).map { (app, $0) } }
        // A window matches by its own title, or a little below that by its app ("safa" → every Safari window).
        let windowScores: [(OpenWindows.Window, Int)] = OpenWindows.shared.windows.compactMap { w in
            let byTitle: Int? = Fuzzy.score(q, w.title)
            let byApp: Int? = Fuzzy.score(q, w.appName).map { $0 - 100 }
            guard let score = [byTitle, byApp].compactMap({ $0 }).max() else { return nil }
            return (w, score)
        }
        let scores: [Int] = pageScores.map(\.1) + commandScores.map(\.1) + appScores.map(\.1)
        let best = (scores + windowScores.map(\.1)).max() ?? 0
        let floor = best >= Fuzzy.substring ? Fuzzy.substring - 100 : best >= Fuzzy.keyword ? Fuzzy.keyword : 0

        // Orbit's own pages ("사운드", "storage", "번역"…) open the app window there.
        result += pageScores.filter { $0.1 >= max(floor, Fuzzy.substring - 100) }
        .sorted { $0.1 > $1.1 }.prefix(2).map { page, _ in
            LauncherItem(id: "page.\(page.rawValue)", title: page.title, subtitle: "Orbit", icon: .mark, accessory: "Orbit", section: "Orbit", actions: [
                LauncherAction(title: "Open", symbol: "macwindow") { MainWindow.show(page) },
            ])
        }

        let commands = commandScores
            .filter { $0.1 >= floor }
            .map { ($0.0, $0.1 + Frecency.boost("cmd.\($0.0.rawValue)")) }
            .sorted { $0.1 > $1.1 }
            .prefix(6)
            .map { command($0.0) }

        let apps = appScores
            .filter { $0.1 >= floor }
            .map { ($0.0, $0.1 + Frecency.boost("app.\($0.0.path)")) }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { application($0.0) }

        // Order sections by their best match.
        if (apps.first.map { Fuzzy.score(q, $0.title) ?? 0 } ?? 0) >= (commands.first.map { Fuzzy.score(q, $0.title) ?? 0 } ?? 0) {
            result += apps + commands
        } else {
            result += commands + apps
        }

        result += windowScores
            .filter { $0.1 >= floor }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { window($0.0) }

        result += SnippetStore.shared.launcherItems(for: q)
        result += ClipboardStore.shared.search(q).prefix(best >= Fuzzy.substring ? 3 : 5).map(clip)
        result += SmartAnswers.trailing(for: q)

        // Searching the web is the way out when nothing here fits, not an extra under every search.
        if q.count > 1, best < Fuzzy.substring - 100, !answered {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            result.append(LauncherItem(id: "web", title: "Search Google for “%@”".loc(q), icon: .symbol("magnifyingglass", .blue),
                                       accessory: "Web", section: "Web", actions: [
                LauncherAction(title: "Search", symbol: "safari") {
                    if let url = URL(string: "https://www.google.com/search?q=\(encoded)") { NSWorkspace.shared.open(url) }
                },
            ]))
        }
        return result
    }

    private func suggestions() -> [LauncherItem] {
        let favorites: [OrbitAction] = [.captureArea, .captureText, .clipboard, .winLeft, .winRight, .winMaximize, .keepAwake]
        let ranked = OrbitAction.allCases.filter { Frecency.boost("cmd.\($0.rawValue)") > 0 }
            .sorted { Frecency.boost("cmd.\($0.rawValue)") > Frecency.boost("cmd.\($1.rawValue)") }
        var seen = Set<OrbitAction>()
        let commands = (ranked + favorites).filter { seen.insert($0).inserted }.prefix(7).map { command($0, section: "Suggestions") }
        let recentApps = AppIndex.shared.apps
            .filter { Frecency.boost("app.\($0.path)") > 0 }
            .sorted { Frecency.boost("app.\($0.path)") > Frecency.boost("app.\($1.path)") }
            .prefix(3).map { application($0, section: "Recent Apps") }
        let clips = ClipboardStore.shared.items.prefix(3).map(clip)
        return commands + recentApps + clips
    }

    private func command(_ a: OrbitAction, section: String = "Commands") -> LauncherItem {
        LauncherItem(id: "cmd.\(a.rawValue)", title: a.title, subtitle: a.groupTitle, icon: .symbol(a.symbol, a.tint),
                     accessory: a.shortcutLabel, section: section, actions: [
            LauncherAction(title: "Run Command", symbol: "return") { a.perform() },
            LauncherAction(title: "Change Shortcut…", symbol: "keyboard") { MainWindow.show(.shortcuts) },
        ])
    }

    private func application(_ app: AppIndex.App, section: String = "Applications") -> LauncherItem {
        let url = URL(fileURLWithPath: app.path)
        return LauncherItem(id: "app.\(app.path)", title: app.name, icon: .file(app.path), accessory: "Application", section: section, actions: [
            LauncherAction(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) },
            LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: ["⌘", "↩"]) { NSWorkspace.shared.activateFileViewerSelecting([url]) },
            LauncherAction(title: "Copy Path", symbol: "doc.on.doc") { Self.copy(app.path) },
            LauncherAction(title: "Uninstall…", symbol: "trash") { AppUninstaller.shared.present(app: url) },
        ])
    }

    private func window(_ w: OpenWindows.Window) -> LauncherItem {
        LauncherItem(id: "win.\(w.pid).\(w.title)", title: w.title, subtitle: w.appName,
                     icon: w.appPath.map { .file($0) } ?? .symbol("macwindow", Tint.launcher),
                     accessory: w.minimized ? "Minimized" : "Window", section: "Open Windows", actions: [
            LauncherAction(title: "Switch to Window", symbol: "macwindow") { OpenWindows.shared.focus(w) },
            LauncherAction(title: "Close Window", symbol: "xmark.square") { OpenWindows.shared.close(w) },
            LauncherAction(title: "Quit App", symbol: "power") { NSRunningApplication(processIdentifier: w.pid)?.terminate() },
        ])
    }

    private func clip(_ item: ClipItem) -> LauncherItem {
        let icon: LauncherItem.Icon = item.kind == .image ? (ClipboardStore.shared.image(for: item).map { .image($0) } ?? .symbol("photo", Tint.clipboard))
            : .symbol(item.kind.symbol, Tint.clipboard)
        return LauncherItem(id: "clip.\(item.id)", title: item.title.replacingOccurrences(of: "\n", with: " "),
                            subtitle: item.appName, icon: icon, accessory: item.date.orbitRelative, section: "Clipboard", actions: [
            LauncherAction(title: "Paste", symbol: "doc.on.clipboard") { ClipboardPanel.shared.paste(item, plain: false) },
            LauncherAction(title: "Copy", symbol: "doc.on.doc", shortcut: ["⌘", "↩"]) { ClipboardStore.shared.copy(item); Toast.show("Copied") },
            LauncherAction(title: "Paste as Plain Text", symbol: "textformat") { ClipboardPanel.shared.paste(item, plain: true) },
            LauncherAction(title: item.pinned ? "Unpin" : "Pin", symbol: "pin") { ClipboardStore.shared.togglePin(item) },
        ])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied", detail: text)
    }
}

// MARK: - Ranking

enum Fuzzy {
    /// The score of a plain substring hit in a short title; title matches score at least about this.
    static let substring = 600
    /// A keyword-prefix hit.
    static let keyword = 400

    /// nil = no match. Prefix > word prefix > substring > subsequence.
    static func score(_ query: String, _ title: String, keywords: String = "") -> Int? {
        let q = query.lowercased(), t = title.lowercased()
        if t == q { return 1000 }
        if t.hasPrefix(q) { return 900 - t.count }
        let words = t.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(q) }) { return 750 - t.count }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(q) { return 700 }
        if t.contains(q) { return 600 - t.count }
        if !keywords.isEmpty, keywords.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 400 }
        var i = t.startIndex
        for ch in q {
            guard let found = t[i...].firstIndex(of: ch) else { return nil }
            i = t.index(after: found)
        }
        return 200 - t.count
    }
}

enum Frecency {
    private static let key = "launcher.frecency"

    static func bump(_ id: String) {
        var table = Pref.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        table[id, default: 0] += 1
        Pref.defaults.set(table, forKey: key)
    }

    static func boost(_ id: String) -> Int {
        let table = Pref.defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return Int(min(150, (table[id] ?? 0) * 15))
    }
}

// MARK: - Calculator

/// Tiny recursive-descent evaluator: + - * / % ^ and parentheses. Never uses NSExpression (which can raise).
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        let s = input.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        guard s.count >= 3, s.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/%^")) != nil,
              s.allSatisfy({ "0123456789.+-*/%^()".contains($0) }) else { return nil }
        var parser = Parser(chars: Array(s))
        guard let v = parser.expression(), parser.i == parser.chars.count, v.isFinite else { return nil }
        return v
    }

    static func format(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 10
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private struct Parser {
        let chars: [Character]
        var i = 0

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]; i += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while i < chars.count, "*/%".contains(chars[i]) {
                let op = chars[i]; i += 1
                guard let r = power() else { return nil }
                switch op {
                case "*": v *= r
                case "/": v /= r
                default: v = v.truncatingRemainder(dividingBy: r)
                }
            }
            return v
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < chars.count, chars[i] == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func unary() -> Double? {
            if i < chars.count, chars[i] == "-" { i += 1; return unary().map { -$0 } }
            return primary()
        }

        mutating func primary() -> Double? {
            if i < chars.count, chars[i] == "(" {
                i += 1
                let v = expression()
                guard i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            return Double(String(chars[start..<i]))
        }
    }
}
