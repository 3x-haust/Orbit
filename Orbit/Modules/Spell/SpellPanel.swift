import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Select text anywhere → ⌥⇧K (or the Ring, the launcher, ⌘C three times) → a card next to the
/// pointer with the corrected text, every fix marked in place and listed below to keep or drop.
/// The translator's sibling: same card, same placement, and a switch between the two.
@MainActor @Observable
final class SpellController {
    static let shared = SpellController()

    enum Phase: Equatable { case idle, working, done(SpellResult), failed(String) }

    var source = ""
    var phase: Phase = .idle
    var engine: SpellEngine = .apple
    /// Edits the user keeps; the rest stay as they were written.
    var accepted: Set<Int> = []
    /// The suggestion picked for an edit with several (index into its options; 0 when absent).
    var choices: [Int: Int] = [:]
    /// The web checker waiting on the user's OK, while the card asks for it.
    var consent: SpellEngine?
    /// The text is Korean: the engine menu lists the Korean checkers.
    var korean = false
    /// Shown after a replace when the card stays open.
    var replaced = false
    /// There's a selection in another app to paste over: not for text typed into Orbit, and not
    /// once a replace has used it up.
    var canReplace = false

    /// The app the text came from, where 바꾸기 pastes.
    @ObservationIgnored private var app: NSRunningApplication?
    /// The selection as it was when the card opened, put back before 바꾸기.
    @ObservationIgnored private var selection: SelectionAnchor?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var anchor: NSRect?
    @ObservationIgnored private(set) lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.level = .floating
        p.setContent(SpellCard(model: self))
        p.onEscape = { [weak self] in self?.hide(); return true }
        p.onResignKey = { [weak self] in
            guard Pref.defaults.bool(forKey: Pref.translateCloseOnBlur), self?.pasting == false else { return }
            self?.hide()
        }
        return p
    }()
    @ObservationIgnored private var pasting = false

    static var enabled: Bool { Pref.defaults.bool(forKey: Pref.spellEnabled) }

    static var languageToolAccount: SpellChecker.Account {
        get { .init(user: Keychain.get("languagetool.user") ?? "", key: Keychain.get("languagetool") ?? "") }
        set { Keychain.set(newValue.user, for: "languagetool.user"); Keychain.set(newValue.key, for: "languagetool") }
    }

    static var ignored: [String] {
        get { Pref.defaults.stringArray(forKey: Pref.spellIgnored) ?? [] }
        set { Pref.defaults.set(newValue, forKey: Pref.spellIgnored) }
    }

    /// The engine picked in settings for text that isn't Korean; Apple Intelligence when nothing
    /// is picked and it's there.
    static var pickedEngine: SpellEngine {
        let e = SpellEngine(rawValue: Pref.defaults.string(forKey: Pref.spellEngine) ?? "") ?? .preferred
        return e.isWeb ? .preferred : e
    }

    /// For Korean: Daum once the user has agreed to the web checkers, until then Apple Intelligence.
    static var koreanEngine: SpellEngine {
        let e = SpellEngine(rawValue: Pref.defaults.string(forKey: Pref.spellKoreanEngine) ?? "")
        if let e, e != .languageTool, !e.isWeb || webAllowed { return e }
        return webAllowed ? .daum : .preferred
    }

    static var webAllowed: Bool {
        get { Pref.defaults.bool(forKey: Pref.spellWebConsent) }
        set { Pref.defaults.set(newValue, forKey: Pref.spellWebConsent) }
    }

    static var combine: Bool { Pref.defaults.bool(forKey: Pref.spellCombine) }

    static var setup: SpellChecker.Setup {
        let engine = pickedEngine
        return SpellChecker.Setup(engine: engine, korean: koreanEngine, web: webAllowed, combine: combine, ignored: ignored,
                                  account: engine == .languageTool ? languageToolAccount : .init())
    }

    /// The engine the settings pick for this text.
    static func engine(for text: String) -> SpellEngine {
        SpellChecker.language(of: text) == "ko" ? koreanEngine : pickedEngine
    }

    // MARK: Opening

    /// Shortcut, Ring, launcher: the selection in the app the user is in.
    func checkSelection() {
        guard Self.enabled else { Toast.show("Spell check is off", symbol: "textformat.abc.dottedunderline", detail: "Turn it on in Orbit › Spelling"); return }
        let front = NSWorkspace.shared.frontmostApplication
        // In one of Orbit's own fields: its selection, nothing to paste back into.
        if NSApp.isActive, let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.selectedRange().length > 0 {
            let text = (field.string as NSString).substring(with: field.selectedRange())
            show(text, from: NSRunningApplication.current)
            return
        }
        let app = front.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 } ?? Paster.lastExternal
        // Where the selection is, before the card takes the keyboard.
        let anchor = SelectionAnchor.capture(in: app)
        Task {
            var selection = anchor
            if selection == nil, let copied = await SelectionReader.read(from: app) {
                selection = SelectionAnchor.capture(in: app, text: copied)
            }
            guard let text = selection?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                Toast.show("Select some text first", symbol: "textformat.abc.dottedunderline")
                return
            }
            show(text, from: app, selection: selection)
        }
    }

    /// ⌘C three times: the text is already on the clipboard.
    func checkClipboard() {
        guard Self.enabled else { return }
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            Toast.show("Copy some text first", symbol: "textformat.abc.dottedunderline")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        show(text, from: front, selection: SelectionAnchor.capture(in: front, text: text))
    }

    /// - Parameter frame: where the card goes instead of next to the pointer (the translator's card,
    ///   when switching over from it).
    /// - Parameter app: where the text came from; nil for the app the user was last in, Orbit itself
    ///   for text typed into Orbit (then there's nothing to replace).
    func show(_ text: String, from app: NSRunningApplication? = nil, at frame: NSRect? = nil, selection: SelectionAnchor? = nil) {
        let own = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        self.app = own ? nil : (selection?.app ?? app ?? Paster.lastExternal)
        self.selection = own ? nil : selection
        canReplace = self.app != nil
        source = String(text.prefix(SpellChecker.limit))
        korean = SpellChecker.language(of: source) == "ko"
        engine = korean ? Self.koreanEngine : Self.pickedEngine
        consent = nil
        replaced = false
        anchor = frame
        SpellChecker.prewarm()
        present()
        run()
    }

    func run() {
        job?.cancel()
        let text = source, setup = Self.setup
        consent = nil
        phase = .working
        resize(for: .working)
        job = Task {
            let next: Phase
            do {
                let result = try await SpellChecker.check(text, setup: setup)
                accepted = Set(result.edits.filter(\.confident).map(\.id))
                choices = [:]
                next = .done(result)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                next = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            resize(for: next)
            withAnimation(.easeOut(duration: 0.22)) { phase = next }
        }
    }

    /// Switches this language's engine. A web checker asks for the user's OK the first time.
    func use(_ engine: SpellEngine) {
        if engine.isWeb, !Self.webAllowed {
            withAnimation(.spring(duration: 0.3)) { consent = engine }
            resize(for: phase)
            return
        }
        self.engine = engine
        Pref.defaults.set(engine.rawValue, forKey: korean || engine.isWeb ? Pref.spellKoreanEngine : Pref.spellEngine)
        run()
    }

    /// The user agreed to the web checkers.
    func allowWeb() {
        guard let engine = consent else { return }
        Self.webAllowed = true
        withAnimation(.spring(duration: 0.3)) { consent = nil }
        use(engine)
    }

    func declineWeb() {
        Pref.defaults.set(true, forKey: Pref.spellWebOfferDismissed)
        withAnimation(.spring(duration: 0.3)) { consent = nil }
        resize(for: phase)
    }

    func setCombine(_ on: Bool) {
        Pref.defaults.set(on, forKey: Pref.spellCombine)
        run()
    }

    func toggle(_ edit: SpellEdit) {
        withAnimation(.spring(duration: 0.25)) {
            if accepted.contains(edit.id) { accepted.remove(edit.id) } else { accepted.insert(edit.id) }
        }
    }

    /// Picks one of an edit's suggestions, and keeps the edit.
    func choose(_ edit: SpellEdit, _ option: Int) {
        withAnimation(.spring(duration: 0.25)) {
            choices[edit.id] = option
            accepted.insert(edit.id)
        }
    }

    var result: SpellResult? { if case .done(let r) = phase { r } else { nil } }
    var output: String? { result?.text(accepting: accepted, choices: choices) }

    /// Korean checked on the device, and the user hasn't said yes or no to the web checkers yet.
    var offersWeb: Bool {
        guard let r = result, r.language == "ko", !r.engine.isWeb, !Self.webAllowed, consent == nil else { return false }
        return !Pref.defaults.bool(forKey: Pref.spellWebOfferDismissed)
    }

    func copyResult() {
        guard let output else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        hide()
        Toast.show("Corrected text copied", symbol: "doc.on.doc.fill")
    }

    /// Pastes the corrected text over the selection it came from, then puts the clipboard back.
    func replaceSelection() {
        guard let output, canReplace else { return }
        job?.cancel()
        let closing = Pref.defaults.bool(forKey: Pref.spellCloseAfterReplace)
        let anchor = selection, app = app
        pasting = true
        panel.orderOut(nil) // no fade: the panel has to let go of the keyboard first
        Task {
            let outcome = await SelectionReplacer.replace(with: output, anchor: anchor, app: app, feature: "spell")
            pasting = false
            guard outcome == .replaced, !closing else { return }
            selection = nil
            // Stay up, without taking the keyboard back, and show the text as it is now. The
            // selection is gone, so there's nothing left to replace.
            source = output
            replaced = true
            canReplace = false
            panel.orderFrontRegardless()
            run()
        }
    }

    /// Over to the translator with the same text, in the same spot.
    func switchToTranslate() {
        let frame = panel.isVisible ? panel.frame : nil
        let text = source
        job?.cancel()
        panel.orderOut(nil)
        TranslateController.shared.show(text, at: frame, selection: canReplace ? selection : nil)
    }

    func hide() {
        job?.cancel()
        panel.dismiss()
    }

    // MARK: Placement (as the translator's card)

    static let width: CGFloat = 440

    private func present() {
        let size = NSSize(width: Self.width, height: estimatedHeight(for: .working))
        if let anchor, !panel.isVisible {
            // Switching over: same top-left as the card it replaces, shown without a rise.
            let frame = NSRect(x: anchor.minX, y: anchor.maxY - size.height, width: size.width, height: size.height)
            panel.setFrame(fitted(frame), display: false)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.active.visibleFrame
        var origin = NSPoint(x: mouse.x - 40, y: mouse.y - size.height - 18)
        if origin.y < screen.minY + 8 { origin.y = mouse.y + 18 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        if panel.isVisible {
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            setPanelFrame(fitted(frame))
        }
        else { panel.present(at: fitted(NSRect(origin: origin, size: size))) }
    }

    private func resize(for phase: Phase, extra: CGFloat = 0) {
        guard panel.isVisible else { return }
        var frame = panel.frame
        let height = estimatedHeight(for: phase) + extra
        frame.origin.y += frame.height - height
        frame.size.height = height
        setPanelFrame(fitted(frame))
    }

    private func fitted(_ frame: NSRect) -> NSRect {
        let screen = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.active).visibleFrame.insetBy(dx: 8, dy: 8)
        var f = frame
        f.size.height = min(f.height, screen.height)
        if f.minY < screen.minY { f.origin.y = screen.minY }
        if f.maxY > screen.maxY { f.origin.y = screen.maxY - f.height }
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        return f
    }

    private func setPanelFrame(_ frame: NSRect) {
        guard panel.isVisible, panel.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func estimatedHeight(for phase: Phase) -> CGFloat {
        var h = SpellCard.height(for: phase, source: source, fontSize: CGFloat(Pref.defaults.double(forKey: Pref.translateFontSize)))
        if consent != nil { return max(h, 49 + 1 + 44 + 214) }
        if case .done(let r) = phase, r.language == "ko", !r.engine.isWeb, !Self.webAllowed, !Pref.defaults.bool(forKey: Pref.spellWebOfferDismissed) { h += 46 }
        return h
    }
}

// MARK: - Reading the selection

/// The selected text in another app: from Accessibility when the app shares it (the clipboard
/// isn't touched), otherwise by sending ⌘C and putting the clipboard back right after.
@MainActor
enum SelectionReader {
    /// Marks Orbit's own ⌘C so the ⌘C ⌘C listener doesn't count it.
    static let marker: Int64 = 0x0B17_5E11

    static func read(from app: NSRunningApplication?) async -> String? {
        if let text = accessibilitySelection(app), !text.isEmpty { return text }
        return await copySelection(app)
    }

    private static func accessibilitySelection(_ app: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let owner = app.map { AXUIElementCreateApplication($0.processIdentifier) } ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(owner, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(owner, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copySelection(_ app: NSRunningApplication?) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let pb = NSPasteboard.general
        let saved = PasteboardSnapshot(pb)
        let before = pb.changeCount
        TranslateController.shared.quiet(for: 1.5)
        // The keyboard back to the app (from the launcher, say), then ⌘C.
        if let key = NSApp.keyWindow, key is NSPanel { key.orderOut(nil) }
        if let app, !app.isTerminated, NSWorkspace.shared.frontmostApplication != app {
            if NSApp.isActive { NSApp.yieldActivation(to: app) }
            app.activate()
            for _ in 0..<25 where NSWorkspace.shared.frontmostApplication != app || NSApp.keyWindow != nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        // Let go of the shortcut's own keys first, or the app sees ⌥⇧⌘C.
        for _ in 0..<25 where !NSEvent.modifierFlags.intersection([.option, .shift, .control, .command]).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        postCopy()
        var text: String?
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before { text = pb.string(forType: .string); break }
        }
        guard pb.changeCount != before else { return nil } // nothing was selected
        ClipboardStore.shared.markOwnWrite() // the selection isn't a copy for the history
        saved.restore(to: pb)
        TranslateController.shared.quiet(for: 0.8)
        return text
    }

    private static func postCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        let c = CGKeyCode(kVK_ANSI_C), cmd = CGKeyCode(kVK_Command)
        for (key, down) in [(cmd, true), (c, true), (c, false), (cmd, false)] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = (key == cmd && !down) ? [] : .maskCommand
            e?.setIntegerValueField(.eventSourceUserData, value: marker)
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// Everything on the clipboard, to put back after Orbit borrowed it.
struct PasteboardSnapshot {
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor init(_ pb: NSPasteboard) {
        items = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    @MainActor func restore(to pb: NSPasteboard) {
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items.map { types in
                let item = NSPasteboardItem()
                for (t, data) in types { item.setData(data, forType: t) }
                // The user's own clip coming back — not a new copy for the history.
                item.setData(Data(), forType: Self.transient)
                return item
            })
        }
        ClipboardStore.shared.markOwnWrite()
    }
}

// MARK: - Card

struct SpellCard: View {
    @Bindable var model: SpellController
    @AppStorage(Pref.translateFontSize) private var fontSize = 16.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 18)
            content
            footer
        }
        .background(WindowDragArea())
        .focusEffectDisabled()
        .modifier(PanelShell())
        .background(SpellKeys(model: model))
    }

    private var header: some View {
        HStack(spacing: 8) {
            PanelModeSwitch(spelling: true, translate: { model.switchToTranslate() }, spell: {})
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                Text(languageName).foregroundStyle(Palette.ink)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Palette.raised))
            Spacer()
            Menu {
                ForEach(model.korean ? SpellEngine.korean : SpellEngine.others) { e in
                    Button { model.use(e) } label: {
                        if e == model.engine { Label(e.title.loc, systemImage: "checkmark") }
                        else if e.isWeb, !SpellController.webAllowed { Label(e.title.loc, systemImage: "network") }
                        else { Text(e.title.loc) }
                    }
                    .disabled(!e.status.ready)
                }
                if model.korean, SpellController.webAllowed {
                    Divider()
                    Toggle("Combine Daum and Naver".loc, isOn: Binding(get: { SpellController.combine }, set: { model.setCombine($0) }))
                }
            } label: {
                Text(engineLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Button { model.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                    .frame(width: 22, height: 22).background(Circle().fill(Palette.raised))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
        .overlay(alignment: .top) {
            Capsule().fill(Palette.inkSecondary.opacity(0.35)).frame(width: 32, height: 4).padding(.top, 5)
                .allowsHitTesting(false)
        }
        .background(WindowDragArea())
        .help("Drag to move".loc)
    }

    private var languageName: String {
        guard let code = model.result?.language ?? SpellChecker.language(of: model.source) else { return "Auto".loc }
        return TranslationLanguage.named(code)
    }

    /// The engine that did the work (Apple Spelling when it stepped in).
    private var engineLabel: String {
        model.result?.engineLabel ?? model.engine.title.loc
    }

    @ViewBuilder private var content: some View {
        if let engine = model.consent {
            WebConsent(engine: engine, allow: { model.allowWeb() }, decline: { model.declineWeb() })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
        } else {
            phaseContent
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .idle, .working:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<TranslateController.placeholderLines(for: model.source), id: \.self) { i in
                    Shimmer().frame(width: i == 2 ? 180 : nil, height: fontSize * 0.9)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.identity)
        case .done(let r):
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(SpellMarkup.text(r, accepted: model.accepted, choices: model.choices))
                        .font(.system(size: fontSize))
                        .foregroundStyle(Palette.ink)
                        .lineSpacing(fontSize * 0.2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)
                if let notice = r.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 18).padding(.bottom, 8)
                }
                if model.offersWeb {
                    WebOffer(try: { model.use(.daum) }, dismiss: { model.declineWeb() })
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
                if r.edits.isEmpty {
                    Text((model.replaced ? "Replaced — nothing left to fix ✓" : "Nothing to fix ✓").loc)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                        .padding(.horizontal, 18).padding(.bottom, 12)
                } else {
                    Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 18)
                    CorrectionList(result: r, accepted: model.accepted, choices: model.choices,
                                   toggle: { model.toggle($0) }, choose: { model.choose($0, $1) })
                        .frame(height: SpellCard.listHeight(r))
                }
            }
            .transition(.opacity)
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.system(size: 13)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Try Again") { model.run() }.buttonStyle(PillButtonStyle(prominent: false))
                        if model.engine != .apple { Button("Use Apple Spelling") { model.use(.apple) }.buttonStyle(PillButtonStyle(prominent: false)) }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let r = model.result, !r.edits.isEmpty {
                Text(r.edits.count == 1 ? "1 fix".loc : "%ld fixes".loc(r.edits.count))
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                if model.accepted.count != r.edits.count {
                    Text("· %ld kept".loc(model.accepted.count)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer()
            Button { model.run() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28).background(Circle().fill(Palette.raised))
            }
            .buttonStyle(.plain)
            .help("Check again (⌘R)".loc)
            .disabled(model.phase == .working)
            Group {
                CardFooterButton(title: "Replace", keys: "⌘↩") { model.replaceSelection() }
                    .disabled(!model.canReplace)
                    .opacity(model.canReplace ? 1 : 0.4)
                    .help(model.canReplace ? "" : "Nothing selected to replace — copy it instead".loc)
                CardFooterButton(title: "Copy", keys: "↩ C", prominent: true) { model.copyResult() }
            }
            .disabled(model.output == nil)
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background { ZStack { Palette.surface.opacity(0.6); WindowDragArea() } }
    }

    // MARK: Height

    static func listHeight(_ r: SpellResult) -> CGFloat {
        let rows = r.edits.reduce(CGFloat(0)) { h, e in
            let reason: CGFloat = e.reason.map { $0.count > 44 ? 32 : 17 } ?? 0
            return h + 36 + reason + (e.options.count > 1 ? 28 : 0)
        }
        return min(rows + 12, 260)
    }

    static func height(for phase: SpellController.Phase, source: String, fontSize size: CGFloat) -> CGFloat {
        func width(_ line: Substring) -> CGFloat {
            line.unicodeScalars.reduce(0) { w, c in
                let wide = (0x1100...0x11FF).contains(c.value) || (0x2E80...0x9FFF).contains(c.value)
                    || (0xAC00...0xD7AF).contains(c.value) || (0xFF00...0xFFEF).contains(c.value)
                return w + size * (wide ? 0.95 : 0.52)
            }
        }
        func lines(_ s: String, max cap: Int) -> Int {
            min(cap, s.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, Int(ceil(width($1) / 392))) })
        }
        let chrome: CGFloat = 49 + 1 + 44 // header, hairline, footer
        switch phase {
        case .idle, .working:
            return chrome + 28 + CGFloat(TranslateController.placeholderLines(for: source)) * (size * 0.9 + 8)
        case .failed:
            return chrome + 96
        case .done(let r):
            // As marked up: struck-out letters and ␣ marks stay in the line.
            let marked = String(SpellMarkup.text(r, accepted: Set(r.edits.map(\.id)), choices: [:]).characters)
            let body = CGFloat(lines(marked, max: 18)) * size * 1.5 + 28
            let notice: CGFloat = r.notice == nil ? 0 : 34
            let tail: CGFloat = r.edits.isEmpty ? 30 : 1 + listHeight(r)
            return chrome + max(size * 1.45 + 28, body) + notice + tail
        }
    }
}

