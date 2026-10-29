import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @Bindable var model: AppsModel
    @FocusState private var searchFocused: Bool
    private var catalog: AppsCatalog { .shared }

    var body: some View {
        GeometryReader { geo in
            let size = catalog.iconSize
            let cell = size + 44
            let gridWidth = min(geo.size.width - 160, max(cell * 5, 1180))
            let columns = max(4, Int(gridWidth / cell))
            ZStack {
                BehindWindowBlur().ignoresSafeArea()
                Color.black.opacity(0.32).ignoresSafeArea()
                // A click on the empty desktop around everything closes, like Launchpad.
                Color.clear.contentShape(Rectangle()).onTapGesture { AppsPanel.shared.hide() }

                VStack(spacing: 18) {
                    search
                    if catalog.showCategories, model.query.isEmpty, !model.categories.isEmpty {
                        categoryChips.frame(maxWidth: gridWidth)
                    }
                    grid(columns: columns, cell: cell, size: size)
                        .frame(maxWidth: gridWidth)
                    footer
                }
                .padding(.top, 64)
                .padding(.bottom, 28)
                .scaleEffect(model.shown ? 1 : 1.035)
                .opacity(model.shown ? 1 : 0)
                .blur(radius: model.info == nil ? 0 : 6)

                if let app = model.info {
                    Color.black.opacity(0.25).ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(duration: 0.25)) { model.info = nil } }
                    AppInfoCard(app: app) { withAnimation(.spring(duration: 0.25)) { model.info = nil } }
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                }
            }
            .onAppear { model.columns = columns }
            .onChange(of: columns) { model.columns = columns }
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: model.focusToken) { searchFocused = true }
    }

    // MARK: Search

    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search apps", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 440, height: 42)
        .glassEffect(.regular, in: Capsule())
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(title: "All", symbol: "square.grid.3x3", isOn: model.category == nil) {
                    withAnimation(.spring(duration: 0.3)) { model.category = nil }
                }
                ForEach(model.categories, id: \.self) { c in
                    CategoryChip(title: c.title, symbol: c.symbol, isOn: model.category == c) {
                        withAnimation(.spring(duration: 0.3)) { model.category = model.category == c ? nil : c }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Grid

    private func grid(columns: Int, cell: Double, size: Double) -> some View {
        let sections = model.sections
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if let title = section.title {
                                Text(title.loc.uppercased())
                                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(.leading, 10)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns), spacing: 6) {
                                ForEach(Array(section.apps.enumerated()), id: \.element.path) { i, app in
                                    let sel = AppsModel.Selection(section: section.id, path: app.path)
                                    AppCell(app: app, size: size, cell: cell, selected: model.selection == sel,
                                            running: catalog.running.contains(app.path), pinnedRow: section.pinned)
                                        .id(sel)
                                        // Icons cascade in on open.
                                        .scaleEffect(model.shown ? 1 : 0.82)
                                        .opacity(model.shown ? 1 : 0)
                                        .animation(.spring(duration: 0.42, bounce: 0.2).delay(model.shown ? Double(min(i, 48)) * 0.006 : 0),
                                                   value: model.shown)
                                        .onDrop(of: [.fileURL], delegate: PinDrop(target: section.pinned ? app.path : nil))
                                }
                            }
                        }
                        .onDrop(of: [.fileURL], delegate: PinDrop(target: nil, enabled: section.pinned))
                    }
                    if sections.allSatisfy(\.apps.isEmpty) { empty }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { AppsPanel.shared.hide() })
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) {
                guard let s = model.selection else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(s, anchor: nil) }
            }
            .onChange(of: model.query) { if let first = sections.first?.id { proxy.scrollTo(first, anchor: .top) } }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.square").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.4))
            Text("No apps match “%@”".loc(model.query)).font(.orbitSection).foregroundStyle(.white.opacity(0.85))
            Text("Try the English name, or the initials — ㅋㅋㅇㅌ finds 카카오톡.").font(.orbitCaption).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var footer: some View {
        HStack(spacing: Space.standard) {
            ShortcutHint(title: "Open", keys: ["↩"])
            ShortcutHint(title: "Show in Finder", keys: ["⌘", "↩"])
            ShortcutHint(title: "Pin", keys: ["⌘", "P"])
            ShortcutHint(title: "Info", keys: ["⌘", "I"])
            if catalog.showCategories { ShortcutHint(title: "Category", keys: ["⇥"]) }
        }
        .opacity(0.8)
    }
}

