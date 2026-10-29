import AppKit

/// Where the user's selection was when a card opened: the app, the focused text element, the
/// selected range and text. 바꾸기 uses it to put the selection back before replacing it, since
/// some apps drop or move it while the card has the keyboard.
@MainActor
struct SelectionAnchor {
    let app: NSRunningApplication
    let element: AXUIElement?
    let window: AXUIElement?
    let range: CFRange?
    /// The selected text, as the app reports it (or as copied, when it doesn't).
    var text: String

    /// Reads the selection in `app` now. `text` is used when Accessibility can't say what's selected.
    static func capture(in app: NSRunningApplication?, text fallback: String? = nil) -> SelectionAnchor? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        var element: AXUIElement?, window: AXUIElement?, range: CFRange?, selected: String?
        if AXIsProcessTrusted() {
            let owner = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(owner, 0.25)
            element = Self.element(owner, kAXFocusedUIElementAttribute)
            window = Self.element(owner, kAXFocusedWindowAttribute)
            if let element {
                AXUIElementSetMessagingTimeout(element, 0.25)
                range = Self.range(of: element)
                selected = Self.string(element, kAXSelectedTextAttribute)
            }
        }
        guard let text = selected.flatMap({ $0.isEmpty ? nil : $0 }) ?? fallback else { return nil }
        return SelectionAnchor(app: app, element: element, window: window, range: range, text: text)
    }

    /// What's selected in the element now; nil when the app won't say.
    var selectedText: String? { element.flatMap { Self.string($0, kAXSelectedTextAttribute) } }

    var value: String? { element.flatMap { Self.string($0, kAXValueAttribute) } }

    /// Focuses the element again and selects the saved range. True when the app took it.
    func restore() -> Bool {
        guard let element else { return false }
        if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        if (Self.copy(element, kAXFocusedAttribute) as? Bool) != true {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        guard var r = range, let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Replaces the selection through Accessibility, and checks the text really changed (some apps
    /// say yes and do nothing).
    func setSelectedText(_ s: String) -> Bool {
        guard let element else { return false }
        let before = value
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, s as CFString) == .success else { return false }
        if let before, let after = value { return after != before && after.contains(s) }
        // No value to compare: it worked if the original is no longer what's selected.
        return selectedText.map { !Self.same($0, text) } ?? false
    }

    /// The same text, give or take spaces around it and line-ending style.
    static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return norm(a) == norm(b)
    }

    // MARK: AX

    private static func copy(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? { copy(e, attr) as? String }

    private static func range(of e: AXUIElement) -> CFRange? {
        guard let v = copy(e, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) && r.length > 0 ? r : nil
    }
}

/// 바꾸기 for both cards: back to the app, the selection put back, then the text replaced, by
/// Accessibility where the app supports it, otherwise by ⌘V. When the selection can't be found
/// again it doesn't paste blindly: the text is left on the clipboard and a toast says so.
@MainActor
enum SelectionReplacer {
    enum Outcome { case replaced, copied }

    static func replace(with output: String, anchor: SelectionAnchor?, app fallback: NSRunningApplication?, feature: String) async -> Outcome {
        let pb = NSPasteboard.general
        guard AXIsProcessTrusted() else {
            write(output, to: pb)
            Toast.show("Copied", symbol: "doc.on.doc.fill", detail: "Allow Accessibility to paste directly")
            SpellLog.write("\(feature) replace path=copied-no-ax")
            return .copied
        }
        let target = anchor?.app ?? fallback
        // Give the keyboard back, and the app its focus.
        if let key = NSApp.keyWindow, key is NSPanel { key.orderOut(nil) }
        if let target, !target.isTerminated, NSWorkspace.shared.frontmostApplication != target {
            if NSApp.isActive { NSApp.yieldActivation(to: target) }
            target.activate()
        }
        for _ in 0..<50 {
            let front = NSWorkspace.shared.frontmostApplication
            if (target == nil || front == target), NSApp.keyWindow == nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(60))
        let bundle = target?.bundleIdentifier ?? "?"

        guard let anchor else {
            await paste(output, pb)
            SpellLog.write("\(feature) replace app=\(bundle) path=paste-no-anchor")
            return .replaced
        }
        let restored = anchor.range != nil && anchor.restore()
        if restored { try? await Task.sleep(for: .milliseconds(30)) }
        let now = anchor.selectedText
        let matches = now.map { SelectionAnchor.same($0, anchor.text) }
        let detail = "app=\(bundle) element=\(anchor.element != nil ? 1 : 0) range=\(anchor.range != nil ? 1 : 0) restored=\(restored ? 1 : 0) match=\(matches.map { $0 ? "1" : "0" } ?? "?")"
        // Spaces around the selection stay: the card worked on the trimmed text.
        let text = now.map { wrapped(output, like: $0) } ?? wrapped(output, like: anchor.text)

        switch matches {
        case true?:
            if anchor.setSelectedText(text) {
                SpellLog.write("\(feature) replace \(detail) path=ax-set")
                return .replaced
            }
            await paste(text, pb)
            SpellLog.write("\(feature) replace \(detail) path=paste-verified")
            return .replaced
        case nil:
            // The app won't say what's selected (no text element, or it doesn't share it): the
            // selection is most likely still there, as it was when the text was copied.
            await paste(text, pb)
            SpellLog.write("\(feature) replace \(detail) path=paste-unverified")
            return .replaced
        case false?:
            write(output, to: pb)
            Toast.show("The selection was lost, so it’s copied", symbol: "doc.on.doc.fill", detail: "Press ⌘V to paste it")
            SpellLog.write("\(feature) replace \(detail) path=copied-selection-lost")
            return .copied
        }
    }

    private static func wrapped(_ s: String, like original: String) -> String {
        let lead = original.prefix { $0.isWhitespace || $0.isNewline }
        let trail = original.reversed().prefix { $0.isWhitespace || $0.isNewline }
        guard lead.count + trail.count < original.count else { return s }
        return String(lead) + s.trimmingCharacters(in: .whitespacesAndNewlines) + String(trail.reversed())
    }

    private static func write(_ s: String, to pb: NSPasteboard) {
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// ⌘V with the text on the clipboard, then the clipboard put back.
    private static func paste(_ s: String, _ pb: NSPasteboard) async {
        let saved = PasteboardSnapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(s, forType: .string)
        item.setData(Data(), forType: PasteboardSnapshot.transient)
        pb.writeObjects([item])
        ClipboardStore.shared.markOwnWrite()
        let ours = pb.changeCount
        Paster.sendPaste()
        // Time for the app to read the clipboard before it's put back.
        try? await Task.sleep(for: .milliseconds(1000))
        if pb.changeCount == ours { saved.restore(to: pb) }
    }
}

/// Which way 바꾸기 went, for diagnosis. Never the text itself.
enum SpellLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Orbit/spell.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        // Keep it small.
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 256_000,
           let all = try? String(contentsOf: url, encoding: .utf8) {
            try? String(all.suffix(128_000)).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