/// The corrected text with every fix shown in place: what goes struck through in a muted red,
/// what comes in on the accent with an underline. Fixes the user dropped show the original with a
/// dotted underline.
enum SpellMarkup {
    static let removed = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 0.85) : NSColor(srgbRed: 0.82, green: 0.24, blue: 0.2, alpha: 0.8)
    })

    static func text(_ r: SpellResult, accepted: Set<Int>, choices: [Int: Int] = [:]) -> AttributedString {
        let chars = Array(r.source)
        var out = AttributedString()
        var at = 0
        for e in r.edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where e.range.lowerBound >= at {
            out += AttributedString(String(chars[at..<min(e.range.lowerBound, chars.count)]))
            if accepted.contains(e.id) {
                for seg in e.option(choices[e.id] ?? 0).segments {
                    switch seg.op {
                    case .equal: out += AttributedString(seg.text)
                    case .delete: out += deleted(seg.text)
                    case .insert: out += inserted(seg.text)
                    }
                }
            } else {
                var kept = AttributedString(e.original)
                kept.underlineStyle = Text.LineStyle(pattern: .dot, color: Palette.inkSecondary.opacity(0.7))
                out += kept
            }
            at = min(e.range.upperBound, chars.count)
        }
        if at < chars.count { out += AttributedString(String(chars[at...])) }
        return out
    }

    private static func deleted(_ s: String) -> AttributedString {
        // A dropped space would be an invisible strike: show it as ␣ (and a dropped line break as ↵).
        if s.allSatisfy(\.isWhitespace) {
            var mark = AttributedString(String(s.map { $0.isNewline ? "↵" : "␣" }))
            mark.foregroundColor = removed
            return mark
        }
        var a = AttributedString(s)
        a.foregroundColor = removed
        a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: removed)
        return a
    }

    private static func inserted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.underlineStyle = Text.LineStyle(pattern: .solid, color: Palette.accent)
        a.backgroundColor = Palette.accent.opacity(0.16)
        return a
    }
}

