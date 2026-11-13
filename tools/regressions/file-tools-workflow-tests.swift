import AppKit
@testable import Orbit

/// Run as an app through the background computer harness: these checks open real result windows.
@main @MainActor
struct FileToolsWorkflowTests {
    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FileToolsScratch") as! String)
        let log = root.appendingPathComponent("workflow.log")
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: log)
        Task { @MainActor in
            var failures = 0
            func check(_ condition: Bool, _ name: String) {
                if !condition { failures += 1 }
                let line = "\(condition ? "PASS" : "FAIL") \(name)\n"
                if let handle = try? FileHandle(forWritingTo: log) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                    try? handle.close()
                }
            }
            @MainActor func wait(_ tools: FileTools) async -> Bool {
                let deadline = ContinuousClock.now + .seconds(15)
                while tools.busy && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return !tools.busy
            }
            do {
                let source = folder.appendingPathComponent("pages.pdf")
                var box = CGRect(x: 0, y: 0, width: 80, height: 60)
                let context = CGContext(source as CFURL, mediaBox: &box, nil)!
                for _ in 0..<2 {
                    context.beginPDFPage(nil)
                    context.setFillColor(CGColor(gray: 0.4, alpha: 1))
                    context.fill(box)
                    context.endPDFPage()
                }
                var oversized = CGRect(x: 0, y: 0, width: 4000, height: 4000)
                let data = Data(bytes: &oversized, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
                context.endPDFPage()
                context.closePDF()
                let original = try Data(contentsOf: source)
                let tools = FileTools.shared
                tools.perform(.jpg, on: source)
                check(await wait(tools), "partial conversion finishes")
                let completed = tools.result.files
                let failure = tools.result.failure
                check(completed.count == 2 && failure != nil, "partial conversion retains two pages and the failure")
                if let first = completed.first {
                    let edited = try FileConversion.save(Data(contentsOf: first), beside: first, suffix: " (Edited)", extension: "jpg")
                    tools.saved(edited)
                    check(tools.result.files == completed + [edited] && tools.result.failure == failure,
                          "saving an edit retains every completed page and the failure")
                }
                check(try Data(contentsOf: source) == original, "workflow preserves the original PDF")

                tools.perform(.jpg, on: source)
                let window = NSApp.windows.first { $0.title == "File Tools".loc }
                check(window != nil, "conversion has a result window")
                window?.close()
                check(window?.isVisible == false, "result window can close during conversion")
                check(await wait(tools), "hidden conversion finishes")
                check(window?.isVisible == true && tools.result.files.count == 2 && tools.result.failure != nil,
                      "hidden result window reopens with completed pages and failure")
            } catch {
                check(false, "unexpected workflow error: \(error)")
            }
            let summary = "\(failures == 0 ? "PASS" : "FAIL") workflow: \(failures) failures"
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 100),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = summary
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: summary)
            label.frame = NSRect(x: 20, y: 35, width: 440, height: 30)
            window.contentView?.addSubview(label)
            window.center()
            window.makeKeyAndOrderFront(nil)
            try? Data("\(failures)\n".utf8).write(to: root.appendingPathComponent("workflow.exit"))
        }
        NSApp.run()
    }
}
