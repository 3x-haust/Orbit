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
    @State private var copied = false

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
                HStack {
                    Button((copied ? "Copied" : "Copy Claude setup").loc) { copyClaudeSetup() }
                        .disabled(profile.sourceFolder == nil)
                    Link("Claude Code setup guide", destination: URL(string: "https://code.claude.com/docs/en/statusline")!)
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
            copied = false
        }
        .task(id: check?.id) {
            guard let request = check else { return }
            let work = Task.detached(priority: .utility) { NotchAIUsageReader.read(request.profile) }
            let reading = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
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
        case .missing: return "Waiting for quota data"
        case .unreadable: return "Can’t read source folder"
        case .invalid: return "Invalid quota data"
        }
    }

    private func copyClaudeSetup() {
        guard let folder = profile.sourceFolder else { return }
        let output = folder.appendingPathComponent("orbit-quota.json").path
        let command = ClaudeQuotaSetup.command(outputPath: output)
        let settings = ["statusLine": ["type": "command", "command": command]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let snippet = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.prepareForNewContents(with: [])
        copied = NSPasteboard.general.setString(snippet, forType: .string)
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
            "Choose a Codex profile folder containing its sessions directory. Orbit reads the quota snapshots recorded by Codex."
        case .claude:
            "Use the setup snippet to write orbit-quota.json from Claude Code’s status line. If you already have a status line, add the capture command to it."
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

/// Claude Code sends the entire status-line input on stdin. Save only the quota fields and
/// publish with an atomic rename so Orbit can read the file while Claude updates it.
enum ClaudeQuotaSetup {
    static func command(outputPath: String) -> String {
        let script = #"""
        use strict;
        use warnings;
        local $/;
        my $input = <STDIN>;
        my $data = eval { decode_json($input // '') };
        exit 0 unless ref($data) eq 'HASH' && ref($data->{rate_limits}) eq 'HASH';
        my %windows;
        for my $key ('five_hour', 'seven_day') {
            my $window = $data->{rate_limits}->{$key};
            next unless ref($window) eq 'HASH' && defined $window->{used_percentage};
            $windows{$key} = { used_percentage => $window->{used_percentage}, resets_at => $window->{resets_at} };
        }
        exit 0 unless %windows;
        my $target = $ARGV[0];
        my ($file, $temp) = tempfile('.orbit-quota-XXXXXXXX', DIR => dirname($target), UNLINK => 1);
        print {$file} encode_json({ captured_at => time, rate_limits => \%windows }) or die $!;
        close $file or die $!;
        rename($temp, $target) or die $!;
        """#
        return "/usr/bin/perl -MJSON::PP -MFile::Temp=tempfile -MFile::Basename=dirname -e "
            + shellArgument(script) + " -- " + shellArgument(outputPath)
    }

    private static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