/// original → suggestion, a chip for the kind and the reason; click to keep or drop it.
struct CorrectionList: View {
    let result: SpellResult
    let accepted: Set<Int>
    var choices: [Int: Int] = [:]
    let toggle: (SpellEdit) -> Void
    var choose: (SpellEdit, Int) -> Void = { _, _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(result.edits) { e in
                    CorrectionRow(edit: e, on: accepted.contains(e.id), choice: choices[e.id] ?? 0,
                                  tap: { toggle(e) }, choose: { choose(e, $0) })
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .scrollIndicators(.automatic)
    }
}

private struct CorrectionRow: View {
    let edit: SpellEdit
    let on: Bool
    let choice: Int
    let tap: () -> Void
    let choose: (Int) -> Void
    @State private var hovering = false
    @State private var expanded = false

    private var picked: SpellDiff.Hunk { edit.option(choice) }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(on ? Palette.accent : Palette.inkSecondary.opacity(0.55))
                .padding(.top, 1)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Self.visible(edit.original))
                        .strikethrough(on, color: SpellMarkup.removed)
                        .foregroundStyle(on ? SpellMarkup.removed : Palette.ink)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                    Text(Self.visible(picked.replacement))
                        .fontWeight(.semibold)
                        .foregroundStyle(on ? Palette.ink : Palette.inkSecondary)
                    Spacer(minLength: 6)
                    if edit.detail != nil {
                        Button { withAnimation(.spring(duration: 0.28)) { expanded.toggle() } } label: {
                            Image(systemName: expanded ? "chevron.up" : "questionmark.circle")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                                .frame(width: 18, height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide the explanation".loc : "Why? Show the rule and examples".loc)
                    }
                    KindChip(kind: edit.kind)
                }
                .font(.system(size: 13))
                .lineLimit(1)
                if let reason = edit.reason, !expanded {
                    Text(reason).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if expanded, let detail = edit.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        .lineSpacing(2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if edit.options.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(edit.options.indices, id: \.self) { i in
                            CandidateChip(title: Self.visible(edit.options[i].replacement), on: on && i == choice) { choose(i) }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.ink.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
        .help(on ? "Click to keep the original".loc : "Click to apply this fix".loc)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }

    /// Trimmed, with spaces that matter on their own made visible.
    static func visible(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "␣" : t.replacingOccurrences(of: "\n", with: " ↵ ")
    }
}

/// One of several suggestions for the same words.
private struct CandidateChip: View {
    let title: String
    let on: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .foregroundStyle(on ? Palette.accent : Palette.ink)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(on ? Palette.accent.opacity(0.14) : Palette.raised.opacity(hovering ? 1 : 0.75)))
                .overlay(Capsule().strokeBorder(on ? Palette.accent.opacity(0.55) : .clear, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }
}

/// The card asking, once, before Korean text goes to the web checkers.
private struct WebConsent: View {
    let engine: SpellEngine
    let allow: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "network").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.raised))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check Korean with Daum and Naver?".loc).font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.ink)
                    Text("The Korean web spell checkers know Korean best.".loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                line("paperplane", "This text is sent to Daum’s or Naver’s spell checker.")
                line("wrench.and.screwdriver", "It’s an unofficial connection, so it may stop working if they change it.")
                line("person", "For personal use. Orbit keeps no copy of what you check.")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Not Now".loc, action: decline).buttonStyle(PillButtonStyle(prominent: false))
                Button("Allow".loc, action: allow).buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label { Text(text.loc).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 14)
        }
        .font(.system(size: 12)).foregroundStyle(Palette.ink)
    }
}

