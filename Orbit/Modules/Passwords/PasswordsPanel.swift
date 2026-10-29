import KeyboardShortcuts
import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class PasswordsPanelModel {
    var query = "" { didSet { selection = 0 } }
    var selection = 0
    var focusToken = 0
    var target: PasswordAutofill.Target?
    var warning: String?
    var unlocking = false
    var unlockError: String?

    /// Logins for the page in front first, then everything matching the search.
    var results: [VaultItem] {
        let items = Vault.shared.items
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let host = target?.host
        func site(_ i: VaultItem) -> Bool { host.map { h in i.hosts.contains { VaultItem.sameSite($0, h) } } ?? false }
        let matched = q.isEmpty ? items : items.filter { $0.searchText.contains(q) || $0.title.lowercased().hasPrefix(q) }
        return matched.sorted { a, b in
            let sa = site(a), sb = site(b)
            if sa != sb { return sa }
            if a.favorite != b.favorite { return a.favorite }
            if !q.isEmpty {
                let pa = a.title.lowercased().hasPrefix(q), pb = b.title.lowercased().hasPrefix(q)
                if pa != pb { return pa }
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    var selected: VaultItem? { let r = results; return r.indices.contains(selection) ? r[selection] : nil }

    func isSuggested(_ item: VaultItem) -> Bool {
        guard let h = target?.host else { return false }
        return item.hosts.contains { VaultItem.sameSite($0, h) }
    }

    func move(_ d: Int) {
        let n = results.count
        guard n > 0 else { return }
        selection = min(max(0, selection + d), n - 1)
    }
}

/// Quick Access, like 1Password's: one shortcut from anywhere, type to find a login, ↩ to fill it in.
@MainActor
final class PasswordsPanel {
    static let shared = PasswordsPanel()

    private let model = PasswordsPanelModel()
    private var monitor: Any?
    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        // Kept out of screenshots and screen recordings: it shows logins.
        p.sharingType = .none
        p.setContent(PasswordsPanelView(model: model, onFill: { [weak self] item, force in self?.fill(item, force: force) }))
        p.onResignKey = { [weak self] in self?.hide() }
        return p
    }()

    var isVisible: Bool { panel.isVisible }
    func toggle() { isVisible ? hide() : show() }

    func show() {
        let vault = Vault.shared
        guard vault.state != .none else {
            MainWindow.show(.passwords)
            return
        }
        Paster.start()
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? Paster.lastExternal : front
        model.target = PasswordAutofill.target(for: app)
        model.query = ""
        model.selection = 0
        model.warning = nil
        model.unlockError = nil
        let screen = NSScreen.active.visibleFrame
        let size = CGSize(width: 640, height: 420)
        panel.present(at: NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.08,
                                 width: size.width, height: size.height))
        model.focusToken += 1
        installKeys()
        if vault.state == .locked, vault.canUseTouchID {
            model.unlocking = true
            Task {
                await vault.unlockWithTouchID()
                model.unlocking = false
                model.focusToken += 1
            }
        }
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.dismiss()
    }

    func vaultLocked() { if isVisible { hide() } }

    private func installKeys() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let vault = Vault.shared
        if e.keyCode == 53 { // esc
            if !model.query.isEmpty { model.query = "" } else { hide() }
            return true
        }
        guard vault.state == .unlocked else { return false }
        switch e.keyCode {
        case 125: model.move(1); return true
        case 126: model.move(-1); return true
        case 48: model.move(flags.contains(.shift) ? -1 : 1); return true
        case 36, 76:
            guard let item = model.selected else { return true }
            if flags.contains(.command) { hide(); MainWindow.show(.passwords); PasswordsUI.shared.select(item); return true }
            fill(item, force: flags.contains(.option))
            return true
        default: break
        }
        guard flags.contains(.command), let item = model.selected else { return false }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "c":
            if flags.contains(.shift) { vault.copy(item.username, what: "Username") }
            else if flags.contains(.option) { if let code = TOTP(item.totp)?.code() { vault.copy(code, what: "One-time code") } }
            else { vault.copy(item.kind == .card ? item.cardNumber : item.password, what: item.kind == .card ? "Card number" : "Password") }
            hide()
            return true
        case "o":
            hide()
            MainWindow.show(.passwords)
            PasswordsUI.shared.select(item)
            return true
        default: return false
        }
    }

    private func fill(_ item: VaultItem, force: Bool) {
        guard let target = model.target else {
            Vault.shared.copy(item.password, what: "Password")
            hide()
            return
        }
        // A login for another site is never filled by accident: ⌥↩ to do it anyway.
        if let host = target.host, !item.hosts.isEmpty, !item.hosts.contains(where: { VaultItem.sameSite($0, host) }), !force {
            model.warning = "This login is for %@, but the page is %@. Press ⌥↩ to fill anyway.".loc(item.hosts.first ?? "", host)
            return
        }
        hide()
        let submit = Vault.shared.submitAfterFill
        Task {
            switch await PasswordAutofill.fill(item, into: target, submit: submit) {
            case .filled:
                if let code = TOTP(item.totp)?.code() { Vault.shared.copy(code, what: "One-time code") }
            case .noFields:
                Vault.shared.copy(item.password, what: "Password")
                Toast.show("No login fields found — the password is on the clipboard", symbol: "key.horizontal.fill")
            case .appChanged:
                Toast.show("Didn’t fill: another app came to the front", symbol: "exclamationmark.triangle.fill")
            case .noAccess:
                Toast.show("Filling needs Accessibility", symbol: "lock.fill", detail: "Orbit › Permissions")
            }
        }
    }
}

