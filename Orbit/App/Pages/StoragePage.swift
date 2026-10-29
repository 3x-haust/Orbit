import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct StoragePage: View {
    private var model: StorageModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Storage", subtitle: "See what’s using space, and clean it up safely.") {
                HStack(spacing: 10) {
                    if model.phase != .scanning, let last = model.lastScan {
                        Text("Measured %@".loc(last.orbitRelative)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                            .transition(.opacity)
                    }
                    if model.phase == .scanning {
                        Button("Stop") { model.cancel() }.buttonStyle(PillButtonStyle(prominent: false))
                    } else {
                        Button(model.lastScan == nil ? "Analyze" : "Analyze Again") { model.scan() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                }
                .animation(.spring(duration: 0.3), value: model.phase)
            }

            DiskCard(model: model)

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Clean up")
                CleanupSection(model: model)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Applications")
                AppsSection(model: model)
            }
        }
        .onAppear { model.loadApps() }
    }
}

// MARK: - Disk overview

private struct DiskCard: View {
    let model: StorageModel

    var body: some View {
        let disk = model.disk
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(disk.used.diskBytes).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                Text("used of %@".loc(disk.total.diskBytes)).font(.system(size: 13)).foregroundStyle(Palette.inkSecondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(disk.available.diskBytes).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text("available").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
            }

            UsageBar(model: model)
                .frame(height: 14)

            if model.phase == .scanning {
                HStack(spacing: 8) {
                    ProgressView(value: model.progress).progressViewStyle(.linear).tint(Palette.ink).frame(maxWidth: 220)
                    Text("Measuring… %ld%%".loc(Int(model.progress * 100))).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        .contentTransition(.numericText())
                }
                .transition(.opacity)
            }

            if model.usage.isEmpty {
                Text("Analyze to see what’s taking up space. Analyzing only measures — nothing is removed.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 10) {
                    ForEach(StorageCategory.allCases) { c in
                        if let size = model.usage[c] {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.ink.opacity(c.shade)).frame(width: 10, height: 10)
                                Image(systemName: c.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary).frame(width: 16)
                                Text(c.title.loc).font(.system(size: 12)).foregroundStyle(Palette.ink)
                                Spacer(minLength: 4)
                                Text(size.diskBytes).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                                    .contentTransition(.numericText())
                            }
                            .transition(.opacity.combined(with: .offset(y: 4)))
                        }
                    }
                }
            }
        }
        .padding(20)
        .card(radius: 18)
        .animation(.spring(duration: 0.5, bounce: 0.12), value: model.usage)
        .animation(.easeOut(duration: 0.25), value: model.phase)
    }
}

/// The disk as one bar: a segment per category, then free space.
private struct UsageBar: View {
    let model: StorageModel

    var body: some View {
        GeometryReader { g in
            let total = max(1, Double(model.disk.total))
            HStack(spacing: 2) {
                if model.usage.isEmpty {
                    segment(Palette.ink, Double(model.disk.used) / total * g.size.width)
                } else {
                    ForEach(StorageCategory.allCases) { c in
                        if let size = model.usage[c], size > 0 {
                            segment(Palette.ink.opacity(c.shade), max(3, Double(size) / total * g.size.width - 2))
                                .help("\(c.title.loc) · \(size.diskBytes)")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .background(Capsule().fill(Palette.raised))
            .clipShape(Capsule())
        }
    }

    private func segment(_ color: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }
}

// MARK: - Cleanup

private struct CleanupSection: View {
    @Bindable var model: StorageModel
    @State private var expanded: Set<CleanupGroup.Kind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.findPhase == .idle {
                EmptyCleanup { model.findCleanable() }
            } else {
                FindHeader(model: model)
                ForEach(model.groups) { group in
                    GroupCard(model: model, group: group, expanded: expanded.contains(group.kind)) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                            if expanded.contains(group.kind) { expanded.remove(group.kind) } else { expanded.insert(group.kind) }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                SettingsGroup {
                    SettingsRow(title: "Trash", subtitle: model.trashSize.map { $0 > 0 ? "%@ waiting to be deleted".loc($0.diskBytes) : "Empty".loc }
                                ?? "Allow Full Disk Access to measure the Trash.", symbol: "trash") {
                        Button("Empty Trash…") { model.emptyTrash() }.buttonStyle(PillButtonStyle(prominent: false))
                            .disabled(model.trashSize == 0)
                    }
                }

                if model.selectedCount > 0 {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("%@ selected".loc(model.selectedSize.diskBytes)).font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.ink).contentTransition(.numericText())
                            Text("%ld items go to the Trash — nothing is deleted outright.".loc(model.selectedCount))
                                .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        }
                        Spacer()
                        if model.cleaning { ProgressView().controlSize(.small) }
                        Button("Move to Trash…") { model.cleanSelected() }.buttonStyle(PillButtonStyle()).disabled(model.cleaning)
                    }
                    .padding(16)
                    .card(active: true, radius: 14)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.12), value: model.groups)
        .animation(.spring(duration: 0.3), value: model.selectedCount > 0)
    }
}

/// The cleanup check's own status line: progress while it looks, the total and a re-check after.
private struct FindHeader: View {
    let model: StorageModel