/// Under an on-device check of Korean: the web checkers do better.
private struct WebOffer: View {
    let `try`: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("More accurate Korean with Daum and Naver".loc).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: `try`) {
                Text("Try".loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.canvas)
                    .padding(.horizontal, 10).frame(height: 22).background(Capsule().fill(Palette.ink))
            }
            .buttonStyle(.plain)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Don’t suggest this again".loc)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.accent.opacity(0.08)))
    }
}

struct KindChip: View {
    let kind: SpellKind

    var symbol: String {
        switch kind {
        case .spelling: "textformat.abc"
        case .spacing: "space"
        case .grammar: "text.badge.checkmark"
        case .wording: "quote.bubble"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(kind.title.loc).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Palette.inkSecondary)
        .padding(.horizontal, 7).frame(height: 18)
        .background(Capsule().fill(Palette.raised))
        .fixedSize()
    }
}

/// 번역 | 맞춤법 at the left of both cards' headers. The current mode shows its name; the other
/// is just its symbol.
struct PanelModeSwitch: View {
    let spelling: Bool
    let translate: () -> Void
    let spell: () -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            segment("Translate", symbol: "character.bubble.fill", on: !spelling, action: translate)
            if SpellController.enabled || spelling {
                segment("Spelling", symbol: "textformat.abc.dottedunderline", on: spelling, action: spell)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.raised))
    }

    private func segment(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { if !on { action() } } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Palette.accent : Palette.inkSecondary)
                if on { Text(title.loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink).fixedSize() }
            }
            .padding(.horizontal, on ? 9 : 7).frame(height: 20)
            .background { if on { Capsule().fill(Palette.canvas).shadow(color: .black.opacity(0.08), radius: 1, y: 0.5) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "" : (title == "Translate" ? "Translate this text".loc : "Check spelling of this text".loc))
    }
}

