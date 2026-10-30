import AppKit
import SwiftUI

/// Something an app left behind outside its bundle.
struct Leftover: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let kind: String
    let size: Int64
    /// False for system-wide files Orbit can't move without an administrator.
    let removable: Bool
    var selected: Bool
}

/// AppCleaner-style uninstall: the app plus its support files, caches, preferences and containers.
@MainActor @Observable
final class AppUninstaller {
    static let shared = AppUninstaller()

    enum Phase: Equatable { case scanning, ready, refused(String), removing, done(Int64) }

    private(set) var app: URL?
    private(set) var name = ""
    private(set) var version: String?
    private(set) var bundleID: String?
    private(set) var appSize: Int64 = 0
    private(set) var phase: Phase = .scanning
    var leftovers: [Leftover] = []
    var includeApp = true

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?

    private(set) var isRunning = false

    private var runningNow: Bool {
        guard let bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var selectedSize: Int64 {
        (includeApp ? appSize : 0) + leftovers.filter { $0.selected && $0.removable }.reduce(0) { $0 + $1.size }
    }

    // MARK: Entry point

    /// Opens the uninstaller for an .app — from the launcher, the Storage page or a drop.
    func present(app url: URL) {
        task?.cancel()
        let bundle = Bundle(url: url)
        app = url
        bundleID = bundle?.bundleIdentifier
        name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        appSize = 0
        leftovers = []
        includeApp = true
        isRunning = runningNow

        if let reason = refusal(for: url) {
            phase = .refused(reason)
        } else {
            phase = .scanning
            task = Task {
                async let size = Task.detached { DiskSize.of(url, guarded: false) }.value
                var found = await scan(url)
                // The Tavi app shares its input method's settings and word list with Orbit's 한/영.
                if bundleID?.hasPrefix("dev.3xhaust.") == true, TaviBridge.shared.installedVersion != nil {
                    found.removeAll { $0.url.path.localizedCaseInsensitiveContains("tavi") }
                }
                appSize = await size
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.4)) {
                    leftovers = found
                    phase = .ready
                }
            }
        }
        showWindow()
    }

    private func refusal(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard url.pathExtension == "app" else { return "That isn’t an app.".loc }
        if path.hasPrefix("/System/") { return "%@ is part of macOS and can’t be removed.".loc(name) }
        if bundleID == Bundle.main.bundleIdentifier { return "Orbit can’t uninstall itself. Quit Orbit and drag it to the Trash.".loc }
        if bundleID?.hasPrefix("com.apple.") == true { return "%@ comes with macOS and is protected by the system.".loc(name) }
        return nil
    }

    // MARK: Scan

    /// Library folders apps write into, with how each match is recognised.
    private struct Place {
        let path: String
        let kind: String
        var byName = false
        var prefixOnly = false
    }

    nonisolated private static let places: [Place] = [
        Place(path: "Library/Application Support", kind: "Application Support", byName: true),
        Place(path: "Library/Caches", kind: "Caches", byName: true),
        Place(path: "Library/Preferences", kind: "Preferences", prefixOnly: true),
        Place(path: "Library/Preferences/ByHost", kind: "Preferences", prefixOnly: true),
        Place(path: "Library/Containers", kind: "Container"),
        Place(path: "Library/Group Containers", kind: "Group Container"),
        Place(path: "Library/Logs", kind: "Logs", byName: true),
        Place(path: "Library/Saved Application State", kind: "Saved State", prefixOnly: true),
        Place(path: "Library/HTTPStorages", kind: "Web Data", prefixOnly: true),
        Place(path: "Library/WebKit", kind: "Web Data", prefixOnly: true),
        Place(path: "Library/Cookies", kind: "Cookies"),
        Place(path: "Library/LaunchAgents", kind: "Launch Agent"),
        Place(path: "Library/Application Scripts", kind: "Scripts"),
    ]

    nonisolated private static let systemPlaces: [Place] = [
        Place(path: "/Library/Application Support", kind: "Application Support", byName: true),
        Place(path: "/Library/Caches", kind: "Caches"),
        Place(path: "/Library/Preferences", kind: "Preferences", prefixOnly: true),
        Place(path: "/Library/LaunchAgents", kind: "Launch Agent"),
        Place(path: "/Library/LaunchDaemons", kind: "Launch Daemon"),
        Place(path: "/Library/PrivilegedHelperTools", kind: "Helper"),
        Place(path: "/Library/Logs", kind: "Logs", byName: true),
    ]

    func scan(_ app: URL) async -> [Leftover] {
        let bundle = Bundle(url: app)
        guard let id = bundle?.bundleIdentifier?.lowercased() else { return [] }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let executable = (bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? appName
        let home = DiskSize.home

        return await Task.detached {
            // Short or generic names ("Notes", "App") would match other apps' folders.
            let names = Set([appName, executable].filter { $0.count >= 4 }.map { $0.lowercased() })
            func matches(_ entry: String, _ place: Place) -> Bool {
                let e = entry.lowercased()
                let stem = (e as NSString).deletingPathExtension
                if place.prefixOnly { return e.hasPrefix(id + ".") || stem == id || e.hasPrefix(id + ".savedstate") }
                if stem == id || e.hasPrefix(id + ".") { return true }
                // Group containers are team-prefixed ("ABCDE12345.com.foo.bar") or "group.com.foo.bar".
                if e.hasSuffix("." + id) || e.contains("." + id + ".") { return true }
                return place.byName && names.contains(stem)
            }

            var found: [Leftover] = []
            let all = Self.places.map { (home.appendingPathComponent($0.path), $0, true) }
                + Self.systemPlaces.map { (URL(fileURLWithPath: $0.path), $0, false) }
            for (root, place, inHome) in all {
                guard !Task.isCancelled,
                      let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
                for entry in entries where matches(entry, place) {
                    let url = root.appendingPathComponent(entry)
                    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
                    let removable = inHome || FileManager.default.isDeletableFile(atPath: url.path)
                    found.append(Leftover(url: url, kind: place.kind, size: DiskSize.of(url, guarded: false),
                                          removable: removable, selected: removable))
                }
            }
            return found.sorted { $0.size > $1.size }
        }.value
    }

    // MARK: Actions

    func quitApp() {
        guard let bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        Task {
            for _ in 0..<20 where runningNow { try? await Task.sleep(for: .milliseconds(250)) }
            withAnimation(.spring(duration: 0.3)) { isRunning = runningNow }
        }
    }

    func toggle(_ id: String) {
        guard let i = leftovers.firstIndex(where: { $0.id == id }), leftovers[i].removable else { return }
        leftovers[i].selected.toggle()
    }

    func uninstall() {
        isRunning = runningNow
        guard let app, phase == .ready, !isRunning else { return }
        let targets = (includeApp ? [app] : []) + leftovers.filter { $0.selected && $0.removable }.map(\.url)
        guard !targets.isEmpty else { return }
        let total = selectedSize
        phase = .removing
        Task {
            var freed: Int64 = 0
            var failed: [URL] = []
            for url in targets {
                if (try? await NSWorkspace.shared.recycle([url])) != nil {
                    freed += url == app ? appSize : leftovers.first { $0.url == url }?.size ?? 0
                } else {
                    failed.append(url)
                }
            }
            // An app owned by root (often from the App Store) needs Finder, which asks for a password.
            if failed.contains(app) {
                let script = "tell application \"Finder\" to delete (POSIX file \"\(app.path.replacingOccurrences(of: "\"", with: "\\\""))\" as alias)"
                if await Shell.appleScript(script) {
                    freed += appSize
                    failed.removeAll { $0 == app }
                }
            }
            if failed.count == targets.count {
                phase = .ready
                Toast.show("Couldn’t move %@ to the Trash".loc(name), symbol: "exclamationmark.triangle.fill")
                return
            }
            if !failed.contains(app) {
                StorageModel.shared.appRemoved(app)
                Overlaps.shared.refresh()
            }
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) { phase = .done(freed > 0 ? freed : total) }
            if !failed.isEmpty {
                Toast.show("%ld items couldn’t be moved".loc(failed.count), symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func close() {
        task?.cancel()
        window?.close()
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Uninstall".loc
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: UninstallerView(model: self).orbitTint())
            host.sizingOptions = []
            host.safeAreaRegions = [] // no titlebar safe-area feedback into layout (constraint-loop crash)
            w.contentView = FloatingPanel.container(for: host) // a hosting view as the content view can loop "Update Constraints" and abort
            w.center()
            window = w
        }
        window?.bringToFront()
    }
}

