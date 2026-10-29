import SwiftUI
import UniformTypeIdentifiers

/// Orbit Passwords: a 1Password-style vault on this Mac.
struct PasswordsPage: View {
    private var vault: Vault { Vault.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            PageHeader(title: "Passwords", subtitle: "Logins, cards and notes, locked with your Master Password and a Secret Key only this Mac has.") {
                if vault.state == .unlocked {
                    HStack(spacing: Space.compact) {
                        GeneratorButton()
                        Button { vault.lock() } label: { Label("Lock", systemImage: "lock") }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }
            switch vault.state {
            case .none: SetupFlow()
            case .locked:
                LockedCard()
                    .frame(height: 420)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                if vault.secretKeyMissing { RestoreGroup() }
            case .unlocked:
                VaultBrowser()
                PasswordsSettings()
            }
        }
    }
}

// MARK: - Setup

private struct SetupFlow: View {
    enum Step { case intro, password, kit, restore }
    @State private var step = Step.intro
    @State private var password = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var account: Vault.PendingAccount?
    @State private var savedPDF = false
    @State private var savedKit = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.group) {
            switch step {
            case .intro: intro
            case .password: passwordStep
            case .kit: kitStep
            case .restore: RestoreGroup(onCancel: { step = .intro })
            }
        }
        .onDisappear { account?.wipe() }
    }

    private var intro: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: Space.standard) {
                HStack(spacing: Space.related) {
                    Image(systemName: "key.horizontal.fill").font(.system(size: 22, weight: .semibold))
                        .frame(width: 48, height: 48).background(Circle().fill(Palette.raised))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up Orbit Passwords").font(.orbitTitle)
                        Text("Two secrets open the vault: your Master Password and a Secret Key.").font(.orbitBody).foregroundStyle(Palette.inkSecondary)
                    }
                }
                explainer("person.badge.key", "Master Password", "Only you know it. Orbit never stores it.")
                explainer("key.viewfinder", "Secret Key", "Made on this Mac and kept in its Keychain. Your vault file is useless without it, even with the password.")
                explainer("touchid", "Touch ID", "After setup, unlock with your fingerprint. The Secure Enclave guards the key.")
                HStack {
                    Button("Restore from Emergency Kit…") { step = .restore }.buttonStyle(PillButtonStyle(prominent: false))
                    Spacer()
                    Button("Get Started") { step = .password }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(Space.group)
        }
    }

    private func explainer(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.related) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.orbitBodyEmphasized)
                Text(text.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private var longEnough: Bool { password.count >= 10 }
    private var strongEnough: Bool { !password.isEmpty && PasswordStrength.level(password) >= .fair }
    private var matches: Bool { !password.isEmpty && password == confirm }
    private var passwordOK: Bool { longEnough && strongEnough && matches }

    /// What still stands between the person and the next step, in words.
    private var missing: String? {
        if !longEnough { return "Make the Master Password at least 10 characters.".loc }
        if !strongEnough { return "Make it a little harder to guess — add a word or two.".loc }
        if !matches { return confirm.isEmpty ? "Type it again to confirm.".loc : "The two entries don’t match yet.".loc }
        return nil
    }

    private var passwordStep: some View {
        SettingsGroup(title: "Master Password", footer: "At least 10 characters. A few random words is easy to remember and hard to guess. If you forget it, the vault can’t be opened — not even by Orbit.") {
            VStack(alignment: .leading, spacing: Space.related) {
                field("Master Password", $password)
                StrengthBar(password: password)
                field("Type it again", $confirm)
                VStack(alignment: .leading, spacing: 4) {
                    requirement("At least 10 characters", longEnough)
                    requirement("Strength is Fair or better", strongEnough)
                    requirement("Both entries match", matches)
                }
                HStack {
                    Button("Back") { step = .intro }.buttonStyle(PillButtonStyle(prominent: false))
                    Spacer()
                    if let missing, !password.isEmpty {
                        Text(missing).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    Button("Next") { toKit() }.buttonStyle(PillButtonStyle()).disabled(!passwordOK)
                }
            }
            .padding(Space.standard)
        }
    }

    private func toKit() {
        guard passwordOK else { return }
        if account == nil { account = try? Vault.PendingAccount.make() }
        guard account != nil else { error = "Couldn’t create the vault.".loc; return }
        step = .kit
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        SecureField(title.loc, text: text)
            .textFieldStyle(.plain)
            .font(.orbitBody)
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
    }

    private func requirement(_ text: String, _ met: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(met ? Palette.ink : Palette.inkSecondary)
            Text(text.loc).font(.orbitCaption).foregroundStyle(met ? Palette.ink : Palette.inkSecondary)
        }
    }

    private var canCreate: Bool { passwordOK && account != nil && savedKit && !working }

    private var kitStep: some View {
        SettingsGroup(title: "Your Emergency Kit", footer: "Orbit keeps the Secret Key in this Mac’s Keychain. The kit is how you get back in on a new Mac — the vault is made only after you’ve saved it.") {
            VStack(alignment: .leading, spacing: Space.related) {
                Text("Secret Key").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                Text(account?.text ?? "")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
                HStack {
                    Button {
                        guard let account else { return }
                        EmergencyKit.save(secretKey: account.text, accountID: account.accountID)
                        savedPDF = true
                    } label: { Label("Save Emergency Kit (PDF)…", systemImage: "arrow.down.doc") }
                        .buttonStyle(PillButtonStyle(prominent: false))
                    if savedPDF {
                        Label("Saved", systemImage: "checkmark.circle.fill").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                }
                Toggle("I saved my Emergency Kit somewhere safe", isOn: $savedKit).toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 4) {
                    requirement("Master Password is ready", passwordOK)
                    requirement("Emergency Kit saved", savedKit)
                }
                if let error { Text(error).font(.orbitCaption).foregroundStyle(Palette.accent) }
                HStack {
                    Button("Back") { step = .password }.buttonStyle(PillButtonStyle(prominent: false))
                    Spacer()
                    if !savedKit {
                        Text("Save the kit and tick the box to continue.").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    if working { ProgressView().controlSize(.small) }
                    Button("Create Vault", action: create).buttonStyle(PillButtonStyle()).disabled(!canCreate)
                }
            }
            .padding(Space.standard)
        }
    }

    private func create() {
        guard canCreate, let pending = account else { return }
        working = true
        error = nil
        let pw = password
        Task {
            do {
                try await Vault.shared.create(password: pw, account: pending)
                password = ""
                confirm = ""
                account?.wipe()
                account = nil
            } catch {
                self.error = "Couldn’t create the vault.".loc
            }
            working = false
        }
    }
}

/// Bringing a vault to this Mac: its file plus the Emergency Kit.
private struct RestoreGroup: View {
    var onCancel: (() -> Void)?
    @State private var file: URL?
    @State private var secretKey = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        SettingsGroup(title: "Restore from Emergency Kit", footer: "Choose the vault file you backed up, then type the Secret Key from the kit and your Master Password.") {
            VStack(alignment: .leading, spacing: Space.related) {
                HStack {
                    Text(file?.lastPathComponent ?? "No vault file chosen".loc).font(.orbitBody).foregroundStyle(file == nil ? Palette.inkSecondary : Palette.ink)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "orbitvault") ?? .data, .data]
                        if panel.runModal() == .OK { file = panel.url }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
                TextField("Secret Key (O1-…)", text: $secretKey)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                SecureField("Master Password", text: $password)
                    .textFieldStyle(.plain).font(.orbitBody)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                if let error { Text(error).font(.orbitCaption).foregroundStyle(Palette.accent) }
                HStack {
                    if let onCancel { Button("Back", action: onCancel).buttonStyle(PillButtonStyle(prominent: false)) }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Restore") { restore() }.buttonStyle(PillButtonStyle())
                        .disabled(file == nil || secretKey.isEmpty || password.isEmpty || working)
                }
            }
            .padding(Space.standard)
        }
    }

    private func restore() {
        guard let file else { return }
        working = true
        error = nil
        let sk = secretKey, pw = password
        Task {
            do {
                try await Vault.shared.restore(from: file, secretKeyText: sk, password: pw)
                password = ""
                secretKey = ""
            } catch {
                self.error = "The Secret Key or Master Password doesn’t open this vault.".loc
            }
            working = false
        }
    }
}

