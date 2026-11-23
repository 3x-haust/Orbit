import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
@testable import Orbit

/// The notch's Folder tab against a folder this run makes: which tab an open shows, the listing
/// and its order, thumbnails, the drag a tile hands out, and that a tile dragged over the notch
/// isn't taken for a drop on the shelf.
@main struct NotchFolderTests {
    @MainActor static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Expected an artifact directory and optional --screenshots") }
        let screenshots = CommandLine.arguments.dropFirst(2).contains("--screenshots")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        var failed = 0, passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failed += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
            fflush(stdout)
        }
        func settle(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }

        // Fixtures: pictures with known creation dates, a text file, a hidden file, a subfolder.
        let folder = output.appendingPathComponent("Screenshots-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let colors: [NSColor] = [.systemOrange, .systemBlue, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemYellow]
        var made: [(URL, Date)] = []
        for (i, color) in colors.enumerated() {
            let image = NSImage(size: NSSize(width: 320, height: 200), flipped: false) { rect in
                color.setFill(); rect.fill()
                NSColor.white.withAlphaComponent(0.85).setFill()
                NSRect(x: 24, y: 24, width: 200, height: 18).fill()
                NSRect(x: 24, y: 56, width: 140, height: 12).fill()
                return true
            }
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let url = folder.appendingPathComponent("Screenshot 2026-11-2\(i + 1) at 10.0\(i).png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            let date = Date(timeIntervalSinceNow: Double(i - 10) * 3600)
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
            made.append((url, date))
        }
        try "notes".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: folder.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: folder.appendingPathComponent("Old"), withIntermediateDirectories: true)

        // This executable has its own defaults domain; settings go in the volatile argument domain.
        func settings(folder path: String, openTab: String) {
            UserDefaults.standard.setVolatileDomain([
                NotchPrefs.enabled: true, NotchPrefs.hoverOpen: false, NotchPrefs.hideFullScreen: false,
                NotchPrefs.folderPath: path, NotchPrefs.openTab: openTab,
                NotchPrefs.liveMusic: false, NotchPrefs.liveTimer: false, NotchPrefs.liveFocus: false,
                NotchPrefs.liveCharging: false, NotchPrefs.liveAwake: false, NotchPrefs.liveRecording: false,
            ], forName: UserDefaults.argumentDomain)
        }
        NotchPrefs.register()
        let center = NotchCenter.shared, model = NotchFolder.shared
        NotchCenter.debugSpeed = 100
        center.debugRoom = { 64 }

        // No folder: no Folder tab, and an open still lands on Home.
        settings(folder: "", openTab: "folder")
        center.apply()
        check(!center.config.tabs.contains(.folder), "no folder chosen: no Folder tab")
        center.open(on: center.primary)
        check(center.tab == .home, "no folder chosen: \"Folder\" as the open tab falls back to Home")
        center.close()

        // A folder, opening on it.
        settings(folder: folder.path, openTab: "folder")
        center.apply()
        check(center.config.tabs == [.home, .folder, .shelf, .mirror, .timer, .clipboard], "folder chosen: Folder tab after Home")
        try? await Task.sleep(for: .milliseconds(1600)) // past the 1.5s quick-return window
        center.open(on: center.primary, byHover: true)
        check(center.tab == .folder, "hover open shows the Folder tab")

        model.reload()
        check(await settle { if case .files = model.contents { true } else { false } }, "folder lists its files")
        if case .files(let entries) = model.contents {
            let names = entries.map(\.name)
            check(!names.contains(".hidden"), "hidden files are left out")
            check(names.contains("notes.txt") && names.contains("Old"), "other files and subfolders are listed")
            let pictures = entries.filter { $0.name.hasPrefix("Screenshot") }.map(\.url.lastPathComponent)
            check(pictures == made.sorted { $0.1 > $1.1 }.map(\.0.lastPathComponent), "newest first")

            let newest = entries.first { $0.name.hasPrefix("Screenshot") }!
            let thumb = await model.thumbnail(newest, size: CGSize(width: 76, height: 48))
            check(thumb != nil && model.cachedThumbnail(newest) != nil, "Quick Look thumbnail made and cached")

            // The drag a tile starts carries the file itself.
            let provider = newest.provider
            check(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), "tile drag offers a file URL")
            let dragged: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in done.resume(returning: item as? URL) }
            }
            check(dragged?.standardizedFileURL == newest.url.standardizedFileURL, "tile drag hands over the file in place")

            // A tile dragged across the notch on its way out: no switch to the shelf, no drop.
            let drag = NSPasteboard(name: .drag)
            drag.clearContents()
            drag.writeObjects([newest.url as NSURL])
            check(NotchFolder.isOwnDrag(), "a tile's drag is recognised as this folder's")
            center.setDropTargeted(true, on: center.primary)
            check(center.tab == .folder && !center.dropTargeted, "own drag over the notch keeps the Folder tab")
            check(!center.drop([newest.provider]), "own drag dropped on the notch isn't shelved")
            check(Shelf.shared.items.isEmpty, "shelf stays empty")
            // A file from elsewhere still goes to the shelf, as before.
            drag.clearContents()
            drag.writeObjects([output.appendingPathComponent("elsewhere.png") as NSURL])
            check(!NotchFolder.isOwnDrag(), "a file from elsewhere isn't this folder's")
            center.setDropTargeted(true, on: center.primary)
            check(center.tab == .shelf && center.dropTargeted, "a file from elsewhere opens the Shelf, as before")
            center.setDropTargeted(false, on: center.primary)
            drag.clearContents()
            // The drag's end scheduled a close: start over for the picture.
            center.close()
            center.open(on: center.primary, tab: .folder)
        }

        if screenshots {
            try? await Task.sleep(for: .milliseconds(1500)) // thumbnails in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let notch = NSApp.windows.first(where: { $0 is NotchWindow }),
                      let captured = content.windows.first(where: { Int($0.windowID) == notch.windowNumber }) else {
                    throw NSError(domain: "NotchFolderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notch window unavailable"])
                }
                let config = SCStreamConfiguration()
                config.width = Int(notch.frame.width * 2)
                config.height = Int(notch.frame.height * 2)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: captured), configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("notch-folder.png"))
            } catch {
                check(false, "capture: \(error)")
            }
        }
        center.close()

        // An empty folder and one that's gone.
        let empty = output.appendingPathComponent("Empty-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        settings(folder: empty.path, openTab: "folder")
        model.reload()
        check(await settle { model.contents == .empty }, "empty folder reads as empty")
        settings(folder: output.appendingPathComponent("missing").path, openTab: "folder")
        model.reload()
        check(await settle { model.contents == .unreadable }, "missing folder reads as unreadable")

        print("notch-folder-tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
