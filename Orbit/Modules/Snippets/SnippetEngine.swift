import AppKit
import Carbon

/// Expands snippet keywords as they're typed, in any app.
///
/// A listen-only event tap keeps the last few characters typed (it never holds up or changes a key).
/// When they end in a keyword, the keyword is taken back out with ⌫ and the snippet pasted in its
/// place, then the clipboard is put back. In 한글 mode the field holds composed Hangul rather than the
/// keys pressed, so what to delete is checked against the field itself through Accessibility.
@MainActor
final class SnippetEngine {
    static let shared = SnippetEngine()

    /// On its own thread; keys are read on the main thread a moment later, in order.
    nonisolated(unsafe) private static var live: EventTapThread?
    private var buffer = SnippetBuffer()
    /// Bumped by every key; an expansion that finds it moved on gives up.
    private var generation = 0
    private var busy = false
    private var observers: [Any] = []
    private var source: Source = .plain

    /// Events Orbit posts itself carry this, so the tap doesn't read them as typing.
    private static let marker: Int64 = 0x0B17_5E1F

    /// How the current keyboard turns keys into text.
    private enum Source { case plain, korean2Set, other }

    // MARK: Lifecycle

    /// Starts listening when snippets are on and there's something to expand; stops otherwise.
    /// Safe to call any time (Accessibility may have just been granted).
    func start() {
        observe()
        let store = SnippetStore.shared
        guard store.enabled, !store.active.isEmpty else { stop(); return }
        guard Self.live == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                SnippetEngine.live?.reenable()
            } else if let copy = event.copy() {
                nonisolated(unsafe) let e = copy
                DispatchQueue.main.async { MainActor.assumeIsolated { SnippetEngine.shared.handle(type, e) } }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback, userInfo: nil) else {
            log("couldn’t create the event tap")
            return
        }
        Self.live = EventTapThread(port: port, name: "Orbit snippets")
        refreshSource()
        log("listening")
    }

    func stop() {
        guard let live = Self.live else { return }
        live.stop()
        Self.live = nil
        buffer.reset()
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SnippetEngine.shared.buffer.reset() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SnippetEngine.shared.start() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SnippetEngine.shared.refreshSource() }
        })
    }

    private func refreshSource() {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { source = .plain; return }
        func property(_ key: CFString) -> String? {
            TISGetInputSourceProperty(current, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        }
        let id = property(kTISPropertyInputSourceID) ?? ""
        let type = property(kTISPropertyInputSourceType) ?? ""
        if type == (kTISTypeKeyboardLayout as String) { source = .plain }
        else if id.contains("2SetKorean") { source = .korean2Set }
        else if id.hasSuffix(".Roman") || id.hasSuffix("ABC") { source = .plain }
        else { source = .other }
    }

    // MARK: Typing

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard type == .keyDown else { buffer.reset(); return }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return }
        generation &+= 1
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || IsSecureEventInputEnabled() {
            buffer.reset()
            return
        }
        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Delete: buffer.backspace(); return
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete:
            buffer.reset(); return
        default: break
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let typed = String(utf16CodeUnits: chars, count: length)
        guard !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }) else { buffer.reset(); return }
        buffer.type(typed)
        guard !busy else { return }

        let store = SnippetStore.shared
        let composing = source != .plain
        let match = buffer.match(store.active.map(\.keyword), trigger: store.trigger) { keyword in
            // Mid-syllable, ⌫ takes back a jamo, not a letter: wait for the space that finishes it.
            composing && Dubeolsik.endsComposing(keyword)
        }
        guard let match, let snippet = store.active.first(where: { $0.keyword == match.keyword }) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, allowed(in: app) else { return }
        buffer.reset()
        let gen = generation
        Task { await expand(snippet, match: match, in: app, generation: gen) }
    }

    private func allowed(in app: NSRunningApplication) -> Bool {
        let store = SnippetStore.shared
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, let id = app.bundleIdentifier else { return false }
        if store.excludedApps.contains(id) { return false }
        if !store.inTerminals, SnippetStore.terminals.contains(id) { return false }
        return true
    }

    // MARK: Expanding

    private func expand(_ snippet: Snippet, match: SnippetBuffer.Match, in app: NSRunningApplication, generation gen: Int) async {
        busy = true
        defer { busy = false }
        // The listen-only tap sees a key before the app does; let the app (and its input method) catch up.
        try? await Task.sleep(for: .milliseconds(source == .plain ? 45 : 80))
        guard generation == gen else { log("typing went on; skipped \(snippet.keyword)"); return }

        let delimiter = match.delimiter.map(String.init) ?? ""
        let literal = snippet.keyword + delimiter
        let composed = Dubeolsik.compose(snippet.keyword) + delimiter
        let count: Int
        let length = max(literal.count, composed.count) + 2
        var before = textBeforeCaret(length: length)
        if let b = before, !b.hasSuffix(literal), !b.hasSuffix(composed) {
            // Some apps update what they report a beat after the key lands.
            try? await Task.sleep(for: .milliseconds(70))
            guard generation == gen else { return }
            before = textBeforeCaret(length: length)
        }
        if let before {
            if before.hasSuffix(literal) { count = literal.count }
            else if before.hasSuffix(composed) { count = composed.count }
            else { log("field doesn’t end with \(snippet.keyword); left alone"); return }
        } else {
            switch source {
            case .plain: count = literal.count
            case .korean2Set: count = composed.count
            case .other:
                // Can't see the field and can't tell what the input method made of the letters.
                guard !Dubeolsik.hasLetters(snippet.keyword) else { log("can’t verify \(snippet.keyword) with this input source"); return }
                count = literal.count
            }
        }
        await insert(snippet, into: app, deleting: count, trailing: delimiter)
    }

    /// Puts a snippet's text where the user is typing, first deleting `deleting` characters before the caret.
    /// Asks for `{input:…}` fields first; cancelling leaves everything as it was.
    func insert(_ snippet: Snippet, into app: NSRunningApplication?, deleting: Int = 0, trailing: String = "") async {
        let store = SnippetStore.shared
        let pb = NSPasteboard.general
        var ctx = SnippetTemplate.Context()
        ctx.clipboard = pb.string(forType: .string) ?? ""
        ctx.lookup = { store.content(named: $0) }
        let fields = SnippetTemplate.inputs(in: snippet.content, lookup: ctx.lookup)
        if !fields.isEmpty {
            guard let values = await SnippetInputPrompt.ask(title: snippet.name.isEmpty ? snippet.keyword : snippet.name, fields: fields) else { return }
            ctx.inputs = values
        }
        let rendered = SnippetTemplate.render(snippet.content, ctx)
        // A delimiter after a {cursor} would land at the end, away from where the caret goes.
        let text = rendered.text + (rendered.cursorFromEnd > 0 ? "" : trailing)

        guard await focus(app) else { return }
        if deleting > 0 {
            post(kVK_Delete, times: deleting)
            try? await Task.sleep(for: .milliseconds(30))
        }

        let saved = Self.snapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ours = pb.changeCount
        guard Paster.paste(into: app) else { return } // no Accessibility: the text stays copied, and Paster says so
        store.markUsed(snippet.id)
        log("expanded \(snippet.keyword.isEmpty ? snippet.name : snippet.keyword)")

        if rendered.cursorFromEnd > 0 {
            try? await Task.sleep(for: .milliseconds(160))
            post(kVK_LeftArrow, times: rendered.cursorFromEnd)
        }
        // Give the app time to read the clipboard before it's put back.
        try? await Task.sleep(for: .milliseconds(650))
        if pb.changeCount == ours { Self.restore(saved, to: pb) }
    }

    /// Waits until `app` is in front with no Orbit panel holding the keyboard (the input prompt or
    /// the picker may just have closed).
    private func focus(_ app: NSRunningApplication?) async -> Bool {
        if let key = NSApp.keyWindow, key is NSPanel { key.orderOut(nil) }
        if let app, !app.isTerminated, NSWorkspace.shared.frontmostApplication != app {
            if NSApp.isActive { NSApp.yieldActivation(to: app) }
            app.activate()
        }
        for _ in 0..<40 {
            let front = NSWorkspace.shared.frontmostApplication
            if (app == nil || front == app), NSApp.keyWindow == nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(40))
        return app.map { !$0.isTerminated } ?? true
    }

    private func post(_ key: Int, times: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<times {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key), keyDown: down)
                e?.flags = []
                e?.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Field & clipboard

    /// The characters just before the caret in the focused text field, if the app exposes them.
    private func textBeforeCaret(length: Int) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        let start = max(0, range.location - length)
        var want = CFRange(location: start, length: range.location - start)
        guard want.length > 0, let param = AXValueCreate(.cfRange, &want) else { return nil }
        var result: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &result) == .success,
           let s = result as? String {
            return s
        }
        // Some fields only hand over their whole value.
        var whole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &whole) == .success, let s = whole as? String else { return nil }
        let utf16 = Array(s.utf16)
        guard range.location <= utf16.count else { return nil }
        return String(utf16CodeUnits: Array(utf16[start..<range.location]), count: range.location - start)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in types { item.setData(data, forType: t) }
            // The user's own clip coming back — not a new copy for the history.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            return item
        }
        pb.writeObjects(items)
    }

    private func log(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("snippets.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