// MARK: - Browser

private struct VaultBrowser: View {
    @State private var showImport = false
    @Bindable private var ui = PasswordsUI.shared
    private var vault: Vault { Vault.shared }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Divider().opacity(0.6)
            if ui.section == .watchtower {
                WatchtowerView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list.frame(width: 270)
                Divider().opacity(0.6)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 620)
        .sheet(isPresented: $showImport) { PasswordImportSheet() }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    // Sidebar

    private var tags: [String] { Array(Set(vault.items.flatMap(\.tags))).sorted() }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                side(.all, "All Items", "square.stack", vault.items.count)
                side(.favorites, "Favorites", "star", vault.items.filter(\.favorite).count)
                sideHeading("Categories")
                ForEach(VaultItem.Kind.allCases) { k in side(.kind(k), k.plural, k.symbol, vault.items.filter { $0.kind == k }.count) }
                sideHeading("Security")
                let issueCount = Set(vault.issues.values.flatMap { $0.map(\.id) }).count
                side(.watchtower, "Watchtower", "shield.lefthalf.filled", issueCount, alert: issueCount > 0)
                if !tags.isEmpty {
                    sideHeading("Tags")
                    ForEach(tags, id: \.self) { t in side(.tag(t), t, "tag", vault.items.filter { $0.tags.contains(t) }.count, raw: true) }
                }
            }
            .padding(8)
        }
    }

    private func sideHeading(_ t: String) -> some View {
        Text(t.loc.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5)
            .foregroundStyle(Palette.inkSecondary).padding(.top, 12).padding(.leading, 8).padding(.bottom, 2)
    }

    private func side(_ s: PasswordsUI.Section, _ title: String, _ symbol: String, _ count: Int, alert: Bool = false, raw: Bool = false) -> some View {
        Button {
            ui.section = s
            ui.editing = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(raw ? title : title.loc).font(.orbitBody).lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(.orbitMicro.monospacedDigit())
                        .foregroundStyle(alert ? Palette.accent : Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ui.section == s ? Palette.ink.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // List

    private var filtered: [VaultItem] {
        let q = ui.search.lowercased().trimmingCharacters(in: .whitespaces)
        return vault.items.filter { item in
            let inSection: Bool = switch ui.section {
            case .all, .watchtower, .settings: true
            case .favorites: item.favorite
            case .kind(let k): item.kind == k
            case .tag(let t): item.tags.contains(t)
            }
            return inSection && (q.isEmpty || item.searchText.contains(q))
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                TextField("Search", text: $ui.search).textFieldStyle(.plain).font(.orbitBody)
                Menu {
                    ForEach(VaultItem.Kind.allCases) { k in
                        Button { newItem(k) } label: { Label(k.title.loc, systemImage: k.symbol) }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("New Item".loc)
            }
            .padding(.horizontal, 12).frame(height: 44)
            Divider().opacity(0.6)
            let items = filtered
            if items.isEmpty {
                VStack(spacing: Space.compact) {
                    Image(systemName: "key.horizontal").font(.system(size: 24)).foregroundStyle(Palette.inkSecondary)
                    Text(vault.items.isEmpty ? "Add your first login, or bring in the ones you already have." : "Nothing here")
                        .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                    if vault.items.isEmpty {
                        Button("Import Passwords…") { showImport = true }.buttonStyle(PillButtonStyle()).padding(.top, 4)
                    }
                }
                .padding(Space.standard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in row(item) }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func row(_ item: VaultItem) -> some View {
        Button {
            ui.selectedID = item.id
            ui.editing = nil
        } label: {
            HStack(spacing: Space.compact) {
                ItemIcon(item: item, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title.isEmpty ? "Untitled".loc : item.title).font(.orbitBodyEmphasized).lineLimit(1)
                    Text(item.subtitle).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.favorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Palette.inkSecondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ui.selectedID == item.id ? Palette.ink.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Password") { vault.copy(item.password, what: "Password") }.disabled(item.password.isEmpty)
            Button("Copy Username") { vault.copy(item.username, what: "Username") }.disabled(item.username.isEmpty)
            Button(item.favorite ? "Remove from Favorites" : "Add to Favorites") {
                var i = item; i.favorite.toggle(); vault.save(i)
            }
            Divider()
            Button("Delete", role: .destructive) { vault.delete(item); if ui.selectedID == item.id { ui.selectedID = nil } }
        }
    }

    private func newItem(_ k: VaultItem.Kind) {
        var item = VaultItem(kind: k)
        if k == .login { item.setPassword(PasswordGenerator.make(vault.generatorOptions)) }
        ui.editing = item
        ui.selectedID = item.id
    }

    // Detail

    @ViewBuilder private var detail: some View {
        if let editing = ui.editing {
            ItemEditor(item: editing) { saved in
                if let saved { vault.save(saved); ui.selectedID = saved.id }
                ui.editing = nil
            }
            .id(editing.id)
        } else if let id = ui.selectedID, let item = vault.items.first(where: { $0.id == id }) {
            ItemDetail(item: item).id(item.id)
        } else {
            VStack(spacing: Space.compact) {
                Image(systemName: "lock.open").font(.system(size: 28)).foregroundStyle(Palette.inkSecondary)
                Text("Pick an item").font(.orbitBodyEmphasized)
                Text("Anywhere on the Mac, %@ opens Quick Access to fill a login.".loc(OrbitAction.passwords.shortcutLabel ?? "⌥⇧P"))
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            }
            .padding(Space.group)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Item detail

private struct ItemDetail: View {
    let item: VaultItem
    @State private var revealed: Set<String> = []
    @State private var confirmDelete = false
    private var vault: Vault { Vault.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.standard) {
                HStack(spacing: Space.related) {
                    ItemIcon(item: item, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title.isEmpty ? "Untitled".loc : item.title).font(.orbitTitle).lineLimit(2)
                        Text(item.kind.title.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    IconButton(symbol: item.favorite ? "star.fill" : "star", help: "Favorite") {
                        var i = item; i.favorite.toggle(); vault.save(i)
                    }
                    Button("Edit") { PasswordsUI.shared.editing = item }.buttonStyle(PillButtonStyle(prominent: false))
                }
                VStack(spacing: 0) { fields }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.page))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                if !item.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes".loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                        Text(item.notes).font(.orbitBody).textSelection(.enabled)
                    }
                }
                if !item.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.tags, id: \.self) { t in
                            Text(t).font(.orbitCaption).padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(Palette.raised))
                        }
                    }
                }
                if !item.passwordHistory.isEmpty {
                    DisclosureGroup("Previous passwords (%ld)".loc(item.passwordHistory.count)) {
                        ForEach(Array(item.passwordHistory.prefix(10).enumerated()), id: \.offset) { _, old in
                            HStack {
                                Text(String(repeating: "•", count: 10)).font(.system(.body, design: .monospaced))
                                Text(old.replaced.formatted(date: .abbreviated, time: .omitted)).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                                Spacer()
                                IconButton(symbol: "doc.on.doc", help: "Copy") { vault.copy(old.value, what: "Password") }
                            }
                        }
                    }
                    .font(.orbitCaption)
                }
                HStack {
                    Text("Edited %@".loc(item.updated.formatted(date: .abbreviated, time: .shortened)))
                        .font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                    Spacer()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.plain).font(.orbitCaption).foregroundStyle(Palette.accent)
                }
            }
            .padding(Space.group)
        }
        .alert("Delete “%@”?".loc(item.title), isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                vault.delete(item)
                PasswordsUI.shared.selectedID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s removed from the vault on this Mac. This can’t be undone.")
        }
    }

    @ViewBuilder private var fields: some View {
        let rows = rowsFor(item)
        ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
            if i > 0 { RowDivider() }
            if r.label == "One-time code" {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.label.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                        TOTPView(totp: r.value)
                    }
                    Spacer()
                    IconButton(symbol: "doc.on.doc", help: "Copy") {
                        if let c = TOTP(r.value)?.code() { vault.copy(c, what: "One-time code") }
                    }
                }
                .padding(.horizontal, Space.standard).padding(.vertical, 10)
            } else {
                FieldRow(label: r.label, value: r.value, concealed: r.concealed, link: r.link,
                         revealed: revealed.contains(r.label + "\(i)"),
                         onReveal: { revealed.formSymmetricDifference([r.label + "\(i)"]) })
            }
        }
    }

    private struct Row { var label: String; var value: String; var concealed = false; var link = false }

    private func rowsFor(_ item: VaultItem) -> [Row] {
        var r: [Row] = []
        func add(_ l: String, _ v: String, concealed: Bool = false, link: Bool = false) { if !v.isEmpty { r.append(.init(label: l, value: v, concealed: concealed, link: link)) } }
        switch item.kind {
        case .login:
            add("Username", item.username)
            add("Password", item.password, concealed: true)
            if TOTP(item.totp) != nil { r.append(.init(label: "One-time code", value: item.totp)) }
            for u in item.urls { add("Website", u, link: true) }
        case .card:
            add("Cardholder", item.cardholder)
            add("Number", item.cardNumber, concealed: true)
            add("Expires", item.cardExpiry)
            add("Security code", item.cardCode, concealed: true)
            add("PIN", item.cardPIN, concealed: true)
        case .identity:
            add("Name", [item.firstName, item.lastName].filter { !$0.isEmpty }.joined(separator: " "))
            add("Email", item.email)
            add("Phone", item.phone)
            add("Address", item.address)
            add("Company", item.company)
        case .note:
            break
        }
        for f in item.fields { add(f.label, f.value, concealed: f.concealed) }
        return r
    }
}

