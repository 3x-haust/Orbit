import AppKit
import Foundation

/// One part of what macOS files under "System Data": what it is, who made it, and whether it can go.
struct SystemDataItem: Identifiable, Equatable {
    /// What removing it costs.
    enum Care: Int, Comparable {
        /// Caches and build products: whatever made it makes it again.
        case rebuilds
        /// Toolchains, SDKs, runtimes, models: gone until you download them again.
        case download
        /// Things you made or set up: virtual machines, emulators, backups, an app's settings and sign-ins.
        case yours
        /// macOS manages it; listed so you know what it is.
        case macOS

        static func < (a: Care, b: Care) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .rebuilds: "Comes back"
            case .download: "Re-downloadable"
            case .yours: "Your data"
            case .macOS: "macOS"
            }
        }
    }

    enum Section: Int, CaseIterable, Identifiable {
        case leftovers, developer, machines, apps, home, macOS
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .leftovers: "Left behind by deleted apps"
            case .developer: "Developer"
            case .machines: "Virtual machines & backups"
            case .apps: "App data"
            case .home: "Other folders in your home"
            case .macOS: "macOS"
            }
        }
    }

    let id: String
    var title: String
    var detail: String?
    var section: Section
    var care: Care
    /// What goes to the Trash. Empty when it can't be removed that way.
    var urls: [URL] = []
    var size: Int64 = 0
    var symbol = "folder"
    /// The app it belongs to, for its icon and to make sure it isn't running.
    var app: URL?
    /// Where Reveal in Finder goes.
    var location: URL?
    var children: [SystemDataItem] = []
    /// Removes it the owner's way instead of the Trash, such as `xcrun simctl delete`.
    var command: [String]?

    var removable: Bool {
        care != .macOS && (command != nil || (!urls.isEmpty && urls.allSatisfy(SystemData.canTrash)))
    }
}

/// Finds what makes up System Data. Only reads; StorageModel-style removal happens in SystemDataModel after the user confirms.
enum SystemData {
    private static var home: URL { DiskSize.home }
    private static let fm = FileManager.default

    // MARK: Safety

    /// Folders macOS and apps expect to exist. What's inside them can go; they stay.
    private static let keep: Set<String> = [
        "Library", "Library/Application Support", "Library/Caches", "Library/Containers", "Library/Group Containers",
        "Library/Logs", "Library/HTTPStorages", "Library/WebKit", "Library/Saved Application State", "Library/Developer",
        "Library/Preferences", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Applications",
        ".Trash", ".cache", ".config", ".local",
    ]

    /// Keys and credentials: never offered for the Trash, not even what's inside.
    private static let secrets = [".ssh", ".gnupg", ".aws", ".kube", ".azure", ".password-store", ".docker/config.json", ".netrc"]

