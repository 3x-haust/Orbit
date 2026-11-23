import AppKit
import SwiftUI

struct NotchHomeLayoutSettings: View {
    @AppStorage(NotchPrefs.homeLayout) private var data = Data()

    private var layout: NotchHomeLayout { .decode(data) }

    var body: some View {
        SettingsGroup(title: "Home layout") {
            SettingsRow(title: "Widgets", subtitle: "Choose widgets and use the arrows to change their order.", symbol: "square.grid.2x2") {
                Button("Reset layout") { save(.standard) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .disabled(layout == .standard)
            }
            ForEach(layout.widgets + NotchHomeWidget.allCases.filter { !layout.widgets.contains($0) }) { widget in
                RowDivider()
                widgetRow(widget)
            }
            RowDivider()
            SettingsRow(title: "Widget widths", subtitle: "Set the left and right widths when two widgets are shown.", symbol: "rectangle.split.2x1") {
                ChipPicker(selection: Binding(
                    get: { layout.ratio },
                    set: { save(.init(widgets: layout.widgets, ratio: $0)) }
                ), options: NotchHomeRatio.allCases.map { ($0, $0.title) })
                .disabled(layout.widgets.count != 2)
            }
        }
    }

    private func widgetRow(_ widget: NotchHomeWidget) -> some View {
        let index = layout.widgets.firstIndex(of: widget)
        return SettingsRow(title: widget.title, symbol: widget.symbol) {
            HStack(spacing: 8) {
                if let index {
                    Button { move(from: index, offset: -1) } label: {
                        Image(systemName: "arrow.up").frame(width: 16)
                    }
                    .help("Move earlier".loc)
                    .accessibilityLabel("Move earlier")
                    .disabled(index == 0)
                    Button { move(from: index, offset: 1) } label: {
                        Image(systemName: "arrow.down").frame(width: 16)
                    }
                    .help("Move later".loc)
                    .accessibilityLabel("Move later")
                    .disabled(index == layout.widgets.count - 1)
                }
                Toggle(widget.title.loc, isOn: Binding(
                    get: { layout.widgets.contains(widget) },
                    set: { shown in
                        let widgets = shown ? layout.widgets + [widget] : layout.widgets.filter { $0 != widget }
                        save(.init(widgets: widgets, ratio: layout.ratio))
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(index != nil && layout.widgets.count == 1)
            }
        }
    }

    private func move(from index: Int, offset: Int) {
        var widgets = layout.widgets
        let destination = index + offset
        guard widgets.indices.contains(index), widgets.indices.contains(destination) else { return }
        widgets.swapAt(index, destination)
        save(.init(widgets: widgets, ratio: layout.ratio))
    }

    private func save(_ layout: NotchHomeLayout) {
        guard let encoded = try? JSONEncoder().encode(layout) else { return }
        data = encoded
        NotchCenter.shared.reloadHomeSettings()
    }
}

struct NotchAIUsageSettings: View {
    @AppStorage(NotchPrefs.aiUsage) private var data = Data()
    @State private var editing: NotchAIProfile?
    private var options: NotchAIUsageOptions { .decode(data) }

    var body: some View {
        SettingsGroup(title: "AI Usage", footer: "Orbit reads quota snapshots from your selected folders.") {
            SettingsRow(title: "Show as", symbol: "percent") {
                ChipPicker(selection: Binding(
                    get: { options.mode },
                    set: { mode in update { $0.mode = mode } }
                ), options: NotchAIUsageMode.allCases.map { ($0, $0.title) })
            }
            RowDivider()
            SettingsRow(title: "Limit windows", symbol: "clock") {
                ChipPicker(selection: Binding(
                    get: { options.period },
                    set: { period in update { $0.period = period } }
                ), options: NotchAIUsagePeriod.allCases.map { ($0, $0.title) })
            }
            RowDivider()
            SettingsRow(title: "Usage profiles", subtitle: "Choose the providers shown in the AI Usage widget.", symbol: "person.2") {
                Button("Add profile") {
                    editing = NotchAIProfile(name: "", provider: .custom)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
            }
            ForEach(options.profiles) { profile in
                RowDivider()
                SettingsRow(title: profile.name, subtitle: profile.sourceDescription, symbol: profile.provider.symbol) {
                    HStack(spacing: 8) {
                        Button("Edit…") { editing = profile }
                            .buttonStyle(PillButtonStyle(prominent: false))
                        Toggle(profile.name, isOn: Binding(
                            get: { options.profiles.first { $0.id == profile.id }?.isVisible ?? false },
                            set: { visible in
                                update {
                                    guard let index = $0.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                                    $0.profiles[index].isVisible = visible
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }
        }
        .sheet(item: $editing) { profile in
            NotchAIProfileEditor(
                profile: profile,
                isBuiltIn: NotchAIProfile.builtIns.contains { $0.id == profile.id },
                canRemove: options.profiles.contains { $0.id == profile.id },
                save: { profile in
                    update {
                        if let index = $0.profiles.firstIndex(where: { $0.id == profile.id }) {
                            $0.profiles[index] = profile
                        } else {
                            $0.profiles.append(profile)
                        }
                    }
                },
                remove: {
                    update { $0.profiles.removeAll { $0.id == profile.id } }
                }
            )
        }
    }

    private func update(_ change: (inout NotchAIUsageOptions) -> Void) {
        var updated = options
        change(&updated)
        guard let encoded = try? JSONEncoder().encode(updated) else { return }
        data = encoded
        NotchCenter.shared.reloadHomeSettings()
    }
}

private struct NotchAIProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: NotchAIProfile
    let isBuiltIn: Bool
    let canRemove: Bool
    let save: (NotchAIProfile) -> Void
    let remove: () -> Void
    @State private var check: CheckRequest?
    @State private var result: NotchAIUsageResult?
    @State private var claudeConnection: ClaudeStatusLineBridge.State?
    @State private var claudeError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text((canRemove ? "Edit usage profile" : "Add usage profile").loc)
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                TextField("Profile name", text: $profile.name)
                Picker("Usage source", selection: $profile.provider) {
                    ForEach(NotchAIProvider.allCases) { provider in
                        Text(provider.title.loc).tag(provider)
                    }
                }
                .disabled(isBuiltIn)
                if profile.provider == .codexBar {
                    TextField("Provider ID", text: $profile.providerKey, prompt: Text("e.g. codex, grok, antigravity"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Source folder").font(.headline)
                    HStack {
                        Text(profile.sourceDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if !profile.folder.isEmpty, profile.provider == .codex || profile.provider == .claude {
                            Button("Use default") { profile.folder = "" }
                        }
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            Text(profile.provider.instructions.loc)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if profile.provider == .claude {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if claudeConnection == .connected {
                            Button("Disconnect status line") { setClaudeConnection(false) }
                        } else {
                            Button("Connect existing status line") { setClaudeConnection(true) }
                                .disabled(claudeConnection != .available)
                        }
                        Link("Claude Code setup guide", destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
                    }
                    if claudeError || claudeConnection == .unavailable {
                        Text("Orbit couldn’t update Claude Code’s settings.json.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if claudeConnection == .connected {
                        Text("Connected. Usage updates after Claude Code runs the status line.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Connect once to share quota updates while keeping your current status line.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Check source") {
                    result = nil
                    check = CheckRequest(profile: profile)
                }
                .disabled(profile.sourceFolder == nil || !validProviderKey || (check != nil && result == nil))
                if let result {
                    Text(resultTitle(result).loc).font(.callout).foregroundStyle(.secondary)
                } else if check != nil {
                    ProgressView().controlSize(.small)
                }
            }
            Divider()
            HStack {
                if canRemove && !isBuiltIn {
                    Button("Remove profile", role: .destructive) {
                        remove()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = profile
                    updated.name = trimmedName
                    updated.providerKey = profile.providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    save(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || !validProviderKey)
            }
        }
        .padding(22)
        .frame(width: 485)
        .onChange(of: profile) {
            check = nil
            result = nil
        }
        .task(id: claudeFolder) {
            claudeConnection = nil
            claudeError = false
            guard let folder = claudeFolder else { return }
            let state = await Task.detached(priority: .utility) { ClaudeStatusLineBridge.state(in: folder) }.value
            if !Task.isCancelled { claudeConnection = state }
        }
        .task(id: check?.id) {
            guard let request = check else { return }
            let reading = await NotchAIUsageService.shared.read(request.profile)
            if !Task.isCancelled, check?.id == request.id { result = reading }
        }
    }

    private struct CheckRequest: Sendable {
        let id = UUID()
        let profile: NotchAIProfile
    }

    private var trimmedName: String { profile.name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validProviderKey: Bool {
        profile.provider != .codexBar || !profile.providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = profile.sourceFolder ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url { profile.folder = url.path }
    }

    private func resultTitle(_ result: NotchAIUsageResult) -> String {
        switch result {
        case .available(let snapshot):
            let now = Date()
            let hasCurrentWindow = snapshot.windows.contains { $0.isCurrent(at: now) }
            return hasCurrentWindow ? "Quota data found" : "Quota data found, but expired"
        case .sessionCost: return "Session cost found"
        case .claudeUnverifiedCost, .missing: return "Waiting for quota data"
        case .unreadable: return "Can’t read source folder"
        case .invalid: return "Invalid quota data"
        }
    }

    private var claudeFolder: URL? { profile.provider == .claude ? profile.sourceFolder : nil }

    private func setClaudeConnection(_ connected: Bool) {
        guard let folder = claudeFolder else { return }
        do {
            try ClaudeStatusLineBridge.setConnected(connected, in: folder)
            claudeConnection = ClaudeStatusLineBridge.state(in: folder)
            claudeError = false
        } catch {
            claudeError = true
        }
    }
}

extension NotchAIProvider {
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .custom: "Custom JSON"
        case .codexBar: "CodexBar export"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "terminal"
        case .claude: "sparkle"
        case .custom, .codexBar: "doc.text"
        }
    }

    var instructions: String {
        switch self {
        case .codex:
            "Choose a Codex profile folder. Orbit checks the signed-in account through the installed CLI, then uses saved quota snapshots when the CLI is unavailable."
        case .claude:
            "Orbit reads recent subscription quota automatically. Connect the status line for ongoing quota updates or API session cost."
        case .custom:
            "Put a version 1 orbit-quota.json file from your quota exporter in this folder."
        case .codexBar:
            "Save the output of codexbar usage --provider <provider-id> --json as codexbar-usage.json in this folder."
        }
    }
}

private extension NotchAIProfile {
    var sourceDescription: String {
        sourceFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder selected".loc
    }
}