/// One labelled value with copy, and reveal for hidden ones.
private struct FieldRow: View {
    let label: String
    let value: String
    var concealed = false
    var link = false
    var revealed = false
    var onReveal: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.compact) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                if concealed && !revealed {
                    Text(String(repeating: "•", count: min(14, max(8, value.count)))).font(.system(size: 13, design: .monospaced))
                } else if link, let url = URL(string: value.contains("://") ? value : "https://" + value) {
                    Link(value, destination: url).font(.orbitBody).lineLimit(1)
                } else {
                    Text(value).font(concealed ? .system(size: 13, design: .monospaced) : .orbitBody).textSelection(.enabled).lineLimit(3)
                }
            }
            Spacer()
            if concealed {
                IconButton(symbol: revealed ? "eye.slash" : "eye", help: revealed ? "Hide" : "Reveal", action: onReveal)
            }
            IconButton(symbol: "doc.on.doc", help: "Copy") { Vault.shared.copy(value, what: label) }
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, Space.standard).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Editor

private struct ItemEditor: View {
    @State var item: VaultItem
    let onDone: (VaultItem?) -> Void
    @State private var password = ""
    @State private var urlsText = ""
    @State private var tagsText = ""
    @State private var showGenerator = false
    @State private var scanning = false
    @State private var scanNote: String?

