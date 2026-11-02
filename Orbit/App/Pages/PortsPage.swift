import AppKit
import SwiftUI

struct PortsPage: View {
    private var scanner: PortScanner { .shared }
    @State private var showSystem = false

    var body: some View {
        let ports = scanner.ports
        let dev = ports.filter { $0.kind == .dev }
        let apps = ports.filter { $0.kind == .app }
        let system = ports.filter { $0.kind == .system }

        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Ports", subtitle: "What's listening on your Mac, and which project started it. Type a port in the launcher to jump there.") {
                Button("Refresh") { scanner.refresh() }.buttonStyle(PillButtonStyle(prominent: false))
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Dev servers")
                if dev.isEmpty {
                    EmptyDevServers(loading: scanner.scannedAt == nil)
                } else {
                    PortList(ports: dev, all: ports)
                }
            }

            if !apps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Apps")
                    PortList(ports: apps, all: ports)
                }
            }

            if !system.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button { withAnimation(Motion.reflow) { showSystem.toggle() } } label: {
                        HStack(spacing: 5) {
                            SectionLabel("macOS")
                            Text("\(system.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                                .rotationEffect(.degrees(showSystem ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSystem { PortList(ports: system, all: ports).transition(.opacity) }
                }
            }

            Text("Only processes you own show here; macOS keeps other users' sockets private.")
                .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).padding(.leading, 4)
        }
        .animation(Motion.reflow, value: ports.map(\.id))
        .onAppear { scanner.watch(true) }
        .onDisappear { scanner.watch(false) }
    }
}

private struct EmptyDevServers: View {
    let loading: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "powerplug")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.raised))
            VStack(alignment: .leading, spacing: 3) {
                Text(loading ? "Looking…" : "No dev servers running").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                Text("Start one — npm run dev, rails s, python -m http.server — and it shows up here with its project.")
                    .font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card()
    }
}

private struct PortList: View {
    let ports: [ListeningPort]
    /// Everything scanned, to say which other ports stopping a process also closes.
    let all: [ListeningPort]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ports.enumerated()), id: \.element.id) { i, port in
                if i > 0 { RowDivider() }
                PortRow(port: port, siblings: all.filter { $0.pid == port.pid && $0.port != port.port }.map(\.port))
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let siblings: [Int]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Space.related) {
            Text(verbatim: ":\(port.port)")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 70, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))

            icon

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: port.project?.name ?? port.name).font(.orbitBodyEmphasized).foregroundStyle(Palette.ink).lineLimit(1)
                    if let tool = port.tool, tool != port.project?.name {
                        Text(verbatim: tool).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                            .padding(.horizontal, 6).frame(height: 17)
                            .background(Capsule().fill(Palette.raised))
                    }
                    if port.exposed {
                        Label("Network", systemImage: "wifi").labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6).frame(height: 17)
                            .background(Capsule().fill(Palette.accent.opacity(0.14)))
                            .help("Other devices on your network can reach it, not only this Mac.".loc)
                    }
                }
                Text(verbatim: details).font(.orbitCaption).foregroundStyle(Palette.inkSecondary).lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: Space.standard)

            HStack(spacing: 2) {
                IconButton(symbol: "safari", help: "Open in Browser") { NSWorkspace.shared.open(port.url) }
                IconButton(symbol: "doc.on.doc", help: "Copy URL") { PortActions.copy(port) }
                if let project = port.project {
                    IconButton(symbol: "folder", help: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
                    }
                }
                IconButton(symbol: "stop.circle", help: "Stop") { PortActions.stop(port, siblings: siblings, force: false) }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, Space.standard)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(Palette.ink.opacity(hovering ? 0.025 : 0))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(port.url) }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .contextMenu {
            Button("Open in Browser") { NSWorkspace.shared.open(port.url) }
            Button("Copy URL") { PortActions.copy(port) }
            if let project = port.project {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)]) }
                Button("Copy Path") { PortActions.copyText(project.path) }
            }
            Divider()
            Button("Stop…") { PortActions.stop(port, siblings: siblings, force: false) }
            Button("Force Stop…") { PortActions.stop(port, siblings: siblings, force: true) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let app = port.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app)).resizable().frame(width: 26, height: 26)
        } else {
            Image(systemName: port.kind == .system ? "gearshape.2" : "terminal")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised))
        }
    }

    /// "node · PID 4120 · ~/code/web · 2h"
    private var details: String {
        var parts = [port.project != nil ? port.name : nil, "PID \(port.pid)"].compactMap { $0 }
        if let path = port.project?.path { parts.append((path as NSString).abbreviatingWithTildeInPath) }
        if let started = port.started { parts.append(KeepAwake.format(Date().timeIntervalSince(started))) }
        return parts.joined(separator: " · ")
    }
}

/// What a port row and the launcher both do with a port.
@MainActor
enum PortActions {
    static func copy(_ port: ListeningPort) {
        copyText(port.url.absoluteString)
        Toast.show("Copied %@".loc(port.url.absoluteString), symbol: "doc.on.doc.fill")
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Asks first, since the server's terminal loses it too, then stops it and rescans.
    static func stop(_ port: ListeningPort, siblings: [Int], force: Bool) {
        let alert = NSAlert()
        let name = port.project?.name ?? port.name
        alert.messageText = (force ? "Force stop “%@” on :%ld?" : "Stop “%@” on :%ld?").loc(name, port.port)
        var info = (force ? "It ends right away, without a chance to clean up." : "Like pressing Control-C in its terminal.").loc
        if !siblings.isEmpty {
            info += "\n" + "It also closes %@.".loc(siblings.map { ":\($0)" }.joined(separator: ", "))
        }
        alert.informativeText = info
        alert.addButton(withTitle: (force ? "Force Stop" : "Stop").loc)
        alert.addButton(withTitle: "Cancel".loc)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = PortScanner.shared.stop(port, force: force) {
            Toast.show(error, symbol: "exclamationmark.triangle.fill")
            return
        }
        Toast.show("Stopped :%ld".loc(port.port), symbol: "stop.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PortScanner.shared.refresh() }
    }
}
