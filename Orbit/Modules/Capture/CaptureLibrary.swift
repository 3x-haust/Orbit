import AVFoundation
import AppKit
import ImageIO
import Observation
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Every recent screenshot and recording in one panel: drag one into another app to attach it, copy,
/// edit, Quick Look, show in Finder or delete.
@MainActor @Observable
final class CaptureLibrary: NSObject {
    static let shared = CaptureLibrary()

    struct Item: Identifiable, Hashable {
        let url: URL
        let date: Date
        var id: URL { url }
        var ext: String { url.pathExtension.lowercased() }
        var isVideo: Bool { ["mp4", "mov", "m4v"].contains(ext) }
        var isGIF: Bool { ext == "gif" }
        var isImage: Bool { !isVideo }
    }

    enum Filter: String, CaseIterable { case all, screenshots, recordings }

    private(set) var items: [Item] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    var filter: Filter = .all
    var selection: URL?
    /// Pictures picked (⌘-click) to join into one, in the order picked.
    var picked: [URL] = []

    var shown: [Item] {
        switch filter {
        case .all: items
        case .screenshots: items.filter { !$0.isVideo }
        case .recordings: items.filter(\.isVideo)
        }
    }

    var isVisible: Bool { panel.isVisible }

    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.level = .floating
        p.setContent(CaptureLibraryView(library: self))
        p.onEscape = { [weak self] in
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil); return true }
            self?.hide()
            return true
        }
        return p
    }()
    @ObservationIgnored private var keys: Any?

    static let size = CGSize(width: 560, height: 600)

    func toggle() { isVisible ? hide() : show() }

    func show() {
        reload()
        guard !isVisible else { panel.makeKeyAndOrderFront(nil); return }
        let screen = NSScreen.active.visibleFrame
        panel.present(at: NSRect(x: screen.midX - Self.size.width / 2, y: screen.midY - Self.size.height / 2,
                                 width: Self.size.width, height: Self.size.height))
        installKeys()
    }

    func hide() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        panel.dismiss()
    }

    // MARK: Loading

    /// Orbit's capture folder, plus the save folder when it's somewhere else.
    private var folders: [URL] {
        var dirs = [CaptureService.dir]
        if let saved = Pref.defaults.string(forKey: Pref.captureSaveFolder) {
            let url = URL(fileURLWithPath: saved)
            if url.standardizedFileURL != CaptureService.dir.standardizedFileURL { dirs.append(url) }
        }
        return dirs
    }

    func reload() {
        let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mp4", "mov", "m4v"]
        var seen = Set<String>()
        var found: [Item] = []
        for dir in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
            for url in files where kinds.contains(url.pathExtension.lowercased()) {
                // The save folder is often the Desktop: only Orbit's own files from there.
                if dir != CaptureService.dir, !url.lastPathComponent.hasPrefix("Orbit") { continue }
                // A capture saved to the folder is the same picture as the one Orbit keeps.
                guard seen.insert(url.lastPathComponent).inserted else { continue }
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                found.append(Item(url: url, date: values?.creationDate ?? values?.contentModificationDate ?? .distantPast))
            }
        }
        items = Array(found.sorted { $0.date > $1.date }.prefix(200))
        if let selection, !items.contains(where: { $0.url == selection }) { self.selection = nil }
    }

    func thumbnail(for item: Item) -> NSImage? {
        if let cached = thumbnails[item.url] { return cached }
        let url = item.url
        Task {
            let image: NSImage? = item.isVideo
                ? await VideoTools.thumbnail(url, scale: 2)
                : await Task.detached(priority: .utility) { Self.imageThumbnail(url) }.value
            if let image { thumbnails[url] = image }
        }
        return nil
    }

    private nonisolated static func imageThumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }

    // MARK: Actions

    func edit(_ item: Item) {
        if item.isVideo {
            hide()
            VideoEditorWindow.open(item.url)
        } else if item.isGIF {
            VideoTools.open(item.url)
        } else if let image = NSImage(contentsOf: item.url) {
            hide()
            EditorWindow.open(image: image, fileURL: item.url)
        }
    }

    func togglePick(_ item: Item) {
        guard item.isImage, !item.isGIF else { return }
        withAnimation(Motion.hover) {
            if let i = picked.firstIndex(of: item.url) { picked.remove(at: i) } else { picked.append(item.url) }
        }
    }

    /// Joins the picked pictures and opens the result in the editor.
    func combinePicked(axis: EditorModel.Axis) {
        let images = picked.compactMap { NSImage(contentsOf: $0) }
        guard images.count >= 2, let joined = EditorModel.join(images, axis: axis, alignment: .center, gap: 16) else { return }
        picked = []
        hide()
        EditorWindow.open(image: joined, fileURL: nil)
    }

    func copy(_ item: Item) {
        NSPasteboard.general.clearContents()
        if item.isImage, !item.isGIF, let image = NSImage(contentsOf: item.url) {
            // The picture and the file, so it pastes into chats as an image and into Finder as a file.
            NSPasteboard.general.writeObjects([image, item.url as NSURL])
        } else {
            NSPasteboard.general.writeObjects([item.url as NSURL])
        }
        ClipboardStore.shared.markOwnWrite()
        Toast.show("Copied")
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func pin(_ item: Item) {
        guard item.isImage, let image = NSImage(contentsOf: item.url) else { return }
        PinWindow.pin(image)
    }

    func delete(_ item: Item) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            Toast.show("Couldn’t move it to the Trash", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
            return
        }
        if let capture = CaptureService.shared.recent.first(where: { $0.fileURL == item.url }) { CaptureService.shared.remove(capture) }
        let index = shown.firstIndex(of: item)
        withAnimation(Motion.reflow) {
            items.removeAll { $0.url == item.url }
            thumbnails[item.url] = nil
        }
        if selection == item.url {
            let rest = shown
            selection = index.flatMap { rest.isEmpty ? nil : rest[min($0, rest.count - 1)].url }
        }
        Toast.show("Moved to Trash", symbol: "trash")
    }

    func provider(for item: Item) -> NSItemProvider {
        NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL)
    }

    // MARK: Keyboard and Quick Look

    private var selected: Item? { selection.flatMap { url in items.first { $0.url == url } } }

    private func installKeys() {
        if let keys { NSEvent.removeMonitor(keys) }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel || event.window is QLPreviewPanel else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.contains(.command) {
                if chars == "c", let item = self.selected { self.copy(item); return nil }
                if event.keyCode == 51, let item = self.selected { self.delete(item); return nil }
                return event
            }
            switch event.keyCode {
            case 49: self.quickLook(); return nil
            case 36, 76: if let item = self.selected { self.edit(item) }; return nil
            case 51, 117: if let item = self.selected { self.delete(item) }; return nil
            case 123, 124, 125, 126: self.moveSelection(event.keyCode); return nil
            default: return event
            }
        }
    }

    private func moveSelection(_ key: UInt16) {
        let list = shown
        guard !list.isEmpty else { return }
        let columns = CaptureLibraryView.columns
        let current = selection.flatMap { url in list.firstIndex { $0.url == url } }
        var next = current ?? 0
        if current != nil {
            switch key {
            case 123: next -= 1
            case 124: next += 1
            case 125: next += columns
            default: next -= columns
            }
        }
        selection = list[min(max(0, next), list.count - 1)].url
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    func quickLook() {
        let ql = QLPreviewPanel.shared()!
        if ql.isVisible { ql.orderOut(nil); return }
        guard selected != nil else { return }
        ql.dataSource = self
        ql.reloadData()
        ql.makeKeyAndOrderFront(nil)
    }
}

