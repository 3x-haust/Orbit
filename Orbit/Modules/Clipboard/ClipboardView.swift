import SwiftUI
import UniformTypeIdentifiers

struct ClipboardView: View {
    @Bindable var model: ClipboardViewModel
    let onPaste: (ClipItem, Bool) -> Void
    @FocusState private var searchFocused: Bool
    private var store: ClipboardStore { .shared }

    var body: some View {
        let results = model.results
        VStack(spacing: 0) {
            toolbar(count: results.count)
            Divider().opacity(0.5)
            if results.isEmpty {
                empty
            } else {
                cards(results)
            }
        }
        .panelShell()
        .onChange(of: model.focusToken) { searchFocused = true }
        .onAppear { searchFocused = true }
    }

    private func toolbar(count: Int) -> some View {
        HStack(spacing: Space.related) {
            HStack(spacing: Space.compact) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.orbitBody)
                    .focused($searchFocused)
            }
            .frame(width: 220)

            HStack(spacing: Space.tight + 2) {
                Chip(title: "All", isOn: model.filter == .all) { model.filter = .all }
                Chip(title: "Pinned", symbol: "pin.fill", isOn: model.filter == .pinned) { model.filter = .pinned }
                ForEach(ClipItem.Kind.allCases, id: \.self) { kind in
                    Chip(title: kind.title, isOn: model.filter == .kind(kind)) { model.filter = .kind(kind) }
                }
            }

            Spacer(minLength: Space.standard)

            if store.paused {
                Button { store.resume() } label: {
                    Label("Paused", systemImage: "pause.circle.fill").font(.orbitCaption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .help("Clipboard recording is paused. Click to resume.")
            }

            HStack(spacing: Space.standard) {
                ShortcutHint(title: "Paste", keys: ["↩"], emphasized: true)
                ShortcutHint(title: "Plain", keys: ["⇧", "↩"])
                ShortcutHint(title: "Pin", keys: ["⌘", "P"])
                ShortcutHint(title: "Filter", keys: ["↑", "↓"])
            }
        }
        .padding(.horizontal, Space.standard)
        .frame(height: 44)
    }

    private func cards(_ results: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Space.related) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, selected: index == model.selection)
                            .id(item.id)
                            // One click pastes, like picking from a menu; arrows + ↩ still work from the keyboard.
                            .onTapGesture {
                                model.selection = index
                                onPaste(item, false)
                            }
                            .contextMenu { menu(for: item) }
                            .onDrag { provider(for: item) }
                    }
                }
                .padding(.horizontal, Space.standard)
                .padding(.vertical, Space.related)
            }
            .onChange(of: model.selection) { _, new in
                guard results.indices.contains(new) else { return }
                proxy.scrollTo(results[new].id, anchor: .center)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Space.compact) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "Nothing here yet".loc : "No matches for “%@”".loc(model.query))
                .font(.orbitSection)
            Text(model.query.isEmpty ? "Anything you copy will appear here — text, links, images and files." : "Try a different word, or press ↓ to change the filter.")
                .font(.orbitCaption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for item: ClipItem) -> some View {
        Button("Paste") { onPaste(item, false) }
        Button("Paste as Plain Text") { onPaste(item, true) }
        Button("Copy") { store.copy(item); Toast.show("Copied") }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { store.togglePin(item) }
        if item.kind == .link, let url = URL(string: item.text ?? "") {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file, let path = item.filePaths?.first {
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        }
        if item.kind == .image, let url = item.imageURL, let image = store.image(for: item) {
            Button("Annotate") { ClipboardPanel.shared.hide(); EditorWindow.open(image: image, fileURL: url) }
            Button("Pin to Screen") { ClipboardPanel.shared.hide(); PinWindow.pin(image) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item) }
    }

    private func provider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .image: return item.imageURL.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
        case .file: return item.filePaths?.first.flatMap { NSItemProvider(contentsOf: URL(fileURLWithPath: $0)) } ?? NSItemProvider()
        default: return NSItemProvider(object: (item.text ?? "") as NSString)
        }
    }
}

struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .frame(width: Size.card.width, height: Size.card.height)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(selected ? Palette.accent : (hovering ? Palette.ink.opacity(0.2) : Palette.hairline),
                              lineWidth: selected ? 2 : 0.5)
        }
        .shadow(color: .black.opacity(selected ? 0.18 : 0.08), radius: selected ? 10 : 4, y: 2)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind.title): \(item.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: Space.compact) {
            AppIcon(bundleID: item.appBundleID, fallback: item.kind.symbol)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.kind.title.loc).font(.orbitCaption.weight(.semibold))
                Text(item.appName ?? "Unknown app".loc).font(.orbitMicro).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
            }
            if index < 9 {
                KeyCap(label: "⌘\(index + 1)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Palette.raised.opacity(0.6))
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.text ?? "")
                .font(item.looksLikeCode ? .system(size: 11, design: .monospaced) : .orbitBody)
                .lineLimit(item.looksLikeCode ? 9 : 7)
                .foregroundStyle(.primary.opacity(0.9))
                .padding(10)
        case .link:
            VStack(alignment: .leading, spacing: Space.tight) {
                Image(systemName: "globe").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Text(URL(string: item.text ?? "")?.host() ?? "").font(.orbitBodyEmphasized).lineLimit(1)
                Text(item.text ?? "").font(.orbitCaption).foregroundStyle(.secondary).lineLimit(3)
            }
            .padding(10)
        case .image:
            if let image = ClipboardStore.shared.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(Checkerboard())
            }
        case .file:
            VStack(spacing: Space.compact) {
                if let path = item.filePaths?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable().frame(width: 64, height: 64)
                }
                Text(item.title).font(.orbitBody).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
        case .color:
            ZStack(alignment: .bottomLeading) {
                Color(nsColor: item.color ?? .gray)
                Text(item.text ?? "")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(item.footnote).lineLimit(1)
            Spacer(minLength: Space.compact)
            Text(item.date.orbitRelative)
        }
        .font(.orbitMicro.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

struct AppIcon: View {
    let bundleID: String?
    var fallback = "app"
    var size: CGFloat = 20

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = icon {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: fallback).font(.system(size: size * 0.6)).frame(width: size, height: size)
        }
    }

    private var icon: NSImage? {
        guard let bundleID else { return nil }
        if let cached = Self.cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.cache[bundleID] = image
        return image
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}
