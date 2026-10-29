import SwiftUI
import UniformTypeIdentifiers

/// Compress and extract — Keka, in plain words.
struct ArchivesPage: View {
    @Bindable private var archives = Archives.shared
    @State private var dropping = false
    @State private var previewEnabled: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Archives", subtitle: "Zip things up, or unpack any archive — ZIP, 7Z, RAR and more.")

            dropZone

            if !archives.jobs.isEmpty {
                SettingsGroup(title: "Recent") {
                    ForEach(Array(archives.jobs.enumerated()), id: \.element.id) { i, job in
                        if i > 0 { RowDivider() }
                        ArchiveJobRow(job: job).padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            SettingsGroup(title: "Open with Orbit") {
                SettingsRow(title: "Open archives with Orbit",
                            subtitle: archives.isDefaultHandler
                                ? "Double-click an archive and Orbit unpacks it right next to it."
                                : "Double-click an archive and Orbit unpacks it right next to it. Opens them now: %@".loc(archives.currentZipApp ?? "Archive Utility".loc),
                            symbol: "cursorarrow.click.2") {
                    Toggle("", isOn: Binding(get: { archives.isDefaultHandler }, set: { archives.setDefaultHandler($0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(archives.changingHandler)
                }
                RowDivider()
                SettingsRow(title: "Finder right-click menu", subtitle: servicesHint, symbol: "contextualmenu.and.cursorarrow") {
                    HStack(spacing: 8) {
                        if archives.servicesState == .ready {
                            Label("In the menu", systemImage: "checkmark.circle.fill").font(.orbitCaption).foregroundStyle(Palette.accent)
                        }
                        Button("Settings…") { archives.openServicesSettings() }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            SettingsGroup(title: "Compress", footer: compressFooter) {
                SettingsRow(title: "Format", subtitle: formatHint, symbol: "archivebox") {
                    ChipPicker(selection: $archives.format, options: ArchiveFormat.allCases.map { ($0, $0.title) })
                }
                RowDivider()
                SettingsRow(title: "Compression", subtitle: "Smaller files take a little longer.", symbol: "dial.medium") {
                    ChipPicker(selection: $archives.level, options: [(.fast, "Fast"), (.normal, "Normal"), (.best, "Smallest")])
                }
                RowDivider()
                SettingsRow(title: "Ask for a password", subtitle: "Lock the archive so only people with the password can open it.", symbol: "lock") {
                    Toggle("", isOn: $archives.askPassword).toggleStyle(.switch).labelsHidden()
                        .disabled(!archives.format.supportsPassword)
                }
                if archives.askPassword, archives.format == .zip {
                    RowDivider()
                    SettingsRow(title: "Lock type", subtitle: "AES-256 is safer, but Windows needs 7-Zip to open it. ZipCrypto opens in Windows’ own File Explorer.", symbol: "lock.shield") {
                        ChipPicker(selection: $archives.zipEncryption, options: [(.aes256, "AES-256"), (.zipCrypto, "ZipCrypto")])
                    }
                }
                if archives.format == .zip {
                    RowDivider()
                    SettingsRow(title: "Works on Windows", subtitle: "Korean names stay readable on Windows, and characters Windows won’t allow (: ? * | …) are swapped for look-alikes.", symbol: "pc") {
                        Toggle("", isOn: $archives.windowsCompatible).toggleStyle(.switch).labelsHidden()
                    }
                }
                RowDivider()
                SettingsRow(title: "Split into parts", subtitle: "For email or USB sticks with size limits. Orbit and other archive apps put them back together.", symbol: "square.split.2x1") {
                    ChipPicker(selection: $archives.splitMB, options: [(0, "Off"), (25, "25 MB"), (100, "100 MB"), (700, "700 MB"), (4000, "4 GB")])
                }
                RowDivider()
                SettingsRow(title: "Leave out system clutter", subtitle: "Skips .DS_Store, ._ files and Thumbs.db that nobody needs.", symbol: "sparkles") {
                    Toggle("", isOn: $archives.skipMacFiles).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Move the originals to the Trash", subtitle: "After the archive is made.", symbol: "trash") {
                    Toggle("", isOn: $archives.trashOriginals).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: "Extract", footer: "Opens ZIP, 7Z, RAR, TAR, GZ, BZ2, XZ, ZST, LZ, ISO, DMG, CAB, LHA, CPIO and split parts (.001).") {
                SettingsRow(title: "Show in Finder when done", symbol: "folder") {
                    Toggle("", isOn: $archives.revealAfter).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "File name language", subtitle: "Orbit figures out names from Windows ZIPs on its own. If they still look garbled, pick the language they were made in.", symbol: "character.textbox") {
                    Picker("", selection: $archives.nameEncoding) {
                        ForEach(NameEncoding.allCases, id: \.self) { Text($0.title.loc).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingsRow(title: "Move the archive to the Trash", subtitle: "After it’s unpacked.", symbol: "trash") {
                    Toggle("", isOn: $archives.trashArchiveAfter).toggleStyle(.switch).labelsHidden()
                }
            }

            SettingsGroup(title: "Quick Look", footer: "Turn on “Orbit Preview” under Quick Look in System Settings › General › Login Items & Extensions.") {
                SettingsRow(title: "Preview archives and folders",
                            subtitle: previewEnabled == false
                                ? "Off — press Space on a .zip or a folder to see what’s inside once it’s on."
                                : "Press Space on a .zip, .7z, .rar or a folder in Finder to see what’s inside, without unpacking.",
                            symbol: "eye") {
                    Button("Open Settings") { QuickLookExtension.openSettings() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: archives.jobs.count)
        .onAppear {
            archives.refreshHandlerState()
            archives.refreshServices()
            Task { previewEnabled = await QuickLookExtension.isEnabled() }
        }
    }

    private var servicesHint: String {
        switch archives.servicesState {
        case .disabled: "Turned off — in Settings, open Keyboard Shortcuts › Services and tick “Compress with Orbit” and “Extract with Orbit”."
        case .missing: "Not listed by macOS yet — it appears after Orbit is reopened."
        default: "Right-click files › Quick Actions › “Compress with Orbit” or “Extract with Orbit”."
        }
    }

    private var compressFooter: String? {
        if !archives.format.supportsPassword { return "Passwords work with ZIP and DMG." }
        if archives.askPassword, archives.format == .zip, archives.zipEncryption == .aes256 {
            return "To open it with Windows’ own File Explorer, pick ZipCrypto."
        }
        return nil
    }

    private var formatHint: String {
        switch archives.format {
        case .zip: "Opens anywhere — Mac, Windows, phones."
        case .sevenZip: "Smaller than ZIP. The other side needs an app that opens 7z."
        case .tarGz, .tarXz, .tarBz2: "For Linux and developers."
        case .dmg: "A Mac disk image — opens on any Mac."
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: dropping ? "arrow.down.circle.fill" : "archivebox")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(dropping ? Palette.accent : Palette.ink)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 4) {
                Text("Drop files here").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Files and folders get compressed · archives get unpacked").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            HStack(spacing: 8) {
                Button("Compress…") { archives.chooseAndCompress() }.buttonStyle(PillButtonStyle())
                Button("Extract…") { archives.chooseAndExtract() }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(dropping ? Palette.accent.opacity(0.08) : Palette.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropping ? Palette.accent : Palette.hairline, style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: dropping ? [] : [6, 5]))
        )
        .animation(.spring(duration: 0.25), value: dropping)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                }
                archives.handleDrop(urls)
            }
            return true
        }
    }
}