// MARK: - Cell

private struct AppCell: View {
    let app: AppsCatalog.App
    let size: Double
    let cell: Double
    let selected: Bool
    let running: Bool
    let pinnedRow: Bool
    @State private var hovering = false
    private var catalog: AppsCatalog { .shared }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: catalog.icon(app))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
                .scaleEffect(hovering ? 1.05 : 1)
                .animation(.spring(duration: 0.22, bounce: 0.35), value: hovering)
            Text(app.name)
                .font(.system(size: size < 64 ? 11 : 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: cell - 8)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            // Running, like the Dock's dot.
            Circle().fill(.white.opacity(running ? 0.85 : 0)).frame(width: 4, height: 4)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(width: cell)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(selected ? 0.13 : (hovering ? 0.05 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? Palette.accent.opacity(0.9) : .clear, lineWidth: 1.5))
        .overlay(alignment: .topTrailing) {
            if pinnedRow || catalog.isPinned(app), hovering {
                Image(systemName: "pin.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { AppsPanel.shared.reveal(app) } else { AppsPanel.shared.open(app) }
        }
        // Drag an app out to the Dock or a Finder window — or onto the Pinned row.
        .onDrag { NSItemProvider(object: app.url as NSURL) }
        .contextMenu { menu }
        .help(app.name)
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { AppsPanel.shared.open(app) }
        Button("Show in Finder") { AppsPanel.shared.reveal(app) }
        Button(catalog.isPinned(app) ? "Unpin" : "Pin to Top") {
            withAnimation(.spring(duration: 0.3)) { catalog.togglePin(app) }
        }
        Button("Get Info") { withAnimation(.spring(duration: 0.25)) { AppsPanel.shared.model.info = app } }
        if let runningApp = catalog.runningApp(app) {
            Divider()
            Button("Hide") { runningApp.hide() }
            Button("Quit") { runningApp.terminate() }
        }
        Divider()
        Button("Uninstall…") { AppsPanel.shared.uninstall(app) }
            .disabled(app.isSystem)
    }
}

/// Dropping an app (from the grid, or a Finder window) on the Pinned row pins it there.
private struct PinDrop: DropDelegate {
    /// The pinned app it lands in front of; nil = the end of the row.
    let target: String?
    var enabled = true

    func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? { enabled ? DropProposal(operation: .move) : nil }

    func performDrop(info: DropInfo) -> Bool {
        guard enabled, let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let path = url?.standardizedFileURL.path, path.hasSuffix(".app") else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let catalog = AppsCatalog.shared
                    guard let app = catalog.apps.first(where: { $0.path == path }) else { return }
                    withAnimation(.spring(duration: 0.3)) {
                        if !catalog.isPinned(app) { catalog.togglePin(app) }
                        if let target { catalog.movePin(path, before: target) }
                    }
                }
            }
        }
        return true
    }
}

private struct CategoryChip: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title.loc).font(.system(size: 12, weight: isOn ? .semibold : .medium))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(isOn ? Color.black : .white.opacity(0.85))
            .background(Capsule().fill(isOn ? Color.white : .white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Info

private struct AppInfoCard: View {
    let app: AppsCatalog.App
    let close: () -> Void
    @State private var size: Int64?
    private var catalog: AppsCatalog { .shared }

    private var info: [String: Any] { Bundle(path: app.path)?.infoDictionary ?? [:] }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: catalog.icon(app)).resizable().frame(width: 72, height: 72)
            VStack(spacing: 3) {
                Text(app.name).font(.orbitTitle)
                if app.bundleName != app.name { Text(app.bundleName).font(.orbitCaption).foregroundStyle(.secondary) }
            }
            VStack(spacing: 0) {
                row("Version", (info["CFBundleShortVersionString"] as? String) ?? "—")
                row("Category", app.category.title.loc)
                row("Size", size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                row("Bundle ID", app.bundleID ?? "—")
                row("Location", (app.path as NSString).deletingLastPathComponent)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
            HStack(spacing: 8) {
                Button("Show in Finder") { AppsPanel.shared.reveal(app) }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Open") { AppsPanel.shared.open(app) }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 380)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).padding(14) }
                .buttonStyle(.plain)
        }
        .task(id: app.path) {
            let path = app.path
            size = await Task.detached(priority: .utility) { Self.measure(path) }.value
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.loc).font(.orbitCaption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.orbitCaption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    nonisolated private static func measure(_ path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// The desktop, blurred, behind the panel.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
