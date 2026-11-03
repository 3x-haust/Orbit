import AppKit
import SwiftUI

/// The Storage page's look inside "System Data": who made each part, what it is, and whether it can go.
struct SystemDataSection: View {
    private var model: SystemDataModel { .shared }
    @State private var expanded: Set<String> = []
    /// Sections showing everything, not just their biggest few.
    @State private var showAll: Set<SystemDataItem.Section> = []
    private let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.phase == .idle {
                SystemDataIntro { model.scan() }
            } else {
                header
                if !model.fullDisk, model.phase == .done {
                    SettingsGroup {
                        SettingsRow(title: "App containers aren’t counted", subtitle: "Docker, UTM and sandboxed apps keep their data in containers macOS protects. Allow Full Disk Access, then analyze again.",
                                    symbol: "lock") {
                            Button("Allow Full Disk Access") { MenuBarAgentPrefs.openFullDiskAccessSettings() }
                                .buttonStyle(PillButtonStyle(prominent: false))
                        }
                    }
                }
                ForEach(SystemDataItem.Section.allCases) { section in
                    let items = model.items.filter { $0.section == section }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(section.title.loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                                Text(items.reduce(Int64(0)) { $0 + $1.size }.diskBytes).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                            }
                            .padding(.leading, 4)
                            list(showAll.contains(section) ? items : Array(items.prefix(shown)))
                            if items.count > shown {
                                Button(showAll.contains(section) ? "Show fewer" : "Show all %ld".loc(items.count)) {
                                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                                        if showAll.contains(section) { showAll.remove(section) } else { showAll.insert(section) }
                                    }
                                }
                                .buttonStyle(PillButtonStyle(prominent: false))
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.12), value: model.items)
        .animation(.spring(duration: 0.3), value: model.phase)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.phase == .scanning {
                ProgressView(value: model.progress).progressViewStyle(.linear).tint(Palette.ink).frame(maxWidth: 200)
                Text(model.progress > 0.95 ? "Measuring the biggest folders… %@ so far".loc(model.total.diskBytes)
                     : "Looking through System Data… %ld%%".loc(Int(model.progress * 100)))
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).contentTransition(.numericText())
                Spacer()
                Button("Stop") { model.cancel() }.buttonStyle(PillButtonStyle(prominent: false))
            } else {
                Circle().fill(Palette.ink).frame(width: 7, height: 7)
                Text("%@ found, in %ld places".loc(model.total.diskBytes, model.items.count))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                if let at = model.scannedAt {
                    Text(at.orbitRelative.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
                Button("Analyze Again") { model.scan() }.buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(.horizontal, 4)
    }

    private func list(_ items: [SystemDataItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider() }
                let open = expanded.contains(item.id)
                SystemDataRow(item: item, expanded: open, busy: model.busy.contains(item.id),
                              toggle: item.children.isEmpty ? nil : {
                                  withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                                      if open { expanded.remove(item.id) } else { expanded.insert(item.id) }
                                  }
                              },
                              remove: { model.remove(item) })
                if open {
                    VStack(spacing: 0) {
                        ForEach(item.children.prefix(40)) { child in
                            SystemDataRow(item: child, parent: item, busy: model.busy.contains(child.id), remove: { model.remove(child, in: item) })
                        }
                        if item.children.count > 40 {
                            Text("and %ld more".loc(item.children.count - 40)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 58).padding(.vertical, 8)
                        }
                    }
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SystemDataIntro: View {
    let scan: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "internaldrive").font(.system(size: 20, weight: .medium)).foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 3) {
                Text("What’s in System Data").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("macOS puts app data, simulators, virtual machines and its own files in one number. Orbit splits it up, says what each part is and whether it’s safe to remove.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Analyze", action: scan).buttonStyle(PillButtonStyle())
        }
        .padding(18)
        .card(hovering: hovering)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }
}

private struct SystemDataRow: View {
    let item: SystemDataItem
    var parent: SystemDataItem?
    var expanded = false
    var busy = false
    var toggle: (() -> Void)?
    let remove: () -> Void
    @State private var hovering = false

    private var child: Bool { parent != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.title).font(child ? .system(size: 12) : .orbitBody).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if !child || item.care != parent?.care { CarePill(care: item.care) }
                }
                if let detail = item.detail {
                    Text(verbatim: detail).font(child ? .system(size: 11) : .orbitCaption).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(child ? 1 : 3).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                if let location = item.location {
                    IconButton(symbol: "magnifyingglass", help: "Reveal in Finder", size: 26) {
                        NSWorkspace.shared.activateFileViewerSelecting([location])
                    }
                }
                if item.removable {
                    IconButton(symbol: item.command == nil ? "trash" : "xmark.bin", help: item.command == nil ? "Move to Trash" : "Delete", size: 26, action: remove)
                        .disabled(busy)
                }
            }
            .opacity(hovering ? 1 : 0.4)
            if busy { ProgressView().controlSize(.small) }
            Text(item.size > 0 ? item.size.diskBytes : "—").font(.system(size: child ? 12 : 13, weight: .semibold, design: .rounded))
                .foregroundStyle(child ? Palette.inkSecondary : Palette.ink).frame(width: 74, alignment: .trailing)
            if !child {
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 18).opacity(toggle == nil ? 0 : 1)
            }
        }
        .padding(.leading, child ? 56 : Space.standard).padding(.trailing, child ? 42 : Space.standard)
        .padding(.vertical, child ? 6 : 11)
        .background(Palette.ink.opacity(hovering ? 0.025 : 0))
        .contentShape(Rectangle())
        .onTapGesture { toggle?() }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu {
            if let location = item.location {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                Button("Copy Path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(location.path, forType: .string) }
            }
            if item.removable {
                Divider()
                Button(item.command == nil ? "Move to Trash…" : "Delete…", action: remove)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        let side: CGFloat = child ? 20 : 28
        if let app = item.app {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: side, height: side)
        } else if child, let location = item.location, FileManager.default.fileExists(atPath: location.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: location.path)).resizable().frame(width: side, height: side)
        } else {
            Image(systemName: item.symbol).font(.system(size: child ? 10 : 13, weight: .medium)).foregroundStyle(Palette.ink)
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: child ? 5 : 7, style: .continuous).fill(Palette.raised))
        }
    }
}

/// How much care removing something takes, in two words.
private struct CarePill: View {
    let care: SystemDataItem.Care

    var body: some View {
        let safe = care == .rebuilds
        HStack(spacing: 3) {
            if care == .macOS { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)) }
            Text(care.label.loc)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(safe ? Palette.accent : Palette.inkSecondary)
        .padding(.horizontal, 6).frame(height: 16)
        .background(Capsule().fill(safe ? Palette.accent.opacity(0.14) : Palette.raised))
        .help(help.loc)
    }

    private var help: String {
        switch care {
        case .rebuilds: "Whatever made it makes it again, so removing it is safe."
        case .download: "Removing it is safe, but you’ll have to download it again to use it."
        case .yours: "Something you made or set up. Check before removing it."
        case .macOS: "macOS manages this itself. It’s here so you know what it is."
        }
    }
}