/// The translator's footer button, shared by both cards.
struct CardFooterButton: View {
    let title: String
    let keys: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title.loc).font(.system(size: 12, weight: .semibold))
                Text(keys).font(.system(size: 11, weight: .medium)).opacity(0.6)
            }
            .foregroundStyle(prominent ? Palette.canvas : Palette.ink)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(prominent ? Palette.ink : Palette.raised))
        }
        .buttonStyle(.plain)
    }
}

/// ↩ or C copy, ⌘↩ replace, ⌘R check again, ⌘T translate instead, esc close — while the card
/// has focus. Esc is caught here too: once the text is clicked into, it takes the key and the
/// panel's own cancel never comes.
private struct SpellKeys: NSViewRepresentable {
    let model: SpellController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === view.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (Int(event.keyCode), flags) {
            case (kVK_Return, []), (kVK_ANSI_C, []): MainActor.assumeIsolated { model.copyResult() }; return nil
            case (kVK_Escape, []): MainActor.assumeIsolated { model.hide() }; return nil
            case (kVK_Return, .command): MainActor.assumeIsolated { model.replaceSelection() }; return nil
            case (kVK_ANSI_R, .command): MainActor.assumeIsolated { model.run() }; return nil
            case (kVK_ANSI_T, .command): MainActor.assumeIsolated { model.switchToTranslate() }; return nil
            default: return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
    final class Coordinator { var monitor: Any? }
}
