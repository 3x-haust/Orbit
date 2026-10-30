import AppKit
import SwiftUI

struct AppsPage: View {
    @Bindable private var catalog = AppsCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Apps", subtitle: "Every app on your Mac in one grid. Type to find one — in Korean, English or by initials.") {
                Button("Open Apps") { AppsPanel.shared.show() }.buttonStyle(PillButtonStyle())
            }

            AppsPreview(catalog: catalog)

            SettingsGroup(title: "Show") {
                SettingsRow(title: "Categories", subtitle: "Chips for Productivity, Developer Tools, Games… ⇥ steps through them.", symbol: "square.grid.2x2") {
                    Toggle("", isOn: $catalog.showCategories).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Frequently used", subtitle: "The apps you switch to most, at the top.", symbol: "clock.arrow.circlepath") {
                    Toggle("", isOn: $catalog.showFrequent).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Icon size", symbol: "app.dashed") {
                    ChipPicker(selection: $catalog.iconSize, options: [(56.0, "Small"), (72.0, "Medium"), (92.0, "Large")])
                }
            }

            SettingsGroup(title: "Folders", footer: "Orbit also looks one folder inside each, so suites like Adobe’s show up.") {
                ForEach(Array(AppsCatalog.Folder.allCases.enumerated()), id: \.offset) { i, f in
                    if i > 0 { RowDivider() }
                    SettingsRow(title: f.title, subtitle: f.subtitle, symbol: "folder") {
                        Toggle("", isOn: Binding(get: { catalog.includes(f) }, set: { catalog.set(f, $0) }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
                ForEach(catalog.extraFolders, id: \.self) { path in
                    RowDivider()
                    SettingsRow(title: (path as NSString).lastPathComponent, subtitle: (path as NSString).abbreviatingWithTildeInPath, symbol: "folder.badge.plus") {
                        Button { catalog.extraFolders.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.inkSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove".loc)
                    }
                }
                RowDivider()
                SettingsRow(title: "Add a folder", subtitle: "Apps kept somewhere else, like an external drive.", symbol: "plus") {
                    Button("Choose…") { addFolder() }.buttonStyle(PillButtonStyle(prominent: false))
                }
            }
        }
        .onAppear { catalog.start() }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add".loc
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !catalog.extraFolders.contains(url.path) { catalog.extraFolders.append(url.path) }
    }
}

/// A small look at the grid: the apps you use most, over a dark desktop.
private struct AppsPreview: View {
    let catalog: AppsCatalog

    var body: some View {
        let picks = Array((catalog.pinnedApps + catalog.frequent(limit: 8) + catalog.apps).uniqued().prefix(8))
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium))
                    Text("Search apps").font(.system(size: 11))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 10)
                .frame(width: 200, height: 24)
                .background(Capsule().fill(.white.opacity(0.09)))
                HStack(spacing: 14) {
                    ForEach(picks) { app in
                        VStack(spacing: 4) {
                            GridIcon(app: app, size: 40)
                            Text(app.name).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1).frame(width: 52)
                        }
                    }
                }
                Text("%ld apps".loc(catalog.apps.count)).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(height: 150)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { AppsPanel.shared.show() }
        .help("Open Apps".loc)
    }
}

private extension Array where Element == AppsCatalog.App {
    func uniqued() -> [Element] {
        var seen = Set<String>()
        return filter { seen.insert($0.path).inserted }
    }
}