    init(item: VaultItem, onDone: @escaping (VaultItem?) -> Void) {
        _item = State(initialValue: item)
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.related) {
                    HStack(spacing: Space.related) {
                        ItemIcon(item: item, size: 40)
                        TextField("Title", text: $item.title).textFieldStyle(.plain).font(.orbitTitle)
                    }
                    switch item.kind {
                    case .login: login
                    case .card: card
                    case .identity: identity
                    case .note: EmptyView()
                    }
                    labelled("Notes") {
                        TextEditor(text: $item.notes).font(.orbitBody).scrollContentBackground(.hidden)
                            .frame(minHeight: item.kind == .note ? 200 : 70)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                    }
                    customFields
                    labelled("Tags") { input("Comma separated", $tagsText) }
                }
                .padding(Space.group)
            }
            Divider().opacity(0.6)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Save") { save() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.standard).frame(height: 52)
        }
        .onAppear {
            password = item.password
            urlsText = item.urls.joined(separator: "\n")
            tagsText = item.tags.joined(separator: ", ")
        }
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            labelled("Username") { input("name@example.com", $item.username) }
            labelled("Password") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        input("Password", $password, mono: true)
                        IconButton(symbol: "wand.and.stars", help: "Generate") { showGenerator.toggle() }
                            .popover(isPresented: $showGenerator, arrowEdge: .bottom) {
                                GeneratorView { new in password = new; showGenerator = false }.padding(Space.standard).frame(width: 380)
                            }
                    }
                    StrengthBar(password: password)
                }
            }
            labelled("Websites") {
                TextEditor(text: $urlsText).font(.orbitBody).scrollContentBackground(.hidden)
                    .frame(height: 46).padding(6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
            }
            labelled("One-time code") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        input("otpauth://… or the setup key", $item.totp, mono: true)
                        Button {
                            scan()
                        } label: { Label(scanning ? "Looking…" : "Find QR on Screen", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(PillButtonStyle(prominent: false)).disabled(scanning)
                    }
                    if TOTP(item.totp) != nil { TOTPView(totp: item.totp, compact: true) }
                    if let scanNote { Text(scanNote).font(.orbitCaption).foregroundStyle(Palette.inkSecondary) }
                }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            labelled("Cardholder") { input("Name on card", $item.cardholder) }
            labelled("Number") { input("1234 5678 9012 3456", $item.cardNumber, mono: true) }
            HStack(spacing: Space.related) {
                labelled("Expires") { input("MM/YY", $item.cardExpiry) }
                labelled("Security code") { input("CVC", $item.cardCode, mono: true) }
                labelled("PIN") { input("PIN", $item.cardPIN, mono: true) }
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.related) {
                labelled("First name") { input("", $item.firstName) }
                labelled("Last name") { input("", $item.lastName) }
            }
            labelled("Email") { input("", $item.email) }
            labelled("Phone") { input("", $item.phone) }
            labelled("Address") { input("", $item.address) }
            labelled("Company") { input("", $item.company) }
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($item.fields) { $f in
                HStack(spacing: 6) {
                    input("Label", $f.label).frame(width: 130)
                    input("Value", $f.value, mono: f.concealed)
                    IconButton(symbol: f.concealed ? "eye.slash" : "eye", help: "Hidden") { f.concealed.toggle() }
                    IconButton(symbol: "minus.circle", help: "Remove") { item.fields.removeAll { $0.id == f.id } }
                }
            }
            Button { item.fields.append(.init(label: "", value: "")) } label: { Label("Add Field", systemImage: "plus") }
                .buttonStyle(.plain).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func labelled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
            content()
        }
    }

    private func input(_ placeholder: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        TextField(placeholder.loc, text: text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 13, design: .monospaced) : .orbitBody)
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
    }

    private func scan() {
        scanning = true
        scanNote = nil
        Task {
            if let found = await TOTPScanner.scanScreens() {
                item.totp = found
                scanNote = "Found a code on screen.".loc
            } else {
                scanNote = "No setup QR code on screen. Open the site’s two-factor setup page, then try again.".loc
            }
            scanning = false
        }
    }

    private func save() {
        item.setPassword(password)
        item.urls = urlsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        item.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        item.totp = item.totp.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.title.isEmpty { item.title = item.hosts.first ?? item.kind.title.loc }
        item.fields.removeAll { $0.label.isEmpty && $0.value.isEmpty }
        onDone(item)
    }
}