// MARK: - View

private struct UninstallerView: View {
    @Bindable var model: AppUninstaller

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 34).padding(.horizontal, 24).padding(.bottom, 18)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Palette.page)
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let app = model.app {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 64, height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.system(size: 20, weight: .bold)).foregroundStyle(Palette.ink)
                Text([model.version.map { "Version %@".loc($0) }, model.appSize > 0 ? model.appSize.diskBytes : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
                if let path = model.app?.deletingLastPathComponent().path {
                    Text(path.replacingOccurrences(of: DiskSize.home.path, with: "~"))
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary.opacity(0.7))
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .scanning:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for files %@ left behind…".loc(model.name)).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
        case .refused(let reason):
            message("hand.raised", reason)
        case .done(let freed):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Palette.accent)
                    .symbolEffect(.bounce, value: freed)
                Text("%@ moved to the Trash".loc(model.name)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Empty the Trash to free %@.".loc(freed.diskBytes)).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary)
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .ready, .removing:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.isRunning { runningBanner }
                    SettingsGroup(title: "App") {
                        row(title: model.name + ".app", detail: "Application".loc, size: model.appSize, on: model.includeApp, removable: true) {
                            model.includeApp.toggle()
                        }
                    }
                    if model.leftovers.isEmpty {
                        Text("No leftover files found.").font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).padding(.leading, 4)
                    } else {
                        SettingsGroup(title: "Leftovers", footer: model.leftovers.contains { !$0.removable }
                                      ? "Locked items are shared system files. Remove them in Finder with an administrator password." : nil) {
                            ForEach(Array(model.leftovers.enumerated()), id: \.element.id) { i, item in
                                if i > 0 { RowDivider() }
                                row(title: item.url.path.replacingOccurrences(of: DiskSize.home.path, with: "~"),
                                    detail: item.kind.loc, size: item.size, on: item.selected, removable: item.removable) {
                                    model.toggle(item.id)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.automatic)
            .disabled(model.phase == .removing)
        }
    }

    private var runningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.accent)
            Text("%@ is open. Quit it before uninstalling.".loc(model.name)).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
            Spacer()
            Button("Quit %@".loc(model.name)) { model.quitApp() }.buttonStyle(PillButtonStyle(prominent: false))
        }
        .padding(12)
        .card()
    }

    private func row(title: String, detail: String, size: Int64, on: Bool, removable: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            OrbitCheckbox(state: on && removable ? .on : .off) { if removable { toggle() } }
                .disabled(!removable)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            if !removable { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary) }
            Text(size.diskBytes).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Palette.inkSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { if removable { withAnimation(.spring(duration: 0.2)) { toggle() } } }
        .opacity(removable ? 1 : 0.6)
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(Palette.inkSecondary)
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.ink).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if case .ready = model.phase {
                Text("%@ selected".loc(model.selectedSize.diskBytes)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary).contentTransition(.numericText())
            }
            if model.phase == .removing { ProgressView().controlSize(.small) }
            Spacer()
            switch model.phase {
            case .done, .refused:
                Button("Done") { model.close() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { model.close() }.buttonStyle(PillButtonStyle(prominent: false)).keyboardShortcut(.cancelAction)
                Button("Move to Trash") { model.uninstall() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.phase != .ready || model.isRunning || model.selectedSize == 0 && !model.includeApp)
            }
        }
        .padding(.horizontal, 20).frame(height: 60)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .animation(.spring(duration: 0.3), value: model.selectedSize)
    }
}