extension CaptureLibrary: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { selected == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { selected?.url as NSURL? }
    }
}

// MARK: - Views

struct CaptureLibraryView: View {
    @Bindable var library: CaptureLibrary
    static let columns = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if library.shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.inkSecondary)
                    Text("No captures yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Screenshots and recordings you take show up here.").font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: Self.columns), spacing: 14) {
                        ForEach(library.shown) { item in
                            LibraryTile(library: library, item: item, selected: library.selection == item.url,
                                        pick: library.picked.firstIndex(of: item.url).map { $0 + 1 })
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.automatic)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer
        }
        .frame(width: CaptureLibrary.size.width, height: CaptureLibrary.size.height)
        .focusEffectDisabled()
        .modifier(PanelShell())
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("Recent Captures").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
            Spacer()
            HStack(spacing: 2) {
                ForEach(CaptureLibrary.Filter.allCases, id: \.self) { f in
                    Button { withAnimation(Motion.reflow) { library.filter = f } } label: {
                        Text(Self.title(f).loc)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(library.filter == f ? Palette.canvas : Palette.inkSecondary)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(library.filter == f ? Palette.ink : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Palette.raised))
            Button { library.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                    .frame(width: 22, height: 22).background(Circle().fill(Palette.raised))
            }
            .buttonStyle(.plain)
            .hoverHint("Close · Esc".loc)
        }
        .padding(.horizontal, 16).frame(height: 52)
        .background(WindowDragArea())
    }

    @ViewBuilder private var footer: some View {
        if library.picked.isEmpty { hints } else { combineBar }
    }

    private var combineBar: some View {
        HStack(spacing: 8) {
            Text(library.picked.count == 1 ? "Pick one more to combine".loc : "%ld picked".loc(library.picked.count))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            Button("Clear") { withAnimation(Motion.hover) { library.picked = [] } }.controlSize(.small)
            Button { library.combinePicked(axis: .horizontal) } label: { Label("Side by Side", systemImage: "rectangle.split.2x1") }
                .controlSize(.small).disabled(library.picked.count < 2)
            Button { library.combinePicked(axis: .vertical) } label: { Label("Stacked", systemImage: "rectangle.split.1x2") }
                .controlSize(.small).buttonStyle(.borderedProminent).disabled(library.picked.count < 2)
        }
        .padding(.horizontal, 16).frame(height: 38)
    }

    private var hints: some View {
        HStack(spacing: 8) {
            Text("Drag into any app to attach · ⌘-click to combine · ↩ to edit")
                .font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            Spacer()
            Button { NSWorkspace.shared.open(CaptureService.dir) } label: {
                Label("Open Folder", systemImage: "folder").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            .hoverHint("Open the captures folder in Finder".loc, below: false)
        }
        .padding(.horizontal, 16).frame(height: 38)
    }

    private static func title(_ f: CaptureLibrary.Filter) -> String {
        switch f {
        case .all: "All"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        }
    }
}

