import SwiftUI

struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var focus: Field?
    enum Field { case search, actions }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.6)
            results
            Divider().opacity(0.6)
            footer
        }
        .panelShell()
        .overlay(alignment: .bottomTrailing) {
            if model.actionsOpen {
                ActionPanel(model: model, focus: $focus)
                    .padding(.trailing, Space.compact)
                    .padding(.bottom, Size.footer + Space.tight)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
        }
        .animation(Motion.adaptive(.spring(duration: 0.2, bounce: 0)), value: model.actionsOpen)
        .onChange(of: model.focusToken) { focus = .search }
        .onChange(of: model.query) { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SmartAnswers.changed)) { _ in model.refresh() }
        .onChange(of: model.actionsOpen) { _, open in focus = open ? .actions : .search }
    }

    private var searchBar: some View {
        HStack(spacing: Space.related) {
            OrbitMark(size: 22, dot: true)
            TextField("Search apps, commands, clipboard…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.orbitSearch)
                .focused($focus, equals: .search)
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
            }
        }
        .padding(.horizontal, Space.standard + 2)
        .frame(height: Size.launcherSearch)
    }

    private var results: some View {
        let items = model.items
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].section != item.section {
                            Text(item.section.loc)
                                .font(.orbitMicro.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Space.related)
                                .padding(.top, index == 0 ? Space.compact : Space.related)
                                .padding(.bottom, Space.tight)
                        }
                        LauncherRow(item: item, selected: index == model.selection)
                            .id(item.id)
                            .onTapGesture { model.selection = index; model.runPrimary() }
                            .onHover { if $0 { model.selection = index } }
                    }
                }
                .padding(.horizontal, Space.compact)
                .padding(.bottom, Space.compact)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) { _, i in
                guard items.indices.contains(i) else { return }
                proxy.scrollTo(items[i].id)
            }
            .overlay {
                if items.isEmpty {
                    VStack(spacing: Space.compact) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                        Text("No results").font(.orbitSection)
                        Text("Try an app name, a command like “capture”, or math like 12*8").font(.orbitCaption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: Space.standard) {
            HStack(spacing: Space.tight + 2) {
                OrbitMark(size: 15)
                Text("Orbit").font(.orbitCaption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
            if let primary = model.selected?.actions.first {
                ShortcutHint(title: primary.title, keys: ["↩"], emphasized: true)
                Divider().frame(height: 14)
            }
            ShortcutHint(title: "Actions", keys: ["⌘", "K"])
        }
        .padding(.horizontal, Space.standard)
        .frame(height: Size.footer + 4)
        .background(Palette.surface.opacity(0.6))
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.related) {
            icon
            HStack(spacing: Space.compact) {
                Text(item.title)
                    .font(.orbitBody)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.orbitBody).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Space.compact)
            if let accessory = item.accessory {
                Text(accessory.loc)
                    .font(.orbitCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.compact + 2)
        .frame(height: Size.compactRow + 4)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(selected ? Palette.ink.opacity(0.08) : .clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(Palette.accent).frame(width: 3, height: 16).offset(x: -1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .symbol(let name, let tint): IconTile(symbol: name, tint: tint, size: 22)
        case .file(let path): Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
        case .image(let image):
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .mark: OrbitMark(size: 20)
        }
    }
}

private struct ActionPanel: View {
    @Bindable var model: LauncherModel
    var focus: FocusState<LauncherView.Field?>.Binding

    var body: some View {
        let actions = model.filteredActions
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                    HStack(spacing: Space.compact + 2) {
                        Image(systemName: action.symbol).font(.system(size: 13)).frame(width: 18).foregroundStyle(.secondary)
                        Text(action.title.loc).font(.orbitBody)
                        Spacer()
                        if i == 0 { KeyCap(label: "↩") }
                        else if !action.shortcut.isEmpty { HStack(spacing: 2) { ForEach(action.shortcut, id: \.self) { KeyCap(label: $0) } } }
                    }
                    .padding(.horizontal, Space.compact + 2)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: Radius.smallControl, style: .continuous)
                        .fill(i == model.actionSelection ? Palette.ink.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { model.actionSelection = i; model.runPrimary() }
                }
            }
            .padding(Space.tight + 2)
            Divider()
            TextField("Search actions…", text: $model.actionQuery)
                .textFieldStyle(.plain)
                .font(.orbitBody)
                .focused(focus, equals: .actions)
                .padding(.horizontal, Space.related)
                .frame(height: 36)
        }
        .frame(width: 290)
        .background(Palette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
    }
}
