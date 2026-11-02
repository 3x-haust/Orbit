import AppKit

extension PortScanner {
    /// Launcher results for "3000", ":3000", "localhost:3000", "ports"/"포트", or a dev server's project name.
    /// Searches what the last scan saw and rescans when that's old; `rescanned` redraws the results.
    func launcherItems(for query: String, rescanned: @escaping () -> Void) -> [LauncherItem] {
        let q = query.lowercased()
        let digits = q.replacingOccurrences(of: "localhost", with: "").replacingOccurrences(of: "127.0.0.1", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        let byNumber = digits.count >= 2 && digits.allSatisfy(\.isNumber)
        let all = q == "포트" || q.count >= 3 && ["ports", "port", "localhost", "lsof"].contains { $0.hasPrefix(q) }
        guard byNumber || all || q.count >= 3 else { return [] }

        if scannedAt.map({ Date().timeIntervalSince($0) > 2 }) ?? true { refresh(then: rescanned) }

        let matches: [ListeningPort]
        if byNumber {
            matches = ports.filter { String($0.port).hasPrefix(digits) }
        } else if all {
            matches = ports.filter { $0.kind == .dev } + ports.filter { $0.kind == .app }
        } else {
            // A dev server by its project or tool ("web", "vite"); apps already show up as applications.
            matches = ports.filter { port in
                port.kind == .dev && [port.project?.name, port.tool].contains { $0?.lowercased().contains(q) == true }
            }
        }
        return matches.prefix(8).map(item)
    }

    private func item(_ port: ListeningPort) -> LauncherItem {
        let siblings = ports.filter { $0.pid == port.pid && $0.port != port.port }.map(\.port)
        let subtitle = [port.project?.name ?? port.name, port.tool].compactMap { $0 }.joined(separator: " · ")
        return LauncherItem(id: "port.\(port.port)", title: "localhost:\(port.port)", subtitle: subtitle,
                            icon: port.appPath.map { .file($0) } ?? .symbol("network", Tint.launcher),
                            accessory: port.exposed ? "Network" : "Port", section: "Ports", actions: [
            LauncherAction(title: "Open in Browser", symbol: "safari") { NSWorkspace.shared.open(port.url) },
            LauncherAction(title: "Copy URL", symbol: "doc.on.doc") { PortActions.copy(port) },
            LauncherAction(title: "Stop…", symbol: "stop.circle") { PortActions.stop(port, siblings: siblings, force: false) },
            LauncherAction(title: "Show in Ports", symbol: "network") { MainWindow.show(.ports) },
        ])
    }
}