// MARK: - Watchtower

private struct WatchtowerView: View {
    private var vault: Vault { Vault.shared }

    var body: some View {
        let issues = vault.issues
        ScrollView {
            VStack(alignment: .leading, spacing: Space.standard) {
                let total = Set(issues.values.flatMap { $0.map(\.id) }).count
                let logins = vault.items.filter { $0.kind == .login }.count
                HStack(spacing: Space.related) {
                    Image(systemName: total == 0 ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(total == 0 ? Palette.ink : Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(total == 0 ? "Everything looks good" : "%ld items need attention".loc(total)).font(.orbitTitle)
                        Text("Checked %ld logins on this Mac.".loc(logins)).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    if vault.breachCheck {
                        Button(vault.checkingBreaches ? "Checking…" : "Check Breaches") { vault.checkBreaches() }
                            .buttonStyle(PillButtonStyle(prominent: false)).disabled(vault.checkingBreaches)
                    }
                }
                if !vault.breachCheck {
                    SettingsRow(title: "Check for breached passwords", subtitle: "Uses Have I Been Pwned. Only the first 5 characters of each password’s hash leave this Mac — never the password.", symbol: "exclamationmark.shield") {
                        Toggle("", isOn: Binding(get: { vault.breachCheck }, set: { vault.breachCheck = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.page))
                }
                ForEach(Watchtower.Issue.allCases) { issue in
                    let list = issues[issue] ?? []
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: issue.symbol).foregroundStyle(Palette.accent)
                                Text(issue.title.loc).font(.orbitSection)
                                Text("\(list.count)").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                            }
                            Text(issue.detail.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                            VStack(spacing: 0) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                                    if i > 0 { RowDivider() }
                                    Button {
                                        PasswordsUI.shared.select(item)
                                    } label: {
                                        HStack(spacing: Space.compact) {
                                            ItemIcon(item: item, size: 26)
                                            Text(item.title).font(.orbitBody)
                                            Text(item.subtitle).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.page))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(Space.group)
        }
    }
}

// MARK: - Header generator

private struct GeneratorButton: View {
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: { Label("Generator", systemImage: "wand.and.stars") }
            .buttonStyle(PillButtonStyle(prominent: false))
            .popover(isPresented: $open, arrowEdge: .bottom) { GeneratorView().padding(Space.standard).frame(width: 380) }
    }
}

// MARK: - Settings

private struct PasswordsSettings: View {
    private var vault: Vault { Vault.shared }
    @State private var importError: String?
    @State private var exportPassword = ""
    @State private var showExport = false
    @State private var showChange = false
    @State private var confirmErase = false
    @State private var importPrompt: ImportRequest?
    @State private var importPassword = ""
    @State private var showImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            SettingsGroup(title: "Unlock", footer: "Touch ID is checked by the Secure Enclave. Face unlock is checked by Orbit and is less strict — use it only on a Mac only you use.") {
                SettingsRow(title: "Unlock with Touch ID", subtitle: BiometricUnlock.isAvailable ? "Or a paired Apple Watch." : "This Mac has no Touch ID set up.", symbol: "touchid") {
                    Toggle("", isOn: Binding(get: { vault.touchIDEnabled }, set: { vault.setTouchID($0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(!BiometricUnlock.isAvailable)
                }
                RowDivider()
                SettingsRow(title: "Unlock with your face", subtitle: FaceMatcher.unavailable == nil ? "Uses the face you set up in App Lock." : "Set up your face in App Lock first.", symbol: "faceid") {
                    Toggle("", isOn: Binding(get: { vault.faceEnabled }, set: { vault.setFace($0) }))
                        .toggleStyle(.switch).labelsHidden().disabled(FaceMatcher.unavailable != nil && !vault.faceEnabled)
                }
                RowDivider()
                SettingsRow(title: "Ask for the Master Password every two weeks", subtitle: "So you don’t forget it while using Touch ID.", symbol: "calendar.badge.clock") {
                    Toggle("", isOn: Binding(get: { vault.rePromptMaster }, set: { vault.rePromptMaster = $0 })).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: "Locking") {
                SettingsRow(title: "Lock after", subtitle: "Minutes without touching the Mac. It also locks when Orbit quits.", symbol: "timer") {
                    Picker("", selection: Binding(get: { vault.autoLockMinutes }, set: { vault.autoLockMinutes = $0 })) {
                        Text("1 min").tag(1); Text("5 min").tag(5); Text("10 min").tag(10)
                        Text("30 min").tag(30); Text("1 hour").tag(60); Text("Never").tag(0)
                    }
                    .labelsHidden().frame(width: 110)
                }
                RowDivider()
                SettingsRow(title: "Lock when the Mac sleeps", symbol: "moon") {
                    Toggle("", isOn: Binding(get: { vault.lockOnSleep }, set: { vault.lockOnSleep = $0 })).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Lock when the screen locks", symbol: "lock.display") {
                    Toggle("", isOn: Binding(get: { vault.lockOnScreenLock }, set: { vault.lockOnScreenLock = $0 })).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Clear copied passwords", subtitle: "Marked so clipboard managers, including Orbit’s, don’t keep them.", symbol: "doc.on.clipboard") {
                    Picker("", selection: Binding(get: { vault.clearClipboardSeconds }, set: { vault.clearClipboardSeconds = $0 })) {
                        Text("After 30 s").tag(30); Text("After 90 s").tag(90); Text("After 3 min").tag(180); Text("Never").tag(0)
                    }
                    .labelsHidden().frame(width: 120)
                }
            }

            SettingsGroup(title: "Filling", footer: "Quick Access finds the username and password fields in the app in front and types into them. In a browser it checks the page’s address first, so a look-alike site doesn’t get your login.") {
                SettingsRow(title: "Press return after filling", subtitle: "Signs in right away.", symbol: "return") {
                    Toggle("", isOn: Binding(get: { vault.submitAfterFill }, set: { vault.submitAfterFill = $0 })).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Browser AutoFill menu", subtitle: "Appearing in Safari’s and Chrome’s password menu needs a paid Apple Developer account for this build. Quick Access works everywhere instead.", symbol: "rectangle.and.text.magnifyingglass") {
                    Text("Unavailable").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
            }

            SettingsGroup(title: "Import & Export") {
                SettingsRow(title: "Import", subtitle: "Finds your browsers, 1Password, Bitwarden and Apple Passwords on this Mac — pick one and choose what to bring in.", symbol: "square.and.arrow.down") {
                    HStack(spacing: 6) {
                        Button("Choose File…") { chooseImport() }.buttonStyle(PillButtonStyle(prominent: false))
                        Button("Import…") { showImport = true }.buttonStyle(PillButtonStyle())
                    }
                }
                if let importError {
                    Text(importError).font(.orbitCaption).foregroundStyle(Palette.accent).padding(.horizontal, Space.standard).padding(.bottom, 8)
                }
                RowDivider()
                SettingsRow(title: "Export (encrypted)", subtitle: "A file locked with a password you choose, to move to another Mac.", symbol: "square.and.arrow.up") {
                    Button("Export…") { showExport = true }.buttonStyle(PillButtonStyle(prominent: false))
                }
                RowDivider()
                SettingsRow(title: "Back Up Vault", subtitle: "A copy of the encrypted vault. Opening it needs your Emergency Kit.", symbol: "externaldrive") {
                    Button("Back Up…") { backUp() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            SettingsGroup(title: "Account") {
                SettingsRow(title: "Emergency Kit", subtitle: "A new PDF with your Secret Key.", symbol: "doc.text.magnifyingglass") {
                    Button("Save…") {
                        if let key = vault.secretKeyText() { EmergencyKit.save(secretKey: key, accountID: vault.accountID ?? "") }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                }
                RowDivider()
                SettingsRow(title: "Change Master Password", symbol: "key") {
                    Button("Change…") { showChange = true }.buttonStyle(PillButtonStyle(prominent: false))
                }
                RowDivider()
                SettingsRow(title: "Erase vault from this Mac", subtitle: "Deletes the vault and its keys here. Back up first if you want it elsewhere.", symbol: "trash") {
                    Button("Erase…") { confirmErase = true }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .sheet(isPresented: $showExport) { ExportSheet() }
        .sheet(isPresented: $showChange) { ChangePasswordSheet() }
        .sheet(isPresented: $showImport) { PasswordImportSheet() }
        .sheet(item: $importPrompt) { req in ImportPasswordSheet(url: req.url) { importPrompt = nil } }
        .alert("Erase the vault from this Mac?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { vault.eraseEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every item and the Secret Key are deleted from this Mac. Without a backup and the Emergency Kit, they’re gone.")
        }
    }

    private func chooseImport() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, UTType(filenameExtension: "1pux") ?? .data,
                                     UTType(filenameExtension: "orbitpasswords") ?? .data, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let items = try VaultImport.read(url)
            vault.merge(items)
            Toast.show("Imported %ld items".loc(items.count), symbol: "square.and.arrow.down.fill")
        } catch VaultImport.Failure.needsPassword {
            importPrompt = ImportRequest(url: url)
        } catch {
            importError = (error as? LocalizedError)?.errorDescription?.loc ?? "Couldn’t read that file.".loc
        }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orbit Passwords.orbitvault"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: vault.url, to: dest)
            Toast.show("Vault backed up", symbol: "externaldrive.fill.badge.checkmark")
        } catch {
            Toast.show("Couldn’t back up the vault", symbol: "exclamationmark.triangle.fill")
        }
    }
}

private struct ImportRequest: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            Text("Export Passwords").font(.orbitTitle)
            Text("Choose a password for the export file. It’s needed to import it again.").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            SecureField("Export password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Type it again", text: $confirm).textFieldStyle(.roundedBorder)
            StrengthBar(password: password)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Export…") { export() }.buttonStyle(PillButtonStyle())
                    .disabled(password.count < 8 || password != confirm)
            }
        }
        .padding(Space.group)
        .frame(width: 400)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orbit Passwords Export.orbitpasswords"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Vault.shared.export(password: password) else { return }
        try? data.write(to: url, options: .atomic)
        password = ""
        confirm = ""
        Toast.show("Exported", symbol: "square.and.arrow.up.fill")
        dismiss()
    }
}

private struct ImportPasswordSheet: View {
    let url: URL
    let onDone: () -> Void
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            Text("Import Orbit Export").font(.orbitTitle)
            SecureField("Export password", text: $password).textFieldStyle(.roundedBorder).onSubmit(run)
            if let error { Text(error).font(.orbitCaption).foregroundStyle(Palette.accent) }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(PillButtonStyle(prominent: false))
                Button("Import", action: run).buttonStyle(PillButtonStyle()).disabled(password.isEmpty)
            }
        }
        .padding(Space.group)
        .frame(width: 380)
    }

    private func run() {
        do {
            let items = try VaultImport.read(url, exportPassword: password)
            Vault.shared.merge(items)
            Toast.show("Imported %ld items".loc(items.count), symbol: "square.and.arrow.down.fill")
            onDone()
        } catch {
            self.error = "Wrong password for this export.".loc
        }
    }
}

private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            Text("Change Master Password").font(.orbitTitle)
            SecureField("Current Master Password", text: $current).textFieldStyle(.roundedBorder)
            SecureField("New Master Password", text: $new).textFieldStyle(.roundedBorder)
            StrengthBar(password: new)
            SecureField("Type it again", text: $confirm).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.orbitCaption).foregroundStyle(Palette.accent) }
            Text("Your Secret Key stays the same, so your Emergency Kit still works — just remember the new password.")
                .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Change") { change() }.buttonStyle(PillButtonStyle())
                    .disabled(current.isEmpty || new.count < 10 || new != confirm || PasswordStrength.level(new) < .fair || working)
            }
        }
        .padding(Space.group)
        .frame(width: 420)
    }

    private func change() {
        working = true
        Task {
            do {
                try await Vault.shared.changeMasterPassword(current: current, new: new)
                Toast.show("Master Password changed", symbol: "key.fill")
                dismiss()
            } catch {
                self.error = "The current Master Password isn’t right.".loc
            }
            working = false
        }
    }
}