    /// Inside the home folder, not a symlink, not personal data (mail, messages, photos, keychains), not a folder that must stay.
    nonisolated static func canTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home.path + "/") else { return false }
        let relative = String(path.dropFirst(home.path.count + 1))
        guard !keep.contains(relative), !DiskSize.isPersonal(path: path),
              !secrets.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return false }
        return true
    }

    // MARK: Scan

    /// Everything found, biggest first within each section. `fullDisk`: app containers can be read without prompts.
    /// `found` gets each part as soon as it's measured, so the list fills in while the big folders are still being walked.
    static func scan(fullDisk: Bool, running: Set<String>, progress: @escaping @Sendable (Double) -> Void,
                     found: @escaping @Sendable ([SystemDataItem]) -> Void) async -> [SystemDataItem] {
        let fixed: [@Sendable () -> [SystemDataItem]] = [
            { simulators() }, { runtimes() }, { xcode() }, { android() }, { models() }, { toolchains() },
            { machines(fullDisk: fullDisk) }, { backups() }, { macOS() }, { shared() },
        ]
        // The home folder's own top-level folders are the biggest walks, so they start first.
        let finders = homeFolders().map { dir in { @Sendable in homeFolder(dir) } } + fixed
        let folders = appFolders(fullDisk: fullDisk)
        let total = Double(finders.count + folders.count)
        var done = 0.0
        var items: [SystemDataItem] = []
        var measured: [(AppFolder, Int64)] = []

        await withTaskGroup(of: ([SystemDataItem], (AppFolder, Int64)?).self) { group in
            // A handful at a time: walking ~/Library on every core at once would stall the Mac.
            typealias Job = @Sendable () -> ([SystemDataItem], (AppFolder, Int64)?)
            var pending: [Job] = finders.map { f in { @Sendable in (f(), nil) } }
                + folders.map { folder in { @Sendable in ([], (folder, DiskSize.of(folder.url, guarded: false))) } }
            func next() {
                guard !pending.isEmpty else { return }
                let job = pending.removeFirst()
                group.addTask(priority: .userInitiated) { job() }
            }
            for _ in 0..<6 { next() }
            for await (parts, folder) in group {
                next()
                guard !Task.isCancelled else { continue }
                items += parts
                if !parts.isEmpty { found(sorted(items)) }
                if let folder { measured.append(folder) }
                done += 1
                progress(done / total)
            }
        }
        guard !Task.isCancelled else { return [] }
        items += owners(of: measured, running: running)
        return sorted(items)
    }

    private static func sorted(_ items: [SystemDataItem]) -> [SystemDataItem] {
        items.filter { $0.size > 0 || $0.id == "snapshots" }.sorted { ($0.section.rawValue, -$0.size) < ($1.section.rawValue, -$1.size) }
    }

    private static func size(_ url: URL) -> Int64 { DiskSize.of(url, guarded: false) }

    private static func folder(_ relative: String) -> URL { home.appendingPathComponent(relative) }

    private static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// A parent made of `children`, sized and removable as a whole when they all are.
    private static func group(_ id: String, _ title: String, _ detail: String, section: SystemDataItem.Section, care: SystemDataItem.Care,
                              symbol: String, location: URL?, children: [SystemDataItem], whole: [URL] = [], app: URL? = nil) -> [SystemDataItem] {
        let kids = children.filter { $0.size > 1_000_000 }.sorted { $0.size > $1.size }
        guard !kids.isEmpty || !whole.isEmpty else { return [] }
        let size = whole.isEmpty ? kids.reduce(0) { $0 + $1.size } : whole.reduce(0) { $0 + Self.size($1) }
        return [SystemDataItem(id: id, title: title.loc, detail: detail.loc, section: section, care: care, urls: whole, size: size,
                               symbol: symbol, app: app, location: location, children: kids)]
    }

    private static func entry(_ url: URL, _ title: String, detail: String? = nil, section: SystemDataItem.Section, care: SystemDataItem.Care,
                              symbol: String = "folder", trash: Bool = true) -> SystemDataItem {
        SystemDataItem(id: url.path, title: title, detail: detail, section: section, care: care, urls: trash ? [url] : [],
                       size: size(url), symbol: symbol, location: url)
    }

    private static func children(of url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []).filter {
            $0.lastPathComponent != ".DS_Store" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }
    }

    // MARK: Developer

    private static var hasSimulators: Bool { exists(folder("Library/Developer/CoreSimulator")) }

    private static func simulators() -> [SystemDataItem] {
        let root = folder("Library/Developer/CoreSimulator/Devices")
        let devices = children(of: root).compactMap { dir -> SystemDataItem? in
            guard let plist = NSDictionary(contentsOf: dir.appendingPathComponent("device.plist")),
                  let name = plist["name"] as? String else { return nil }
            return SystemDataItem(id: dir.path, title: name, detail: (plist["runtime"] as? String).map(runtimeName), section: .developer,
                                  care: .yours, size: size(dir), symbol: "iphone", location: dir,
                                  command: ["/usr/bin/xcrun", "simctl", "delete", dir.lastPathComponent])
        }
        return group(root.path, "iOS simulators", "Simulated iPhones and iPads from Xcode, with the apps and data installed in them. Xcode makes a fresh one whenever you need it.",
                     section: .developer, care: .yours, symbol: "iphone", location: root, children: devices)
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-3" → "iOS 26.3"
    private static func runtimeName(_ id: String) -> String {
        let parts = (id.components(separatedBy: "SimRuntime.").last ?? id).split(separator: "-")
        guard let platform = parts.first else { return id }
        return ([String(platform)] + [parts.dropFirst().joined(separator: ".")]).joined(separator: " ")
    }

    /// The OS images simulators boot. They live outside the home folder, so they're removed through simctl.
    private static func runtimes() -> [SystemDataItem] {
        guard hasSimulators else { return [] }
        let out = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"])
        guard out.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(out.output.utf8)) as? [String: [String: Any]] else { return [] }
        let items = json.values.compactMap { r -> SystemDataItem? in
            guard let id = r["identifier"] as? String, let size = (r["sizeBytes"] as? NSNumber)?.int64Value else { return nil }
            let name = (r["runtimeIdentifier"] as? String).map(runtimeName) ?? id
            let version = [r["version"] as? String, (r["build"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            let platform = name.split(separator: " ").first.map(String.init) ?? name
            return SystemDataItem(id: "runtime:" + id, title: "\(platform) \(version)", section: .developer, care: .download, size: size,
                                  symbol: "cpu", command: (r["deletable"] as? Bool) == false ? nil : ["/usr/bin/xcrun", "simctl", "runtime", "delete", id])
        }
        return group("runtimes", "Simulator runtimes", "The iOS, watchOS and visionOS versions simulators run, several GB each. Xcode › Settings › Components downloads them again.",
                     section: .developer, care: .download, symbol: "cpu", location: nil, children: items)
    }

    private static func xcode() -> [SystemDataItem] {
        let dev = folder("Library/Developer")
        var items: [SystemDataItem] = []
        let tests = dev.appendingPathComponent("XCTestDevices")
        if exists(tests) {
            items.append(entry(tests, "Test simulators".loc, detail: "Copies of simulators Xcode makes to run tests in parallel. It makes them again for the next test run.".loc,
                               section: .developer, care: .rebuilds, symbol: "checkmark.diamond"))
        }
        let derived = dev.appendingPathComponent("Xcode/DerivedData")
        if exists(derived) {
            items.append(entry(derived, "Xcode build data".loc, detail: "Builds, indexes and logs for every project you opened. Xcode rebuilds a project’s when you open it.".loc,
                               section: .developer, care: .rebuilds, symbol: "hammer"))
        }
        let caches = dev.appendingPathComponent("CoreSimulator/Caches")
        if exists(caches) {
            items.append(entry(caches, "Simulator caches".loc, detail: "Shared libraries simulators load quickly from. They come back on the next launch.".loc,
                               section: .developer, care: .rebuilds, symbol: "archivebox"))
        }
        let support = children(of: dev.appendingPathComponent("Xcode")).filter { $0.lastPathComponent.hasSuffix("DeviceSupport") }
        items += group("devicesupport", "Device support files", "Debug symbols Xcode copied from iPhones and Watches you connected. It copies them again next time.",
                       section: .developer, care: .rebuilds, symbol: "cable.connector", location: support.first,
                       children: support.flatMap(children(of:)).map { entry($0, $0.lastPathComponent, section: .developer, care: .rebuilds) })
        let archives = dev.appendingPathComponent("Xcode/Archives")
        items += group(archives.path, "Xcode archives", "Builds you archived to upload or share, with their debug symbols. Keep the ones for versions people still use.",
                       section: .developer, care: .yours, symbol: "archivebox.fill", location: archives,
                       children: children(of: archives).map { entry($0, $0.lastPathComponent, section: .developer, care: .yours) })
        return items
    }

    private static func android() -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        let avd = folder(".android/avd")
        let devices = children(of: avd).filter { $0.pathExtension == "avd" }.map { dir -> SystemDataItem in
            let config = (try? String(contentsOf: dir.appendingPathComponent("config.ini"), encoding: .utf8)) ?? ""
            let name = config.split(separator: "\n").first { $0.hasPrefix("avd.ini.displayname") }
                .flatMap { $0.split(separator: "=", maxSplits: 1).last }.map { $0.trimmingCharacters(in: .whitespaces) }
            var item = entry(dir, name ?? dir.deletingPathExtension().lastPathComponent, section: .developer, care: .yours, symbol: "smartphone")
            let ini = dir.deletingPathExtension().appendingPathExtension("ini")
            if exists(ini) { item.urls.append(ini) }
            return item
        }
        items += group(avd.path, "Android emulators", "Virtual Android phones from Android Studio, with the apps and data installed in them.",
                       section: .developer, care: .yours, symbol: "smartphone", location: avd, children: devices)

        let sdk = folder("Library/Android/sdk")
        // Versioned folders are listed one by one; the rest as they are.
        let parts = children(of: sdk).flatMap { dir -> [SystemDataItem] in
            let name = dir.lastPathComponent
            switch name {
            case "system-images":
                return children(of: dir).flatMap { api in children(of: api).flatMap { tag in children(of: tag).map { abi in
                    entry(abi, "System image %@ · %@ · %@".loc(api.lastPathComponent, tag.lastPathComponent, abi.lastPathComponent), section: .developer, care: .download)
                } } }
            case "ndk", "platforms", "build-tools", "sources":
                return children(of: dir).map { entry($0, "\(name) \($0.lastPathComponent)", section: .developer, care: .download) }
            default:
                return [entry(dir, name, section: .developer, care: .download)]
            }
        }
        items += group(sdk.path, "Android SDK", "System images for emulators, NDKs and build tools. Android Studio’s SDK Manager downloads them again.",
                       section: .developer, care: .download, symbol: "shippingbox", location: sdk, children: parts)
        return items
    }

    private static func models() -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        let ollama = folder(".ollama/models")
        if exists(ollama) {
            // Models share blobs, so they're listed for what they are and removed together (or with `ollama rm`).
            let manifests = ollama.appendingPathComponent("manifests")
            var listed: [SystemDataItem] = []
            for registry in children(of: manifests) {
                for namespace in children(of: registry) {
                    for model in children(of: namespace) {
                        for tag in children(of: model) {
                            guard let data = try? Data(contentsOf: tag),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            let layers = (json["layers"] as? [[String: Any]] ?? []) + [json["config"] as? [String: Any] ?? [:]]
                            let bytes = layers.reduce(Int64(0)) { $0 + ((($1["size"] as? NSNumber)?.int64Value) ?? 0) }
                            let prefix = namespace.lastPathComponent == "library" ? "" : namespace.lastPathComponent + "/"
                            listed.append(SystemDataItem(id: tag.path, title: "\(prefix)\(model.lastPathComponent):\(tag.lastPathComponent)",
                                                         section: .developer, care: .download, size: bytes, symbol: "brain"))
                        }
                    }
                }
            }
            items += group(ollama.path, "Ollama models", "Models you pulled with Ollama. `ollama pull` downloads one again, and `ollama rm` removes just one.",
                           section: .developer, care: .download, symbol: "brain", location: ollama, children: listed, whole: [ollama],
                           app: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama"))
        }
        let hub = folder(".cache/huggingface/hub")
        items += group(hub.path, "Hugging Face models", "Models and datasets Python libraries downloaded from Hugging Face. They download again on next use.",
                       section: .developer, care: .download, symbol: "brain", location: hub,
                       children: children(of: hub).filter { $0.lastPathComponent.contains("--") }.map { dir in
                           let parts = dir.lastPathComponent.components(separatedBy: "--")
                           return entry(dir, parts.dropFirst().joined(separator: "/"), section: .developer, care: .download)
                       })
        for (path, title) in [(".lmstudio/models", "LM Studio models"), (".cache/lm-studio/models", "LM Studio models")] {
            let url = folder(path)
            if exists(url) {
                items.append(entry(url, title.loc, detail: "Models you downloaded in LM Studio.".loc, section: .developer, care: .download, symbol: "brain"))
            }
        }
        return items
    }

    /// Hidden folders command-line tools keep in the home folder.
    private static let tools: [(path: String, title: String, detail: String, care: SystemDataItem.Care)] = [
        (".gradle", "Gradle", "Downloaded dependencies and build caches.", .download),
        (".rustup", "Rust toolchains", "Rust versions rustup installed.", .download),
        (".cargo", "Cargo", "Rust crates, and tools you installed with cargo.", .download),
        (".npm", "npm", "npm’s download cache.", .rebuilds),
        (".bun", "Bun", "Bun itself and its package cache.", .download),
        (".m2", "Maven", "Downloaded Java dependencies.", .download),
        (".pub-cache", "Dart & Flutter packages", "Packages pub downloaded.", .download),
        (".cocoapods", "CocoaPods", "Pod spec repositories.", .download),
        (".nvm", "nvm", "Node versions installed with nvm.", .download),
        (".pyenv", "pyenv", "Python versions installed with pyenv.", .download),
        (".conda", "Conda", "Conda packages and environments.", .yours),
        ("miniconda3", "Miniconda", "Conda with its environments.", .yours),
        ("anaconda3", "Anaconda", "Conda with its environments.", .yours),
        ("miniforge3", "Miniforge", "Conda with its environments.", .yours),
        (".vscode/extensions", "VS Code extensions", "Extensions you installed in VS Code.", .download),
        (".cursor/extensions", "Cursor extensions", "Extensions you installed in Cursor.", .download),
    ]

    private static func toolchains() -> [SystemDataItem] {
        var found = tools.compactMap { t -> SystemDataItem? in
            let url = folder(t.path)
            return exists(url) ? entry(url, t.title, detail: t.detail.loc, section: .developer, care: t.care) : nil
        }
        // ~/.cache: one folder per tool; Hugging Face is listed with the models.
        found += children(of: folder(".cache")).filter { $0.lastPathComponent != "huggingface" }.map {
            entry($0, "~/.cache/" + $0.lastPathComponent, section: .developer, care: .download)
        }
        return group("tools", "Developer tools & caches", "Toolchains, package downloads and caches command-line tools keep in hidden folders in your home folder.",
                     section: .developer, care: .download, symbol: "terminal", location: nil, children: found)
    }

    // MARK: Home folder

    /// What the home folder holds besides the usual folders and what this page already lists: projects you keep
    /// there, and hidden folders command-line tools make.
    private static func homeFolders() -> [URL] {
        let standard: Set<String> = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies", "Applications", "Public", ".Trash"]
        let listed = Set(tools.compactMap { $0.path.split(separator: "/").first.map(String.init) }
            + [".android", ".ollama", ".cache", ".tart", ".colima", ".lima", "Parallels", "VirtualBox VMs", "Virtual Machines.localized"])
        return children(of: home).filter { url in
            let name = url.lastPathComponent
            return !standard.contains(name) && !listed.contains(name)
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// Hidden folders whose maker is well known.
    private static let hidden: [String: String] = [
        ".codex": "Codex CLI: sessions, logs and plugins.",
        ".claude": "Claude Code: sessions, settings and plugins.",
        ".local": "Programs and data command-line tools installed for you, in ~/.local/bin and ~/.local/share.",
        ".config": "Settings for command-line tools.",
        ".docker": "Docker’s command-line settings.",
        ".expo": "Expo’s command-line cache.",
        ".mint": "Swift tools installed with Mint.",
        ".swiftpm": "Swift Package Manager’s caches.",
        ".pnpm-store": "pnpm’s package store.",
        ".yarn": "Yarn’s cache.",
        ".deno": "Deno and its cache.",
        ".volta": "Node versions installed with Volta.",
        ".sdkman": "Java versions installed with SDKMAN.",
    ]

    private static func homeFolder(_ dir: URL) -> [SystemDataItem] {
        let name = dir.lastPathComponent
        let isHidden = name.hasPrefix(".")
        let care: SystemDataItem.Care = .yours
        let kids = children(of: dir).map { entry($0, $0.lastPathComponent, section: .home, care: care) }
        let size = kids.reduce(0) { $0 + $1.size }
        guard size >= 100_000_000 else { return [] }
        let detail = hidden[name] ?? (isHidden ? "A hidden folder a command-line tool or app made." : "A folder you keep in your home folder. Storage’s categories above don’t include it, so it’s part of System & Other.")
        return [SystemDataItem(id: dir.path, title: name, detail: detail.loc, section: .home, care: care,
                               // A folder you made is yours to sort through; Orbit only offers what's inside.
                               urls: isHidden ? [dir] : [], size: size, symbol: isHidden ? "eye.slash" : "folder", location: dir,
                               children: Array(kids.filter { $0.size >= 100_000_000 }.sorted { $0.size > $1.size }.prefix(30)))]
    }

    // MARK: Virtual machines & backups

    private static func machines(fullDisk: Bool) -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        func vms(_ id: String, _ title: String, in dir: URL, ext: Set<String>, app: String?) {
            let list = children(of: dir).filter { ext.isEmpty || ext.contains($0.pathExtension) }
                .map { entry($0, $0.deletingPathExtension().lastPathComponent, section: .machines, care: .yours, symbol: "server.rack") }
            items += group(id, title, "Virtual machines and their disks. Removing one deletes everything installed in it.",
                           section: .machines, care: .yours, symbol: "server.rack", location: dir, children: list,
                           app: app.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
        }
        if fullDisk {
            vms("utm", "UTM", in: folder("Library/Containers/com.utmapp.UTM/Data/Documents"), ext: ["utm"], app: "com.utmapp.UTM")
            let docker = folder("Library/Containers/com.docker.docker")
            if exists(docker) {
                var item = entry(docker, "Docker", detail: "Docker’s virtual disk: your images, containers, volumes and build cache. Shrink it with `docker system prune`, or Docker › Troubleshoot › Clean / Purge data.".loc,
                                 section: .machines, care: .yours, symbol: "shippingbox", trash: false)
                item.app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker")
                items.append(item)
            }
        }
        vms("parallels", "Parallels", in: folder("Parallels"), ext: ["pvm"], app: "com.parallels.desktop.console")
        vms("vmware", "VMware Fusion", in: folder("Virtual Machines.localized"), ext: ["vmwarevm"], app: "com.vmware.fusion")
        vms("virtualbox", "VirtualBox", in: folder("VirtualBox VMs"), ext: [], app: "org.virtualbox.app.VirtualBox")
        vms("tart", "Tart", in: folder(".tart/vms"), ext: [], app: nil)
        for (path, title) in [(".colima", "Colima"), (".lima", "Lima")] where exists(folder(path)) {
            items.append(entry(folder(path), title, detail: "Linux virtual machines that run your containers.".loc, section: .machines, care: .yours, symbol: "server.rack"))
        }
        return items
    }

    private static func backups() -> [SystemDataItem] {
        let root = folder("Library/Application Support/MobileSync/Backup")
        let list = children(of: root).map { dir -> SystemDataItem in
            let info = NSDictionary(contentsOf: dir.appendingPathComponent("Info.plist"))
            var item = entry(dir, info?["Device Name"] as? String ?? dir.lastPathComponent, section: .machines, care: .yours, symbol: "iphone")
            if let date = info?["Last Backup Date"] as? Date { item.detail = "Backed up %@".loc(date.orbitRelative.loc) }
            return item
        }
        return group(root.path, "iPhone and iPad backups", "Backups Finder made of your devices. Finder › your device › Manage Backups shows the same list.",
                     section: .machines, care: .yours, symbol: "externaldrive.badge.timemachine", location: root, children: list)
    }

    // MARK: macOS

    private static func macOS() -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        func add(_ id: String, _ title: String, _ detail: String, symbol: String, _ urls: [URL], children: [SystemDataItem] = []) {
            let size = urls.reduce(Int64(0)) { $0 + Self.size($1) }
            guard size > 0 else { return }
            items.append(SystemDataItem(id: id, title: title.loc, detail: detail.loc, section: .macOS, care: .macOS, size: size,
                                        symbol: symbol, location: urls.first, children: children))
        }
        add("vm", "Swap and sleep image", "Memory macOS moved to disk when RAM ran short, and the copy it keeps for deep sleep. Restarting shrinks the swap.",
            symbol: "memorychip", [URL(fileURLWithPath: "/private/var/vm")])
        add("logs", "System logs", "Logs and diagnostics macOS writes as it runs. It deletes old ones by itself.", symbol: "doc.text",
            ["/private/var/db/diagnostics", "/private/var/db/uuidtext", "/private/var/db/powerlog", "/private/var/log", "/Library/Logs"].map { URL(fileURLWithPath: $0) })
        add("assets", "Downloaded system assets", "Things macOS downloads as you need them: Apple Intelligence models, voices, fonts, wallpapers.",
            symbol: "arrow.down.circle", [URL(fileURLWithPath: "/System/Library/AssetsV2")])
        let temp = [confstr(_CS_DARWIN_USER_TEMP_DIR), confstr(_CS_DARWIN_USER_CACHE_DIR)].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        let busiest = temp.flatMap(children(of:)).map { entry($0, $0.lastPathComponent, section: .macOS, care: .macOS, trash: false) }
            .filter { $0.size > 100_000_000 }.sorted { $0.size > $1.size }.prefix(8)
        add("temp", "Temporary files", "Scratch files and caches apps are using right now. macOS clears ones untouched for 3 days, and restarting clears more.",
            symbol: "clock", temp, children: Array(busiest))

        let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output.split(separator: "\n").filter { $0.contains("com.apple") }.count
        if snapshots > 0 {
            items.append(SystemDataItem(id: "snapshots", title: "Time Machine snapshots".loc,
                                        detail: "%ld local backups. macOS keeps them until your backup disk is back, and deletes them by itself when space runs low.".loc(snapshots),
                                        section: .macOS, care: .macOS, symbol: "clock.arrow.circlepath"))
        }
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let purgeable = (v?.volumeAvailableCapacityForImportantUsage ?? 0) - Int64(v?.volumeAvailableCapacity ?? 0)
        if purgeable > 500_000_000 {
            items.append(SystemDataItem(id: "purgeable", title: "Purgeable space".loc,
                                        detail: "Space macOS frees on its own when an app needs it: iCloud files it can download again, old snapshots, caches. It already counts as available.".loc,
                                        section: .macOS, care: .macOS, size: purgeable, symbol: "wind"))
        }
        return items
    }

    private static func confstr(_ name: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return Darwin.confstr(name, &buf, buf.count) > 0 ? String(cString: buf) : nil
    }

    /// Folders installed for every account, outside the home folder: listed, removed by the app's own uninstaller.
    private static func shared() -> [SystemDataItem] {
        var items: [SystemDataItem] = []
        for (path, id, title, detail) in [
            ("/Library/Application Support", "library", "Apps’ files for all users", "Installed for every account by apps like Adobe or Logitech. Remove them with that app’s uninstaller."),
            ("/Users/Shared", "users-shared", "Shared folder", "Files every account on this Mac can open; some apps keep downloads and caches here too."),
        ] {
            let root = URL(fileURLWithPath: path)
            let list = children(of: root).filter { !$0.lastPathComponent.hasPrefix("com.apple") && $0.lastPathComponent != "Apple" }
                .map { entry($0, $0.lastPathComponent, section: .apps, care: .yours, trash: false) }
            items += group(id, title, detail, section: .apps, care: .yours, symbol: "person.2", location: root, children: list)
        }
        return items
    }

    // MARK: App data in ~/Library

    struct AppFolder: Sendable {
        enum Kind: String, Sendable {
            case support, cache, container, group, web, saved, logs

            var title: String {
                switch self {
                case .support: "App data"
                case .cache: "Cache"
                case .container: "Sandbox"
                case .group: "Shared data"
                case .web: "Web data"
                case .saved: "Saved windows"
                case .logs: "Logs"
                }
            }

            var care: SystemDataItem.Care { [.support, .container, .group].contains(self) ? .yours : .rebuilds }
        }

        let url: URL
        let kind: Kind
    }

    private static func appFolders(fullDisk: Bool) -> [AppFolder] {
        var roots: [(String, AppFolder.Kind)] = [
            ("Library/Application Support", .support), ("Library/Caches", .cache), ("Library/HTTPStorages", .web),
            ("Library/WebKit", .web), ("Library/Saved Application State", .saved), ("Library/Logs", .logs),
        ]
        // Other apps' containers are behind macOS's "access data from other apps" prompt without Full Disk Access.
        if fullDisk { roots += [("Library/Containers", .container), ("Library/Group Containers", .group)] }
        // Listed elsewhere, or Orbit's own.
        let elsewhere: Set<String> = [
            "Library/Application Support/MobileSync", "Library/Containers/com.docker.docker", "Library/Containers/com.utmapp.UTM",
            "Library/Application Support/Orbit", "Library/Caches/com.lyu.orbit",
        ].reduce(into: []) { $0.insert(folder($1).path) }
        return roots.flatMap { rel, kind in
            children(of: folder(rel)).filter { !elsewhere.contains($0.path) && !DiskSize.isPersonal(path: $0.path) }.map { AppFolder(url: $0, kind: kind) }
        }
    }

    /// Folder names macOS itself uses in ~/Library that don't look like bundle IDs.
    private static let appleNames: Set<String> = [
        "AddressBook", "Animoji", "AppleMediaServices", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "CloudKit",
        "ContextStore", "CoreParsec", "CrashReporter", "DifferentialPrivacy", "DiskImages", "Dock", "FaceTime", "FamilyCircle",
        "FileProvider", "GameKit", "GeoServices", "Knowledge", "Metadata", "SiriTTS", "Spotlight", "SyncServices", "Ubiquity",
        "accountsd", "homeenergyd", "icdd", "identityservicesd", "locationaccessstored", "networkserviceproxy", "videosubscriptionsd",
    ]

    private struct Owner {
        let key: String
        let name: String
        let app: URL?
        let apple: Bool
        /// Looks like a bundle ID nothing installed claims.
        let orphan: Bool
    }

    /// Installed apps by bundle ID and by name, to tell whose a folder is.
    private struct AppIndex {
        var ids: [String: URL] = [:]
        var names: [String: URL] = [:]

        init() {
            for app in Cleanup.installedApps() {
                let bundle = Bundle(url: app.url)
                if let id = app.bundleID?.lowercased() { ids[id] = app.url }
                for name in [app.name, bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                             bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String].compactMap({ $0 }) {
                    names[name.lowercased()] = names[name.lowercased()] ?? app.url
                }
            }
        }

        /// The app with this bundle ID, or with one it starts with ("com.openai.codex.notifications" is Codex's).
        func app(id: String) -> URL? {
            var parts = id.split(separator: ".").map(String.init)
            while parts.count >= 2 {
                let candidate = parts.joined(separator: ".")
                if let url = ids[candidate] ?? (parts.count >= 3 ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) : nil) {
                    return url
                }
                parts.removeLast()
            }
            return nil
        }
    }

    /// Whose a folder is, from its name: a bundle ID ("com.tinyspeck.slackmacgap"), a group with a team or `group.`
    /// prefix ("2DC432GLL2.com.openai.codex", "group.com.apple.notes"), or an app's name ("Code", "Arc").
    private static func owner(_ folder: String, apps: AppIndex, running: Set<String>) -> Owner {
        var id = folder
        if id.hasPrefix("group.") { id.removeFirst(6) }
        if let dot = id.firstIndex(of: "."), id.distance(from: id.startIndex, to: dot) == 10,
           id[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            id = String(id[id.index(after: dot)...])
        }
        let lower = id.lowercased()
        if lower.hasPrefix("com.apple.") || lower == "com.apple" || appleNames.contains(folder) {
            return Owner(key: "apple", name: "macOS", app: nil, apple: true, orphan: false)
        }
        let bundleLike = lower.split(separator: ".").count >= 3 && !lower.contains(" ")
        // "Telegram Desktop" is Telegram's.
        let firstWord = lower.split(separator: " ").first.map(String.init).flatMap { $0 != lower && $0.count >= 4 ? apps.names[$0] : nil }
        if let app = (bundleLike ? apps.app(id: lower) : nil) ?? apps.names[lower] ?? firstWord {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            return Owner(key: app.path, name: name, app: app, apple: false, orphan: false)
        }
        let alive = running.contains { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }
        return Owner(key: lower, name: id, app: nil, apple: false, orphan: bundleLike && !alive)
    }

    private static func owners(of folders: [(AppFolder, Int64)], running: Set<String>) -> [SystemDataItem] {
        let apps = AppIndex()
        var grouped: [String: (owner: Owner, folders: [SystemDataItem])] = [:]
        for (folder, size) in folders where size > 0 {
            let owner = owner(folder.url.lastPathComponent, apps: apps, running: running)
            let path = (folder.url.path as NSString).abbreviatingWithTildeInPath
            let item = SystemDataItem(id: folder.url.path, title: folder.kind.title.loc, detail: path, section: owner.apple ? .macOS : .apps,
                                      care: owner.apple ? .macOS : folder.kind.care, urls: owner.apple ? [] : [folder.url], size: size,
                                      symbol: "folder", location: folder.url)
            grouped[owner.key, default: (owner, [])].folders.append(item)
        }
        return grouped.values.compactMap { owner, folders in
            let size = folders.reduce(0) { $0 + $1.size }
            let kids = folders.sorted { $0.size > $1.size }
            if owner.apple {
                return SystemDataItem(id: "owner:apple", title: "Apple apps and services".loc,
                                      detail: "What macOS and Apple’s apps keep in your Library: Spotlight, Siri, iCloud, Photos analysis and more.".loc,
                                      section: .macOS, care: .macOS, size: size, symbol: "apple.logo",
                                      location: home.appendingPathComponent("Library"), children: Array(kids.filter { $0.size > 50_000_000 }.prefix(12)))
            }
            // Small app folders are noise; anything an uninstalled app left behind is worth seeing.
            guard size >= (owner.orphan ? 1_000_000 : 20_000_000) else { return nil }
            let why = owner.orphan ? "No installed app has this ID. Probably left behind by an app you deleted."
                : owner.app == nil ? "Orbit couldn’t tell which app made this." : nil
            // One folder: say which, since there's no list to open.
            let only = kids.count == 1 ? kids.first.map { "\($0.title) · \($0.detail ?? "")" } : nil
            let detail = [why?.loc, only].compactMap { $0 }.joined(separator: "\n")
            return SystemDataItem(id: "owner:" + owner.key, title: owner.name, detail: detail.isEmpty ? nil : detail,
                                  section: owner.orphan ? .leftovers : .apps, care: kids.map(\.care).max() ?? .yours,
                                  urls: kids.flatMap(\.urls), size: size, symbol: owner.orphan ? "app.dashed" : "questionmark.folder",
                                  app: owner.app, location: kids.first?.location, children: kids.count > 1 ? kids : [])
        }
    }
}
