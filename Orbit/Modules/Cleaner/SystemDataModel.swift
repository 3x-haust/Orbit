import AppKit
import SwiftUI

/// Drives the Storage page's System Data section: what's in it, and removing parts of it after asking.
@MainActor @Observable
final class SystemDataModel {
    static let shared = SystemDataModel()

    enum Phase: Equatable { case idle, scanning, done }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var items: [SystemDataItem] = []
    private(set) var scannedAt: Date?
    /// App containers are only measured with Full Disk Access; without it macOS would ask about every app.
    private(set) var fullDisk = MenuBarAgentPrefs.readable
    /// What's being removed right now.
    private(set) var busy: Set<String> = []

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Everything found, not counting purgeable space: macOS already reports that as available.
    var total: Int64 { items.filter { $0.id != "purgeable" }.reduce(0) { $0 + $1.size } }

    func scan() {
        task?.cancel()
        fullDisk = MenuBarAgentPrefs.readable
        phase = .scanning
        progress = 0
        items = []
        let fullDisk = fullDisk
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        task = Task {
            let found = await Task.detached(priority: .userInitiated) {
                await SystemData.scan(fullDisk: fullDisk, running: running, progress: { value in
                    Task { @MainActor in
                        let model = SystemDataModel.shared
                        if model.phase == .scanning { withAnimation(.easeOut(duration: 0.3)) { model.progress = max(model.progress, value) } }
                    }
                }, found: { partial in
                    Task { @MainActor in
                        let model = SystemDataModel.shared
                        if model.phase == .scanning { withAnimation(.spring(duration: 0.4, bounce: 0.1)) { model.items = partial } }
                    }
                })
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
                items = found
                scannedAt = Date()
                phase = .done
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        withAnimation(.spring(duration: 0.3)) { phase = scannedAt == nil ? .idle : .done }
    }

    // MARK: Removing

    /// Asks first, in words that match what's lost, then trashes it (or runs its own remover) and updates the list.
    func remove(_ item: SystemDataItem, in parent: SystemDataItem? = nil) {
        guard item.removable, !busy.contains(item.id) else { return }
        let app = item.app ?? parent?.app
        let appName = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        if let app, let id = Bundle(url: app)?.bundleIdentifier, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit %@ first".loc(appName ?? item.title)
            alert.informativeText = "It’s using this data right now.".loc
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        let name = parent.map { "\($0.title) · \(item.title)" } ?? item.title
        let alert = NSAlert()
        alert.messageText = (item.command == nil ? "Move “%@” to the Trash?" : "Delete “%@”?").loc(name)
        alert.informativeText = [warning(item, appName: appName), "Frees about %@.".loc(item.size.diskBytes),
                                 (item.command == nil ? "You can restore it from the Trash until you empty it." : "This can’t be undone.").loc]
            .joined(separator: "\n\n")
        alert.addButton(withTitle: (item.command == nil ? "Move to Trash" : "Delete").loc)
        alert.addButton(withTitle: "Cancel".loc)
        alert.buttons.first?.hasDestructiveAction = item.care >= .yours || item.command != nil
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        busy.insert(item.id)
        Task {
            var removed = false
            if let command = item.command {
                removed = await Shell.runAsync(command[0], Array(command.dropFirst())).status == 0
            } else {
                var moved = 0
                // One at a time so one locked file doesn't stop the rest.
                for url in item.urls where SystemData.canTrash(url) {
                    if (try? await NSWorkspace.shared.recycle([url])) != nil { moved += 1 }
                }
                removed = moved == item.urls.count
                if moved > 0, !removed { Toast.show("Some of it couldn’t be moved".loc, symbol: "exclamationmark.triangle.fill", detail: "macOS or an app is still using it.".loc) }
            }
            busy.remove(item.id)
            guard removed else {
                if item.command != nil { Toast.show("Couldn’t delete %@".loc(item.title), symbol: "exclamationmark.triangle.fill") }
                return
            }
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { drop(item.id) }
            StorageModel.shared.diskChanged()
            Toast.show((item.command == nil ? "Moved %@ to the Trash" : "Freed %@").loc(item.size.diskBytes),
                       symbol: item.command == nil ? "trash.fill" : "checkmark.circle.fill",
                       detail: item.command == nil ? "Empty the Trash to free the space".loc : nil)
        }
    }

    private func warning(_ item: SystemDataItem, appName: String?) -> String {
        switch item.care {
        case .rebuilds: return "It comes back when it’s needed, so the next launch or build may take a little longer.".loc
        case .download: return "It’s gone until you download it again.".loc
        case .yours:
            if item.section == .apps, let appName { return "%@ forgets what’s in it: settings, sign-ins and downloads, as if it were just installed.".loc(appName) }
            if item.section == .leftovers { return "No installed app uses it, but check the name before removing it.".loc }
            return "It holds things you made or set up. Make sure you don’t need it.".loc
        case .macOS: return ""
        }
    }

    /// Takes an item out of the list; a parent shrinks with it and goes when it's empty.
    private func drop(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: i)
            return
        }
        for i in items.indices {
            guard let j = items[i].children.firstIndex(where: { $0.id == id }) else { continue }
            let child = items[i].children.remove(at: j)
            items[i].size = max(0, items[i].size - child.size)
            items[i].urls.removeAll { child.urls.contains($0) }
            if items[i].children.isEmpty { items.remove(at: i) }
            return
        }
    }
}
