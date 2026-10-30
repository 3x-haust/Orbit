import AppKit
import Security
import SwiftUI

/// Updates from the project's GitHub Releases: looks for a newer `vX.Y.Z` tag, downloads its
/// `Orbit-X.Y.Z.zip`, checks the app inside is signed by the same developer as this one, then swaps
/// it in and relaunches. Nothing runs between checks (30s after launch, then every 6 hours).
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    static let repo = "3x-haust/Orbit"
    private static let teamID = "UM52UU4B7L"
    private static let bundleID = "com.lyu.orbit"

    struct Release: Equatable, Codable, Sendable {
        let version: String
        let notes: String
        let page: URL
        let asset: URL
        let size: Int
    }

    enum Status: Equatable {
        case idle, checking, upToDate, noReleases
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    private enum Key {
        static let autoCheck = "updates.autoCheck"
        static let autoInstall = "updates.autoInstall"
        static let lastChecked = "updates.lastChecked"
        static let dismissed = "updates.dismissed"
        static let etag = "updates.etag"
    }

    private(set) var status: Status = .idle
    private(set) var lastChecked: Date?
    private(set) var latest: Release?

    var autoCheck: Bool {
        didSet { Pref.defaults.set(autoCheck, forKey: Key.autoCheck); schedule() }
    }
    var autoInstall: Bool {
        didSet { Pref.defaults.set(autoInstall, forKey: Key.autoInstall) }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    private init() {
        let d = Pref.defaults
        autoCheck = d.object(forKey: Key.autoCheck) as? Bool ?? true
        autoInstall = d.object(forKey: Key.autoInstall) as? Bool ?? false
        lastChecked = d.object(forKey: Key.lastChecked) as? Date
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Running straight out of Xcode's build folder: checking works, replacing the app doesn't make sense.
    var isDevBuild: Bool { Bundle.main.bundlePath.contains("/Build/Products/") }

    var busy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    func start() {
        guard !started else { return }
        started = true
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard started, autoCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.autoCheck, !self.busy else { return }
            self.checkNow(userInitiated: false)
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                let u = Updater.shared
                if u.autoCheck, !u.busy { u.checkNow(userInitiated: false) }
            }
        }
        t.tolerance = 30 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Checking

    /// From the ring or launcher: the General page shows how it goes.
    func checkFromAction() {
        MainWindow.show(.general)
        checkNow(userInitiated: true)
    }

    /// `userInitiated`: someone is looking at the Updates settings, so errors show there and no
    /// prompt pops up; otherwise a found update brings up the prompt (or installs, if allowed).
    func checkNow(userInitiated: Bool) {
        guard !busy else { return }
        status = .checking
        Task {
            do {
                let found = try await Self.fetchLatest()
                lastChecked = Date()
                Pref.defaults.set(lastChecked, forKey: Key.lastChecked)
                handle(found, userInitiated: userInitiated)
            } catch FetchError.noReleases {
                lastChecked = Date()
                status = .noReleases
            } catch {
                UpdateLog.write("check failed: \(error.localizedDescription)")
                status = userInitiated ? .failed(Self.describe(error)) : .idle
            }
        }
    }

    private func handle(_ release: Release, userInitiated: Bool) {
        latest = release
        guard Self.isNewer(release.version, than: currentVersion) else {
            status = .upToDate
            UpdateLog.write("up to date (\(currentVersion), latest \(release.version))")
            return
        }
        status = .available(release)
        UpdateLog.write("update available: \(release.version)")
        if autoInstall, !isDevBuild, !userInitiated {
            install(release)
        } else if !userInitiated, Pref.defaults.string(forKey: Key.dismissed) != release.version {
            UpdatePrompt.show(release)
        }
    }

    /// "Later" on the prompt: don't bring this version up again by itself.
    func dismiss(_ release: Release) {
        Pref.defaults.set(release.version, forKey: Key.dismissed)
        UpdatePrompt.close()
    }

    enum FetchError: LocalizedError {
        case noReleases, rateLimited, badResponse(Int), noAsset, notSigned, notNewer, unzip, cantReplace
        var errorDescription: String? {
            switch self {
            case .noReleases: "No releases yet".loc
            case .rateLimited: "GitHub is limiting requests. Try again in a while.".loc
            case .badResponse(let code): "GitHub answered %ld".loc(code)
            case .noAsset: "This release has no Orbit download".loc
            case .notSigned: "The download isn’t signed by Orbit’s developer, so it wasn’t installed".loc
            case .notNewer: "The download isn’t a newer Orbit".loc
            case .unzip: "Couldn’t unpack the download".loc
            case .cantReplace: "Couldn’t replace Orbit".loc
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? FetchError { return e.errorDescription ?? "" }
        if (error as? URLError)?.code == .notConnectedToInternet { return "You’re offline".loc }
        return error.localizedDescription
    }

    private nonisolated static var cacheURL: URL { Storage.dir("Updates").appendingPathComponent("latest.json") }

    nonisolated static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        r.setValue("Orbit/\(version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// The newest published release. A 304 against the saved ETag reuses the saved answer, which
    /// doesn't count against GitHub's hourly limit.
    nonisolated static func fetchLatest() async throws -> Release {
        var r = request(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        let cached = try? Data(contentsOf: cacheURL)
        if cached != nil, let etag = UserDefaults.standard.string(forKey: Key.etag) {
            r.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        let http = response as? HTTPURLResponse
        let body: Data
        switch http?.statusCode ?? 0 {
        case 200:
            body = data
            try? data.write(to: cacheURL, options: .atomic)
            if let etag = http?.value(forHTTPHeaderField: "ETag") { UserDefaults.standard.set(etag, forKey: Key.etag) }
        case 304:
            guard let cached else { throw FetchError.badResponse(304) }
            body = cached
        case 404:
            throw FetchError.noReleases
        case 403, 429:
            throw FetchError.rateLimited
        case let code:
            throw FetchError.badResponse(code)
        }
        return try parse(body)
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int }
        struct Payload: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard !p.draft, !p.prerelease else { throw FetchError.noReleases }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        let zips = p.assets.filter { $0.name.hasSuffix(".zip") }
        guard let asset = zips.first(where: { $0.name == "Orbit-\(version).zip" }) ?? zips.first(where: { $0.name.hasPrefix("Orbit") })
        else { throw FetchError.noAsset }
        return Release(version: version, notes: p.body ?? "", page: p.html_url, asset: asset.browser_download_url, size: asset.size)
    }

    /// 1.10.0 > 1.9.2; missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    func install(_ release: Release) {
        guard !busy || status == .available(release) else { return }
        guard !isDevBuild else {
            Toast.show("Updates install only in the released app", symbol: "hammer")
            return
        }
        status = .downloading(0)
        Task {
            do {
                let zip = try await Self.download(release) { fraction in
                    Task { @MainActor in
                        if case .downloading = Updater.shared.status { Updater.shared.status = .downloading(fraction) }
                    }
                }
                status = .installing
                let app = try await Task.detached { try Self.unpackAndVerify(zip, version: release.version) }.value
                try replace(with: app)
            } catch {
                UpdateLog.write("install of \(release.version) failed: \(error.localizedDescription)")
                status = .failed(Self.describe(error))
                Toast.show("Update didn’t install", symbol: "exclamationmark.triangle.fill", detail: Self.describe(error))
            }
        }
    }

    private nonisolated static func download(_ release: Release, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let folder = Storage.dir("Updates")
        let destination = folder.appendingPathComponent("Orbit-\(release.version).zip")
        try? FileManager.default.removeItem(at: destination)
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: request(release.asset)).resume()
        }
    }

    /// Unzips next to the download and checks the app: Orbit's bundle id, signed by the same team,
    /// valid all the way down, and actually newer.
    private nonisolated static func unpackAndVerify(_ zip: URL, version: String) throws -> URL {
        let folder = zip.deletingLastPathComponent().appendingPathComponent("unpacked-\(version)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              let name = try FileManager.default.contentsOfDirectory(atPath: folder.path).first(where: { $0.hasSuffix(".app") })
        else { throw FetchError.unzip }
        let app = folder.appendingPathComponent(name)

        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID,
              let found = info["CFBundleShortVersionString"] as? String, found == version
        else { throw FetchError.notNewer }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(found, than: current) else { throw FetchError.notNewer }
        guard signedByUs(app) else { throw FetchError.notSigned }
        return app
    }

    nonisolated static func signedByUs(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Moves the running app to the Trash, puts the new one in its place and relaunches.
    private func replace(with app: URL) throws {
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            // e.g. an admin-owned Applications folder: hand the new app over instead.
            status = .idle
            NSWorkspace.shared.activateFileViewerSelecting([app])
            Toast.show("Drag the new Orbit into Applications", symbol: "arrow.down.app",
                       detail: "Orbit can’t write to its folder, so the update is open in Finder")
            return
        }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: app, to: target)
        } catch {
            if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: target) }
            throw FetchError.cantReplace
        }
        UpdateLog.write("installed; relaunching \(target.path)")
        relaunch(target)
    }

    private func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh", "\(pid)", app.path]
        try? script.run()
        AppQuit.now()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var lastReported = -1.0

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        progress(fraction)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { finish(.failure(Updater.FetchError.badResponse(code))); return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

enum UpdateLog {
    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("updates.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Prompt

/// "Orbit 1.1 is available" — a small card under the menu bar with the release notes.
@MainActor
enum UpdatePrompt {
    private static var panel: FloatingPanel?

    static func show(_ release: Updater.Release) {
        let panel = self.panel ?? FloatingPanel(contentRect: .zero, focusable: true)
        self.panel = panel
        panel.level = .statusBar
        panel.setContent(UpdatePromptView(release: release))
        let size = NSSize(width: 360, height: release.notes.isEmpty ? 150 : 330)
        let screen = NSScreen.active.visibleFrame
        panel.present(at: NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12,
                                 width: size.width, height: size.height))
    }

    static func close() { panel?.dismiss() }
}

private struct UpdatePromptView: View {
    let release: Updater.Release
    @Bindable private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: Brand.logo).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit %@ is available".loc(release.version))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("You have %@".loc(updater.currentVersion))
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            if !release.notes.isEmpty {
                ScrollView {
                    Text(ReleaseNotesText.attributed(release.notes))
                        .font(.system(size: 12)).foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.surface))
            }
            UpdateStatusLine()
            HStack(spacing: 8) {
                Button("Release Notes") {
                    MainWindow.show(.general)
                    ReleaseNotesSheet.open(focus: release.version)
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                Spacer()
                Button("Later") { updater.dismiss(release) }
                    .buttonStyle(PillButtonStyle(prominent: false))
                Button("Install") { updater.install(release) }
                    .buttonStyle(PillButtonStyle())
                    .disabled(updater.busy || updater.isDevBuild)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.canvas))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

}

/// One line of what the updater is doing; empty when there's nothing to say.
struct UpdateStatusLine: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        switch updater.status {
        case .downloading(let f):
            HStack(spacing: 8) {
                ProgressView(value: f).progressViewStyle(.linear).frame(maxWidth: .infinity)
                Text("Downloading %ld%%".loc(Int(f * 100))).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                    .monospacedDigit()
            }
        case .installing:
            Text("Installing…").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Palette.accent)
        default:
            if updater.isDevBuild {
                Text("Development build — installing is off").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
            }
        }
    }
}