private struct LibraryTile: View {
    let library: CaptureLibrary
    let item: CaptureLibrary.Item
    let selected: Bool
    var pick: Int?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // The picture fills a fixed tile; on its own an aspect-fill image takes its natural
                // width and spills over the neighbouring tiles.
                Rectangle().fill(Palette.raised)
                    .frame(maxWidth: .infinity).frame(height: 104)
                    .overlay {
                        if let image = library.thumbnail(for: item) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipped()
                if item.isVideo || item.isGIF {
                    badge
                }
                if hovering {
                    Rectangle().fill(.black.opacity(0.28)).allowsHitTesting(false)
                    actions.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected || pick != nil ? Palette.accent : Palette.hairline, lineWidth: selected || pick != nil ? 2.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onDrag {
                library.selection = item.url
                return library.provider(for: item)
            }
            .onTapGesture(count: 2) { library.edit(item) }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) { library.togglePick(item) } else { library.selection = item.url }
            }
            .overlay(alignment: .topLeading) {
                if let pick {
                    Text("\(pick)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(Palette.accent))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(6)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .contextMenu { menu }

            Text(item.date.orbitRelative).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }

    private var badge: some View {
        Text(item.isGIF ? "GIF" : (VideoTools.durationText(item.url) ?? "Video".loc))
            .font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(.black.opacity(0.6)))
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            TileButton(symbol: item.isVideo ? "scissors" : (item.isGIF ? "play.fill" : "pencil.tip.crop.circle"),
                       hint: item.isVideo ? "Trim & Edit" : (item.isGIF ? "Open" : "Edit")) { library.edit(item) }
            TileButton(symbol: "doc.on.doc", hint: "Copy") { library.copy(item) }
            TileButton(symbol: "eye", hint: "Quick Look") { library.selection = item.url; library.quickLook() }
            TileButton(symbol: "folder", hint: "Show in Finder") { library.reveal(item) }
            TileButton(symbol: "trash", hint: "Move to Trash") { library.delete(item) }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(item.isVideo ? "Trim & Edit" : (item.isGIF ? "Open" : "Edit")) { library.edit(item) }
        Button("Copy") { library.copy(item) }
        Button("Quick Look") { library.selection = item.url; library.quickLook() }
        if item.isImage, !item.isGIF {
            Button("Pin to Screen") { library.pin(item) }
            Button(pick == nil ? "Pick to Combine" : "Unpick") { library.togglePick(item) }
        }
        Button("Show in Finder") { library.reveal(item) }
        Divider()
        Button("Move to Trash") { library.delete(item) }
    }
}

private struct TileButton: View {
    let symbol: String
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .hoverHint(hint.loc)
        .accessibilityLabel(hint.loc)
    }
}
