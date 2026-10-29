import AppKit
import ScreenCaptureKit
import Observation

struct Capture: Identifiable, Hashable {
    let id = UUID()
    let image: NSImage
    let fileURL: URL
    let date = Date()
}

/// Owns the capture lifecycle: permission → frozen snapshot → selection → result.
@MainActor @Observable
final class CaptureService {
    static let shared = CaptureService()
    static let dir = Storage.dir("Captures")

    enum Mode { case area, window, screen, text, scrolling }

    private(set) var recent: [Capture] = []
    private(set) var isCapturing = false
    private var lastArea: (rect: CGRect, screenID: CGDirectDisplayID)?

    private init() { loadRecent() }

    func start(_ mode: Mode) {
        guard !isCapturing, !ScrollingCapture.shared.isRunning else { return }
        guard Permissions.shared.screenCapture || CGPreflightScreenCaptureAccess() else {
            PermissionPrompt.show(.screenCapture)
            return
        }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                switch mode {
                case .screen:
                    let shots = try await snapshots()
                    let screen = NSScreen.active
                    guard let shot = shots.first(where: { $0.screen == screen }) else { return }
                    flash(screen)
                    finish(shot.image, scale: shot.scale)
                case .scrolling:
                    // Pick the area, then capture it live while it's scrolled.
                    let shots = try await snapshots()
                    guard let result = await SelectionOverlay.run(shots: shots, windows: [], startInWindowMode: false, textMode: false),
                          result.rect.width > 0 else { return }
                    ScrollingCapture.shared.begin(rect: result.rect, screenID: result.screenID, scale: result.scale)
                case .area, .window, .text:
                    let shots = try await snapshots()
                    let windows = mode == .window || mode == .area ? try await windowTargets() : []
                    guard let result = await SelectionOverlay.run(shots: shots, windows: windows, startInWindowMode: mode == .window, textMode: mode == .text) else { return }
                    if mode == .text { await recognizeText(result.image) }
                    else {
                        lastArea = (result.rect, result.screenID)
                        finish(result.image, scale: result.scale)
                    }
                }
            } catch {
                Toast.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
            }
        }
    }

    /// Re-captures the last selected rectangle without showing the overlay.
    func repeatLast() {
        guard let last = lastArea else { start(.area); return }
        Task {
            guard let shots = try? await snapshots(),
                  let shot = shots.first(where: { $0.screen.displayID == last.screenID }),
                  let cropped = shot.image.cropping(to: last.rect.applying(.init(scaleX: shot.scale, y: shot.scale)).integral)
            else { return }
            finish(cropped, scale: shot.scale)
        }
    }

    // MARK: Snapshotting

    struct Snapshot {
        let screen: NSScreen
        let image: CGImage
        let scale: CGFloat
    }

    struct WindowTarget {
        let frame: CGRect // Cocoa global coordinates
        let windowID: CGWindowID
        let title: String
        let appName: String
        let scwindow: SCWindow
    }

    private func shareable() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Everything on screen goes in the picture as it is — Orbit's own windows, thumbnails, pins and
    /// popovers too. Only windows caught mid-fade (the Ring closing after you picked Capture) stay out.
    private static func chromeWindowIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.filter { $0.isVisible && $0.alphaValue < 0.99 }.compactMap { CGWindowID(exactly: $0.windowNumber) })
    }

    /// Freezes every display before the overlay appears.
    private func snapshots() async throws -> [Snapshot] {
        let content = try await shareable()
        let chrome = Self.chromeWindowIDs()
        let skip = content.windows.filter { chrome.contains($0.windowID) }
        var result: [Snapshot] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: skip)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(Snapshot(screen: screen, image: image, scale: scale))
        }
        return result
    }

    private func windowTargets() async throws -> [WindowTarget] {
        let content = try await shareable()
        let chrome = Self.chromeWindowIDs()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // CGWindowList is ordered front-to-back; SCShareableContent is not.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = Dictionary(info.enumerated().compactMap { i, w in (w[kCGWindowNumber as String] as? CGWindowID).map { ($0, i) } },
                               uniquingKeysWith: { a, _ in a })
        return content.windows
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
            .filter { w in
                // Orbit's own windows can be picked too; only its chrome sits above layer 0 anyway.
                w.isOnScreen && w.windowLayer == 0 && w.frame.width > 40 && w.frame.height > 40 && !chrome.contains(w.windowID)
            }
            .map { w in
                let f = w.frame
                let cocoa = CGRect(x: f.minX, y: mainHeight - f.maxY, width: f.width, height: f.height)
                return WindowTarget(frame: cocoa, windowID: w.windowID, title: w.title ?? "",
                                    appName: w.owningApplication?.applicationName ?? "", scwindow: w)
            }
    }

    /// Captures a single window on its own — transparent corners, no overlapping windows.
    func captureWindow(_ target: WindowTarget) async throws -> (CGImage, CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: target.scwindow)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = false
        config.captureResolution = .best
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), scale)
    }

    // MARK: Results

    func finish(_ cg: CGImage, scale: CGFloat) {
        let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        let image = NSImage(cgImage: cg, size: size)
        let name = "Orbit \(Self.fileStamp.string(from: Date())).png"
        let url = Self.dir.appendingPathComponent(name)
        if let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
        if Pref.defaults.bool(forKey: Pref.captureSound) { Self.shutter?.stop(); Self.shutter?.play() }
        if Pref.defaults.bool(forKey: Pref.captureAutoCopy) { copy(image) }

        let capture = Capture(image: image, fileURL: url)
        recent.insert(capture, at: 0)
        if recent.count > 30 { recent.removeLast() }
        QuickAccess.shared.add(capture)
    }

    private func recognizeText(_ cg: CGImage) async {
        let codes = OCR.barcodes(cg)
        let text = (try? await OCR.recognize(cg)) ?? ""
        let output = codes.first ?? text
        guard !output.isEmpty else {
            Toast.show("No text found", symbol: "text.viewfinder")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        let words = output.split(whereSeparator: \.isWhitespace).count
        Toast.show(codes.isEmpty ? (words == 1 ? "Copied 1 word".loc : "Copied %ld words".loc(words)) : "Copied QR code".loc,
                   symbol: "text.viewfinder", detail: output.replacingOccurrences(of: "\n", with: " "))
    }

    func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        ClipboardStore.shared.markOwnWrite()
    }

    /// Saves to the user's chosen folder (Desktop by default) and returns the destination.
    @discardableResult
    func save(_ capture: Capture) -> URL? {
        let folder = URL(fileURLWithPath: Pref.defaults.string(forKey: Pref.captureSaveFolder) ?? NSHomeDirectory())
        let dest = folder.appendingPathComponent(capture.fileURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: capture.fileURL, to: dest) } catch { return nil }
        return dest
    }

    func remove(_ capture: Capture) {
        recent.removeAll { $0.id == capture.id }
    }

    private func loadRecent() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recent = files
            .filter { $0.pathExtension == "png" }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            .prefix(30)
            .compactMap { url in NSImage(contentsOf: url).map { Capture(image: $0, fileURL: url) } }
    }

    private func flash(_ screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.animationBehavior = .none
        window.backgroundColor = .white
        window.ignoresMouseEvents = true
        window.alphaValue = 0.0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.05
            window.animator().alphaValue = 0.35
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: { window.orderOut(nil) })
        })
    }

    private static let shutter = NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}

private extension URL {
    var creationDate: Date? { (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate }
}
