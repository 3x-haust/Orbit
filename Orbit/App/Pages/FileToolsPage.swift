import SwiftUI
import UniformTypeIdentifiers

/// Convert and edit files where they are: drag, press Shift, drop on what you want.
struct FileToolsPage: View {
    @AppStorage(FileTools.enabledKey) private var enabled = true
    @State private var dropping = false
    private var permissions: Permissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "File Tools", subtitle: "Convert and edit pictures, PDFs, documents, video and audio right where you drag them.")

            dropZone

            SettingsGroup(title: "Drag and press Shift",
                          footer: "Everything runs on this Mac. Originals stay as they are — every result is a new file beside them.") {
                SettingsRow(title: "Shift opens the file ring",
                            subtitle: "Drag files anywhere and press Shift: the ring opens under the pointer. Press Shift again for Tools, then drop on what you want.",
                            symbol: "shift") {
                    Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                        .onChange(of: enabled) { FileTools.shared.start() }
                }
                if enabled, !permissions.accessibility {
                    RowDivider()
                    SettingsRow(title: "Allow Accessibility", subtitle: "Needed to notice Shift while you drag from Finder and other apps.", symbol: "hand.raised") {
                        Button("Allow…") { permissions.requestAccessibility() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
            }

            SettingsGroup(title: "What it can do") {
                ForEach(Array(Self.kinds.enumerated()), id: \.offset) { index, kind in
                    if index > 0 { RowDivider() }
                    SettingsRow(title: kind.title, subtitle: kind.detail, symbol: kind.symbol) { EmptyView() }
                }
            }
        }
    }

    private static let kinds: [(title: String, detail: String, symbol: String)] = [
        ("Pictures", "Convert to JPG, PNG, HEIC, TIFF, BMP or one PDF. Crop, add a background, compress, remove metadata, redact or annotate.", "photo"),
        ("PDF", "Convert to Word, JPG, PNG, RTF or plain text. Compress, split into pages, or merge several into one.", "doc.richtext"),
        ("Documents", "Word, RTF, text, HTML and OpenDocument to PDF or to each other.", "doc.text"),
        ("Video", "Convert to MP4, MOV or GIF, or take out the sound as M4A. Compress or mute.", "film"),
        ("Audio", "Convert between M4A, WAV and AIFF.", "waveform"),
    ]

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: dropping ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(dropping ? Palette.accent : Palette.ink)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 4) {
                Text("Drop files here").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Pick a format or a tool from the ring").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            Button("Choose Files…") { FileTools.shared.choose() }.buttonStyle(PillButtonStyle())
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
                for provider in providers {
                    if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                FileTools.shared.offer(urls)
            }
            return true
        }
    }
}
