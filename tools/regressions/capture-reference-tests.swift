import AppKit
import SwiftUI
@testable import Orbit

/// Translation uses the real controller and parser, but never sends fixture text to a server.
private final class TranslationFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "translate.googleapis.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"sentences":[{"trans":"매일 조금씩 만들어요."}],"src":"en"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor DelayedText {
    private var continuation: CheckedContinuation<String, Error>?
    private(set) var calls = 0
    var started: Bool { continuation != nil }
    func read() async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: "Late text"); continuation = nil }
}

private struct ReferenceWorkspace: View {
    let showPreview: () -> Void
    @State private var text = ""
    @State private var count = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Writing desk").font(.largeTitle)
            Text("Keep notes beside your work.")
            TextField("Notes", text: $text).textFieldStyle(.roundedBorder)
            Button("Count: \(count)") { count += 1 }
            Button("Capture Preview", action: showPreview)
        }
        .padding(32).frame(width: 600, height: 440).background(Color.white)
    }
}

@main struct CaptureReferenceTests {
    @MainActor static func main() async throws {
        let interactive = CommandLine.arguments.contains("--interactive") || Bundle.main.bundleIdentifier == "com.lyu.orbit.reference-tests"
        guard let path = CommandLine.arguments.dropFirst().first ?? Bundle.main.object(forInfoDictionaryKey: "ReferenceScratchPath") as? String else {
            fatalError("Expected a scratch directory")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else {
            print("SKIP: a logged-in macOS desktop is required")
            exit(2)
        }
        UserDefaults.standard.setVolatileDomain([
            Pref.captureThumbnailSeconds: 0,
            Pref.captureThumbnailCorner: "bottomLeft",
            Pref.translateEngine: "google",
            Pref.translatePrimary: "ko",
            Pref.translateSecondary: "en",
            Pref.translateCloseOnBlur: false
        ], forName: UserDefaults.argumentDomain)
        URLProtocol.registerClass(TranslationFixture.self)
        defer { URLProtocol.unregisterClass(TranslationFixture.self) }
        let image = NSImage(size: NSSize(width: 560, height: 240), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("Reference notes" as NSString).draw(at: NSPoint(x: 32, y: 160), withAttributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.black
            ])
            ("Build a little every day." as NSString).draw(at: NSPoint(x: 32, y: 96), withAttributes: [
                .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black
            ])
            return true
        }
        let url = output.appendingPathComponent("reference.png")
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let originalData = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
        try originalData.write(to: url)
        let capture = Capture(image: image, fileURL: url)

        if interactive {
            let window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 60, y: screen.visibleFrame.minY + 60,
                                                      width: 600, height: 440),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Writing desk"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ReferenceWorkspace {
                QuickAccess.shared.add(capture, keep: true)
            })
            window.orderFront(nil)
            QuickAccess.shared.add(capture, keep: true)
            NSApp.run()
            return
        }

        var passed = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failed += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
            fflush(stdout)
        }
        func settle(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(30))
            }
            return condition()
        }
        // Keep all clipboard types, not just a string, and restore them after the test process.
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        defer {
            pb.clearContents()
            pb.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                values.forEach { item.setData($0.value, forType: $0.key) }
                return item
            })
        }

        QuickAccess.shared.add(capture, keep: true)
        QuickAccess.shared.pin(capture)
        guard let pin = NSApp.windows.compactMap({ $0 as? PinWindow }).first(where: \.isVisible),
              let controls = pin.debugControls else { fatalError("Preview did not create reference controls") }
        check(QuickAccess.shared.items.isEmpty, "pinning replaces the preview")
        check(pin.level == .floating && !pin.hidesOnDeactivate, "reference stays above other apps without hiding on deactivation")
        check(controls.isVisible && controls.canBecomeKey && !controls.ignoresMouseEvents,
              "controls are visible, focusable and interactive")
        check(controls.parent === pin, "controls follow their own reference")
        check(pin.collectionBehavior.contains(.canJoinAllSpaces) && pin.collectionBehavior.contains(.fullScreenAuxiliary),
              "reference retains Spaces and fullscreen behavior")

        pin.setOpacity(0.55)
        check(pin.alphaValue == 0.55 && pin.debugOpacity == 0.55, "opacity updates both image and slider")
        pin.setOpacity(-1)
        check(pin.alphaValue == 0.2, "opacity has a visible lower bound")
        pin.setOpacity(3)
        check(pin.alphaValue == 1, "opacity is capped at full visibility")
        pin.setOpacity(0.55)
        pin.setClickThrough(true)
        check(pin.ignoresMouseEvents && !pin.canBecomeKey && !controls.ignoresMouseEvents,
              "click-through excludes the image, never the control bar")
        check(controls.alphaValue == 1 && pin.alphaValue == 0.55, "controls remain opaque when the image is translucent")
        controls.cancelOperation(nil)
        check(!pin.ignoresMouseEvents && controls.isVisible && pin.isVisible,
              "Escape unlocks the reference without hiding its recovery controls")

        let bounds = NSRect(x: -1440, y: 100, width: 1440, height: 900)
        for (name, frame) in [
            ("center", NSRect(x: -1000, y: 400, width: 560, height: 240)),
            ("bottom edge", NSRect(x: -1000, y: 100, width: 560, height: 240)),
            ("oversized", NSRect(x: -1800, y: -200, width: 2200, height: 1600)),
            ("offscreen", NSRect(x: -2500, y: 1200, width: 560, height: 240))
        ] {
            check(bounds.contains(PinWindow.controlsFrame(for: frame, in: bounds)), "entire control bar stays on screen: \(name)")
        }
        pin.setFrame(screen.visibleFrame.insetBy(dx: -100, dy: -100), display: true)
        check(await settle { screen.visibleFrame.contains(controls.frame) }, "oversized reference keeps live controls inside the screen")

        pb.clearContents(); pb.setString("Clipboard sentinel", forType: .string)
        pin.recognizeText(translate: false)
        await pin.debugTextTask?.value
        let recognized = pb.string(forType: .string) ?? ""
        check(recognized.contains("Reference notes") && recognized.contains("Build a little every day"),
              "Copy Text reads the pinned image with real Vision OCR")
        check(!pin.debugReadingText, "text actions become available after recognition")

        pb.clearContents(); pb.setString("Translation must not copy", forType: .string)
        let beforeTranslation = pb.changeCount
        pin.recognizeText(translate: true)
        await pin.debugTextTask?.value
        check(TranslateController.shared.source == recognized, "translation receives text from the pinned image")
        check(await settle { TranslateController.shared.output == "매일 조금씩 만들어요." },
              "existing translator displays the fixture response")
        check(pb.changeCount == beforeTranslation && pb.string(forType: .string) == "Translation must not copy",
              "translation preserves the clipboard")
        check(pin.isVisible && pin.alphaValue == 0.55 && controls.isVisible, "translation keeps the original reference and opacity")
        TranslateController.shared.hide()

        let emptyStart = pb.changeCount
        pin.debugRecognize = { _ in " \n " }
        pin.recognizeText(translate: false)
        await pin.debugTextTask?.value
        check(!pin.debugReadingText && pb.changeCount == emptyStart, "empty OCR leaves clipboard unchanged and resets progress")
        pin.debugRecognize = { _ in throw NSError(domain: "VisionFixture", code: 1) }
        pin.recognizeText(translate: true)
        await pin.debugTextTask?.value
        check(!pin.debugReadingText && pb.changeCount == emptyStart, "failed OCR leaves clipboard unchanged and resets progress")

        pin.setClickThrough(true)
        pin.unpin()
        check(!pin.isVisible && !controls.isVisible && pin.debugControls == nil, "unpin closes both image and controls")
        check(QuickAccess.shared.items.first?.fileURL == url && QuickAccess.shared.items.first?.image === image,
              "unpin returns the original image and file as a kept preview")
        QuickAccess.shared.debugClear()

        for translate in [false, true] {
            let delayed = DelayedText()
            let closing = PinWindow.pin(image, fileURL: url)
            closing.debugRecognize = { _ in try await delayed.read() }
            closing.recognizeText(translate: translate)
            for _ in 0..<100 {
                if await delayed.started { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            check(await delayed.started, "delayed OCR starts for \(translate ? "translation" : "copy")")
            let job = closing.debugTextTask
            closing.recognizeText(translate: !translate)
            check(closing.debugTextTask != nil && closing.debugReadingText, "both text actions share one running request")
            let source = TranslateController.shared.source, clipboard = pb.changeCount
            closing.close()
            await delayed.finish()
            await job?.value
            check(await delayed.calls == 1, "duplicate text actions do not start another OCR request")
            check(pb.changeCount == clipboard && TranslateController.shared.source == source && !closing.debugReadingText,
                  "closing during OCR prevents late \(translate ? "translation" : "copy") side effects")
        }

        let first = PinWindow.pin(image, fileURL: url), second = PinWindow.pin(image, fileURL: url)
        first.setClickThrough(true)
        second.setOpacity(0.4)
        check(!second.ignoresMouseEvents && first.alphaValue == 1, "multiple references keep independent interaction and opacity")
        first.close()
        check(second.isVisible && second.debugControls?.isVisible == true, "closing one reference leaves the other usable")
        second.debugControls?.cancelOperation(nil)
        check(!second.isVisible && second.debugControls == nil, "Escape in normal controls closes the whole reference")
        check(try Data(contentsOf: url) == originalData, "reference actions leave the source file byte-for-byte unchanged")
        print("capture-reference: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