private struct PasswordsPanelView: View {
    @Bindable var model: PasswordsPanelModel
    let onFill: (VaultItem, Bool) -> Void
    @FocusState private var searchFocused: Bool
    private var vault: Vault { Vault.shared }

    var body: some View {
        Group {
            if vault.state == .unlocked { unlocked } else { LockedCard(compact: true, busy: model.unlocking) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelShell()
    }

    private var unlocked: some View {
        let results = model.results
        return VStack(spacing: 0) {
            HStack(spacing: Space.compact) {
                Image(systemName: "key.horizontal").foregroundStyle(.secondary)
                TextField("Search Passwords", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.orbitSearch)
                    .focused($searchFocused)
                if let host = model.target?.host {
                    Text(host).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Palette.raised))
                }
            }
            .padding(.horizontal, Space.standard)
            .frame(height: 52)
            Divider().opacity(0.5)
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.orbitCaption).foregroundStyle(Palette.accent)
                    .padding(.horizontal, Space.standard).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if results.isEmpty {
                VStack(spacing: Space.compact) {
                    Image(systemName: "key.horizontal").font(.system(size: 26)).foregroundStyle(Palette.inkSecondary)
                    Text(vault.items.isEmpty ? "No items yet" : "Nothing matches").font(.orbitBodyEmphasized)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(results).frame(width: 260)
                    Divider().opacity(0.5)
                    if let item = model.selected { ItemPeek(item: item).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: Space.standard) {
                ShortcutHint(title: "Fill", keys: ["↩"], emphasized: true)
                ShortcutHint(title: "Password", keys: ["⌘", "C"])
                ShortcutHint(title: "Username", keys: ["⇧", "⌘", "C"])
                ShortcutHint(title: "Code", keys: ["⌥", "⌘", "C"])
                Spacer()
                Button { vault.lock() } label: { Image(systemName: "lock") }
                    .buttonStyle(.plain).foregroundStyle(Palette.inkSecondary).help("Lock".loc)
            }
            .padding(.horizontal, Space.standard)
            .frame(height: Size.footer)
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { searchFocused = true }
    }

    private func list(_ results: [VaultItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                        Button { model.selection = i; onFill(item, false) } label: {
                            HStack(spacing: Space.compact) {
                                ItemIcon(item: item, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title.isEmpty ? "Untitled".loc : item.title).font(.orbitBodyEmphasized).lineLimit(1)
                                    Text(item.subtitle).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if model.isSuggested(item) {
                                    Image(systemName: "sparkle").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.accent)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(i == model.selection ? Palette.ink.opacity(0.1) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) {
                if let id = model.selected?.id { proxy.scrollTo(id) }
            }
        }
    }
}

/// The right side of Quick Access: what ↩ and the copy keys will use.
private struct ItemPeek: View {
    let item: VaultItem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.compact) {
                ItemIcon(item: item, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.orbitSection).lineLimit(1)
                    if let host = item.hosts.first { Text(host).font(.orbitCaption).foregroundStyle(Palette.inkSecondary) }
                }
            }
            if item.kind == .login {
                peek("Username", item.username)
                peek("Password", String(repeating: "•", count: min(12, item.password.count)))
                if TOTP(item.totp) != nil { TOTPView(totp: item.totp, compact: true) }
            } else {
                peek("Details", item.subtitle)
            }
            Spacer()
        }
        .padding(Space.standard)
    }

    private func peek(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
            Text(value.isEmpty ? "—" : value).font(.orbitBody).lineLimit(1)
        }
    }
}

extension KeyboardShortcuts.Name {
    static let passwords = Self("passwords", default: .init(.p, modifiers: [.option, .shift]))
}
