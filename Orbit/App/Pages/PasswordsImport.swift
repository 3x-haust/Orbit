import AppKit
import SwiftUI

/// "Bring my passwords in": what Orbit found on this Mac, one click each, then a preview to pick from.
struct PasswordImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importer = PasswordImporter()
    @State private var bitwardenPath: String?
    @State private var bitwardenPassword = ""
    @State private var result: (added: Int, updated: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Passwords").font(.orbitTitle)
                    Text(importer.candidates.isEmpty
                         ? "Pick where your passwords are now. Orbit reads them on this Mac — nothing is uploaded."
                         : "Choose what to bring in. Logins you already have are left alone.")
                        .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
            }

            if let watching = importer.watching {
                WaitingCard(guided: watching) { importer.stopWatching() }
            } else if !importer.candidates.isEmpty {
                PreviewList(importer: importer)
            } else {
                sources
            }

            if let busy = importer.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
            }
            if let error = importer.error {
                Text(error).font(.orbitCaption).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !importer.candidates.isEmpty {
                    Button("Back") { importer.discard() }.buttonStyle(PillButtonStyle(prominent: false))
                }
                Spacer()
                Button("Close") { importer.stopWatching(); dismiss() }.buttonStyle(PillButtonStyle(prominent: false))
                if !importer.candidates.isEmpty {
                    Button("Import %ld".loc(importer.selectedCount)) { commit() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(importer.selectedCount == 0)
                }
            }
        }
        .padding(Space.group)
        .frame(width: 560)
        .frame(minHeight: 420, alignment: .top)
        .onAppear { importer.detect() }
        .onDisappear { importer.stopWatching() }
        .sheet(item: Binding(get: { bitwardenPath.map(PathBox.init) }, set: { bitwardenPath = $0?.path })) { box in
            BitwardenUnlockSheet(password: $bitwardenPassword) {
                importer.importBitwarden(box.path, masterPassword: bitwardenPassword)
                bitwardenPassword = ""
                bitwardenPath = nil
            } onCancel: {
                bitwardenPassword = ""
                bitwardenPath = nil
            }
        }
        .alert("Move the export file to the Trash?", isPresented: Binding(get: { result != nil && importer.exportFile != nil }, set: { if !$0 { importer.keepExport() } })) {
            Button("Move to Trash") { importer.trashExport(); finish() }
            Button("Keep It", role: .cancel) { importer.keepExport(); finish() }
        } message: {
            Text("It holds your passwords as plain text. Everything is safely in Orbit now.")
        }
    }

    // MARK: Sources

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.related) {
                if !importer.browsers.isEmpty || !importer.tools.isEmpty {
                    section("Found on this Mac")
                    VStack(spacing: 0) {
                        ForEach(Array((importer.browsers + importer.tools).enumerated()), id: \.element.id) { i, source in
                            if i > 0 { RowDivider() }
                            sourceRow(source)
                        }
                    }
                    .background(card)
                }
                section("Export from an app")
                VStack(spacing: 0) {
                    ForEach(Array(importer.guided.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { RowDivider() }
                        row(icon: PasswordImporter.icon(g.bundleIDs), symbol: "square.and.arrow.up", title: g.title,
                            subtitle: "Orbit opens it, you export, and the file is picked up by itself.") {
                            Button("Start") { importer.startGuided(g) }.buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                    RowDivider()
                    row(icon: nil, symbol: "doc", title: "A file", subtitle: "A CSV, .1pux or Bitwarden .json you already have.") {
                        Button("Choose File…") { chooseFile() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
                .background(card)
            }
        }
        .frame(maxHeight: 460)
        .disabled(importer.busy != nil)
    }

    @ViewBuilder private func sourceRow(_ source: PasswordImporter.Source) -> some View {
        switch source {
        case .browser(let profile, let count):
            let bundle = PasswordImporter.browserBundleIDs[profile.browser.name].map { [$0] } ?? []
            row(icon: PasswordImporter.icon(bundle), symbol: "globe", title: profile.browser.name,
                subtitle: count > 1 ? "Profile: %@".loc(Self.profileName(profile)) : "Saved passwords in this browser. macOS asks once to allow it.") {
                Button("Import") { importer.importBrowser(profile) }.buttonStyle(PillButtonStyle(prominent: false))
            }
        case .onePasswordCLI(let op):
            row(icon: PasswordImporter.icon(PasswordImporter.Guided.onePassword.bundleIDs), symbol: "key", title: "1Password",
                subtitle: "Through 1Password’s command-line tool. 1Password asks you to allow it.") {
                Button("Import") { importer.importOnePassword(op) }.buttonStyle(PillButtonStyle(prominent: false))
            }
        case .bitwardenCLI(let bw):
            row(icon: PasswordImporter.icon(PasswordImporter.Guided.bitwarden.bundleIDs), symbol: "shield", title: "Bitwarden",
                subtitle: "Through Bitwarden’s command-line tool, with your master password.") {
                Button("Import") { bitwardenPath = bw }.buttonStyle(PillButtonStyle(prominent: false))
            }
        case .guided: EmptyView()
        }
    }

    /// Chromium keeps the names people gave their profiles in "Local State".
    static func profileName(_ p: ChromiumImport.Profile) -> String {
        let dir = p.loginData.deletingLastPathComponent()
        let state = dir.deletingLastPathComponent().appendingPathComponent("Local State")
        if let data = try? Data(contentsOf: state),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any],
           let info = cache[dir.lastPathComponent] as? [String: Any],
           let name = info["name"] as? String, !name.isEmpty {
            return name
        }
        return p.name
    }

    private func row<A: View>(icon: NSImage?, symbol: String, title: String, subtitle: String, @ViewBuilder accessory: () -> A) -> some View {
        HStack(spacing: Space.related) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else {
                    Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.orbitBodyEmphasized)
                Text(subtitle.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(2)
            }
            Spacer(minLength: Space.related)
            accessory()
        }
        .padding(.horizontal, Space.standard)
        .padding(.vertical, 10)
    }

    private func section(_ title: String) -> some View {
        Text(title.loc).font(.orbitCaption.weight(.semibold)).foregroundStyle(Palette.inkSecondary).padding(.top, 4)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .json, .init(filenameExtension: "1pux") ?? .data, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importer.importFile(url, origin: url.lastPathComponent)
    }

    private func commit() {
        let r = importer.commit()
        result = r
        // With a plain-text export involved, the alert asks about it first; otherwise done.
        if importer.exportFile == nil { finish() }
    }

    private func finish() {
        guard let r = result else { return }
        Toast.show("Imported %ld items".loc(r.added + r.updated), symbol: "square.and.arrow.down.fill",
                   detail: r.updated > 0 ? "%ld passwords updated".loc(r.updated) : nil)
        result = nil
        dismiss()
    }
}

private struct PathBox: Identifiable {
    let path: String
    var id: String { path }
}

/// While Orbit waits for an export: the steps, and that it's watching.
private struct WaitingCard: View {
    let guided: PasswordImporter.Guided
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            HStack(spacing: Space.related) {
                if let icon = PasswordImporter.icon(guided.bundleIDs) {
                    Image(nsImage: icon).resizable().frame(width: 36, height: 36)
                }
                Text("Export from %@".loc(guided.title.loc)).font(.orbitBodyEmphasized)
            }
            ForEach(Array(guided.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)").font(.orbitCaption.weight(.bold)).frame(width: 18, height: 18)
                        .background(Circle().fill(Palette.raised))
                    Text(step.loc).font(.orbitBody)
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the export file in Downloads or on the Desktop…").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(Space.standard)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// Every item found, with a checkbox; ones already in the vault start unticked.
private struct PreviewList: View {
    @Bindable var importer: PasswordImporter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("%ld found".loc(importer.candidates.count)).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                let same = importer.candidates.filter { $0.status == .same }.count
                if same > 0 {
                    Text("· %ld already in Orbit".loc(same)).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Button("Select All") { setAll(true) }.buttonStyle(.plain).font(.orbitCaption).foregroundStyle(Palette.accent)
                Button("Select None") { setAll(false) }.buttonStyle(.plain).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($importer.candidates) { $c in
                        HStack(spacing: Space.related) {
                            Toggle("", isOn: $c.include).toggleStyle(.checkbox).labelsHidden()
                            Image(systemName: c.item.kind.symbol).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.item.title.isEmpty ? "Untitled".loc : c.item.title).font(.orbitBody).lineLimit(1)
                                Text(c.item.subtitle).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                            }
                            Spacer()
                            badge(c.status)
                            Text(c.origin).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                        }
                        .padding(.horizontal, Space.standard)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture { c.include.toggle() }
                        RowDivider()
                    }
                }
            }
            .frame(height: 300)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        }
    }

    @ViewBuilder private func badge(_ s: PasswordImporter.Candidate.Status) -> some View {
        switch s {
        case .new: EmptyView()
        case .update: tag("New password", Palette.accent)
        case .same: tag("Already in Orbit", Palette.inkSecondary)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text.loc).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func setAll(_ on: Bool) {
        for i in importer.candidates.indices { importer.candidates[i].include = on }
    }
}

private struct BitwardenUnlockSheet: View {
    @Binding var password: String
    let onUnlock: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.related) {
            Text("Unlock Bitwarden").font(.orbitTitle)
            Text("Your Bitwarden master password goes only to Bitwarden’s own tool, and Orbit locks it again afterwards.")
                .font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            SecureField("Master password", text: $password).textFieldStyle(.roundedBorder).onSubmit { if !password.isEmpty { onUnlock() } }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(PillButtonStyle(prominent: false))
                Button("Unlock", action: onUnlock).buttonStyle(PillButtonStyle()).disabled(password.isEmpty)
            }
        }
        .padding(Space.group)
        .frame(width: 380)
    }
}