    var body: some View {
        HStack(spacing: 8) {
            if model.findPhase == .scanning {
                ProgressView(value: model.findProgress).progressViewStyle(.linear).tint(Palette.ink).frame(maxWidth: 200)
                Text("Looking for things to clean… %ld%%".loc(Int(model.findProgress * 100)))
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).contentTransition(.numericText())
                Spacer()
                Button("Stop") { model.cancelFind() }.buttonStyle(PillButtonStyle(prominent: false))
            } else {
                Circle().fill(model.cleanableSize > 0 ? Palette.accent : Palette.inkSecondary).frame(width: 7, height: 7)
                Text(model.cleanableSize > 0 ? "About %@ can be cleaned up safely.".loc(model.cleanableSize.diskBytes) : "Nothing worth cleaning right now.".loc)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("Find Again") { model.findCleanable() }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(.horizontal, 4)
        .animation(.spring(duration: 0.3), value: model.findPhase)
    }
}

private struct EmptyCleanup: View {
    let scan: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 3) {
                Text("Clean up space").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Finds caches, logs, Xcode leftovers, old downloads and large files. You pick what goes, confirm once more, and it moves to the Trash.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            Button("Find", action: scan).buttonStyle(PillButtonStyle())
        }
        .padding(18)
        .card(hovering: hovering)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }
}

private struct GroupCard: View {
    let model: StorageModel
    let group: CleanupGroup
    let expanded: Bool
    let toggleExpanded: () -> Void

    private var state: OrbitCheckbox.State {
        let on = group.items.filter(\.selected).count
        return on == 0 ? .off : on == group.items.count ? .on : .mixed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                OrbitCheckbox(state: state) { model.toggle(group.kind) }
                Image(systemName: group.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.title.loc).font(.orbitBody).foregroundStyle(Palette.ink)
                        if group.needsReview {
                            Text("Review").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                                .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Palette.raised))
                        }
                    }
                    Text(group.detail.loc).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(group.size.diskBytes).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Palette.ink)
                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide items".loc : "Show %ld items".loc(group.items.count))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if expanded {
                RowDivider()
                VStack(spacing: 0) {
                    ForEach(group.items.prefix(60)) { item in
                        ItemRow(item: item) { model.toggle(group.kind, item: item.id) }
                    }
                    if group.items.count > 60 {
                        Text("and %ld more".loc(group.items.count - 60)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 54).padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ItemRow: View {
    let item: CleanupItem
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            OrbitCheckbox(state: item.selected ? .on : .off, action: toggle)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
            Text(item.name).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if hovering {
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                }
                .buttonStyle(.plain).help("Reveal in Finder".loc)
            }
            if let date = item.date {
                Text(date.orbitRelative.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).frame(width: 90, alignment: .trailing)
            }
            Text(item.size.diskBytes).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.leading, 16).padding(.trailing, 58).padding(.vertical, 6)
        .background(Palette.ink.opacity(hovering ? 0.03 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }
}

/// Ink checkbox with a mixed state for "some of this group".
struct OrbitCheckbox: View {
    enum State { case off, on, mixed }
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(.spring(duration: 0.2, bounce: 0.3)) { action() } }) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(state == .off ? Color.clear : Palette.ink)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(state == .off ? Palette.inkSecondary.opacity(0.6) : Palette.ink, lineWidth: 1.5)
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .heavy)).foregroundStyle(Palette.canvas)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Applications

private struct AppsSection: View {
    let model: StorageModel
    @State private var showAll = false
    @State private var dropping = false
    @State private var query = ""

    private var filtered: [InstalledApp] {
        query.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                TextField("Search apps", text: $query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))

            let list = filtered
            let shown = showAll || !query.isEmpty ? list : Array(list.prefix(12))
            SettingsGroup {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, app in
                    if i > 0 { RowDivider() }
                    AppRow(app: app)
                }
                if shown.isEmpty {
                    Text(model.apps.isEmpty ? "Loading apps…" : "No matches").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: .infinity).padding(16)
                }
            }
            if query.isEmpty && list.count > 12 {
                Button(showAll ? "Show fewer" : "Show all %ld apps".loc(list.count)) {
                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) { showAll.toggle() }
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
    }

    private var dropZone: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.square").font(.system(size: 26, weight: .light))
                .foregroundStyle(dropping ? Palette.accent : Palette.ink)
                .symbolEffect(.bounce, value: dropping)
            VStack(alignment: .leading, spacing: 2) {
                Text("Drop an app here to uninstall it").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Orbit finds its caches, preferences and support files too.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dropping ? Palette.accent.opacity(0.08) : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(dropping ? Palette.accent : Palette.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .scaleEffect(dropping ? 1.01 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: dropping)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                DispatchQueue.main.async { AppUninstaller.shared.present(app: url) }
            }
            return true
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.orbitBody).foregroundStyle(Palette.ink)
                Text(subtitle).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            if let size = app.size {
                Text(size.diskBytes).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Palette.inkSecondary)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.mini)
            }
            Button("Uninstall…") { AppUninstaller.shared.present(app: app.url) }
                .buttonStyle(PillButtonStyle(prominent: false))
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, Space.standard).padding(.vertical, 9)
        .background(Palette.ink.opacity(hovering ? 0.025 : 0))
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .animation(.easeOut(duration: 0.25), value: app.size)
    }

    private var subtitle: String {
        guard let used = app.lastUsed else { return "Never opened".loc }
        return "Last used %@".loc(used.orbitRelative.loc)
    }
}
