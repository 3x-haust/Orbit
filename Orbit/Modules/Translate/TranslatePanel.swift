import AppKit
import Carbon.HIToolbox
import SwiftUI

/// ⌘C twice → a translation card next to the pointer. Also opens from the Ring, launcher or shortcut
/// with whatever text is on the clipboard. ⌘C three times (when turned on) checks spelling instead.
@MainActor @Observable
final class TranslateController {
    static let shared = TranslateController()

    enum Phase: Equatable { case idle, working, done(TranslationResult), failed(String) }

    var source = ""
    var phase: Phase = .idle
    var target = "ko"
    var engine: TranslationEngine = .google

    /// On its own thread, so watching for ⌘C never waits on the main thread.
    nonisolated(unsafe) private static var live: EventTapThread?
    @ObservationIgnored private var pasteTimer: Timer?
    @ObservationIgnored private var lastPaste: (count: Int, text: String?, at: Date) = (0, nil, .distantPast)
    @ObservationIgnored private var lastTrigger = Date.distantPast
    @ObservationIgnored private var lastCopy: Date?
    /// Presses in the current run of ⌘C, and the clipboard repeats seen in it.
    @ObservationIgnored private var presses = 0
    @ObservationIgnored private var repeats = 1
    /// A double press waiting to see whether a third follows (only with ⌘C three times on).
    @ObservationIgnored private var pendingDouble: DispatchWorkItem?
    /// Orbit itself is copying (spell check reading a selection): not the user pressing ⌘C.
    @ObservationIgnored private var quietUntil = Date.distantPast
    @ObservationIgnored private var anchor: NSRect?
    /// The selection the text was copied from, put back before 바꾸기.
    @ObservationIgnored private var selection: SelectionAnchor?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.level = .floating
        p.setContent(TranslateCard(model: self))
        p.onEscape = { [weak self] in self?.hide(); return true }
        p.onResignKey = { [weak self] in
            guard Pref.defaults.bool(forKey: Pref.translateCloseOnBlur) else { return }
            self?.hide()
        }
        return p
    }()

    static var deeplKey: String {
        get { Keychain.get("deepl") ?? "" }
        set { Keychain.set(newValue, for: "deepl") }
    }

    /// Listens for ⌘C ⌘C in every app, including Orbit itself and while Orbit is in the background.
    /// Two signals, either one triggers:
    /// - an HID-level event tap, which sees ⌘C before other apps' taps (DeepL) can swallow it;
    /// - the clipboard receiving the same text twice in quick succession, for when key events
    ///   never reach us (secure input, remote desktops, menu-bar Copy).
    func start() {
        if Self.live != nil || pasteTimer != nil { stop() }
        guard Pref.defaults.bool(forKey: Pref.translateDoubleCopy) || Self.tripleCopy else { return }
        installTap()
        lastPaste = (NSPasteboard.general.changeCount, nil, .distantPast)
        pasteTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { TranslateController.shared.pollPasteboard() }
        }
    }

    /// ⌘C three times opens spell check (and ⌘C twice then waits a moment to see if a third comes).
    static var tripleCopy: Bool { Pref.defaults.bool(forKey: Pref.spellTripleCopy) && SpellController.enabled }

    /// Ignores the clipboard and ⌘C for a moment while Orbit copies on its own.
    func quiet(for seconds: TimeInterval) {
        quietUntil = max(quietUntil, Date().addingTimeInterval(seconds))
        lastCopy = nil
        pendingDouble?.cancel()
    }

    func stop() {
        Self.live?.stop()
        Self.live = nil
        pasteTimer?.invalidate()
        pasteTimer = nil
    }

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                TranslateController.live?.reenable()
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_C), flags == .maskCommand,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               event.getIntegerValueField(.eventSourceUserData) != SelectionReader.marker {
                DispatchQueue.main.async { MainActor.assumeIsolated { TranslateController.shared.copyPressed() } }
            }
            return Unmanaged.passUnretained(event)
        }
        // Listen-only never blocks or alters typing. Falls back to the session tap if HID isn't allowed.
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback, userInfo: nil)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: callback, userInfo: nil) else { return }
        Self.live = EventTapThread(port: port, name: "Orbit double copy")
    }

    private func copyPressed() {
        guard Date() > quietUntil else { return }
        let window = Pref.defaults.double(forKey: Pref.translateInterval)
        defer { lastCopy = Date() }
        guard let last = lastCopy, Date().timeIntervalSince(last) <= window else { presses = 1; return }
        presses += 1
        if presses >= 2 { pressed(presses) }
        if presses >= 3 || !Self.tripleCopy { lastCopy = .distantPast; presses = 0 }
    }

    /// The second or third ⌘C of a run, from either detector.
    private func pressed(_ count: Int) {
        let triple = Self.tripleCopy
        if count >= 3, triple {
            pendingDouble?.cancel()
            pendingDouble = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.fire(spelling: true) }
            return
        }
        guard count == 2 else { return }
        guard Pref.defaults.bool(forKey: Pref.translateDoubleCopy) else { return }
        guard triple else {
            // The app writes the pasteboard as it handles ⌘C; give it a beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.fire() }
            return
        }
        // Wait out the window for a third press before translating.
        guard pendingDouble == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.pendingDouble = nil; self?.fire() }
        pendingDouble = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Pref.defaults.double(forKey: Pref.translateInterval) + 0.12, execute: work)
    }

    /// Same text landing on the clipboard twice within the double-press window. Writes closer than
    /// 60 ms apart are one app writing twice for a single copy, not two presses.
    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPaste.count else { return }
        // Orbit borrowing the clipboard: note where it is now, count nothing.
        if Date() <= quietUntil { lastPaste = (pb.changeCount, nil, .distantPast); repeats = 1; return }
        // Caught between the copying app clearing the clipboard and writing to it; look again next tick.
        if pb.types?.isEmpty ?? true { return }
        let text = pb.string(forType: .string)
        let now = Date()
        let gap = now.timeIntervalSince(lastPaste.at)
        let repeated = text != nil && text == lastPaste.text
        lastPaste = (pb.changeCount, text, now)
        guard repeated, gap >= 0.06, gap <= Pref.defaults.double(forKey: Pref.translateInterval) + 0.1 else { repeats = 1; return }
        repeats += 1
        pressed(repeats)
        if repeats >= 3 || !Self.tripleCopy { lastPaste.at = .distantPast; repeats = 1 }
    }

    /// Both detectors usually see the same double press; translate once.
    private func fire(spelling: Bool = false) {
        guard Date().timeIntervalSince(lastTrigger) > 0.8 else { return }
        lastTrigger = Date()
        if spelling { SpellController.shared.checkClipboard() } else { translateClipboard() }
    }

    func translateClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            Toast.show("Copy some text first", symbol: "character.bubble")
            return
        }
        // The text was just copied from the selection, which is still there: note where it is.
        let front = NSWorkspace.shared.frontmostApplication
        show(text, selection: SelectionAnchor.capture(in: front, text: text))
    }

    /// - Parameter frame: where the card goes instead of next to the pointer (the spell check card,
    ///   when switching over from it).
    func show(_ text: String, at frame: NSRect? = nil, selection: SelectionAnchor? = nil) {
        anchor = frame
        self.selection = selection
        source = String(text.prefix(5000))
        engine = TranslationEngine(rawValue: Pref.defaults.string(forKey: Pref.translateEngine) ?? "")
            .flatMap { TranslationEngine.available.contains($0) ? $0 : nil } ?? .google
        target = Self.direction(for: source)
        present()
        run()
    }

    /// Primary language unless the text is already in it — then the secondary one.
    static func direction(for text: String) -> String {
        let primary = Pref.defaults.string(forKey: Pref.translatePrimary) ?? "ko"
        let secondary = Pref.defaults.string(forKey: Pref.translateSecondary) ?? "en"
        guard let guess = Translator.guessLanguage(text) else { return primary }
        return guess == primary || primary.hasPrefix(guess) ? secondary : primary
    }

    func run() {
        job?.cancel()
        let text = source, target = target, engine = engine
        let formality = Formality(rawValue: Pref.defaults.string(forKey: Pref.translateFormality) ?? "") ?? .auto
        phase = .working
        resize(for: .working)
        job = Task {
            let next: Phase
            do {
                // Name the language up front when the script gives it away (Google's auto-detect calls
                // short Chinese text English or Korean).
                let script = Translator.scriptLanguage(text).flatMap { TranslationLanguage.same($0, target) ? nil : $0 }
                var result = try await Translator.translate(text, to: target, from: script, engine: engine, formality: formality, deeplKey: Self.deeplKey)
                if let script { result.detectedSource = script }
                next = .done(result)
            } catch {
                next = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            // The card grows to its final height while the text fades in, so nothing jumps afterwards.
            resize(for: next)
            withAnimation(.easeOut(duration: 0.22)) { phase = next }
        }
    }

    func swapDirection() {
        let primary = Pref.defaults.string(forKey: Pref.translatePrimary) ?? "ko"
        let secondary = Pref.defaults.string(forKey: Pref.translateSecondary) ?? "en"
        target = target == primary ? secondary : primary
        if case .done(let r) = phase { source = r.text }
        run()
    }

    /// Picked from the result-language menu.
    func translate(to language: String) {
        guard language != target else { return }
        target = language
        run()
    }

    func use(_ engine: TranslationEngine) {
        self.engine = engine
        Pref.defaults.set(engine.rawValue, forKey: Pref.translateEngine)
        run()
    }

    var output: String? { if case .done(let r) = phase { r.text } else { nil } }

    func copyResult() {
        guard let output else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        hide()
        Toast.show("Translation copied", symbol: "doc.on.doc.fill")
    }

    /// Pastes over the selection the user copied from.
    func replaceSelection() {
        guard let output else { return }
        job?.cancel()
        panel.orderOut(nil) // no fade: the panel has to let go of the keyboard first
        let anchor = selection
        selection = nil
        Task { _ = await SelectionReplacer.replace(with: output, anchor: anchor, app: Paster.lastExternal, feature: "translate") }
    }

    func hide() {
        job?.cancel()
        panel.dismiss()
    }

    // MARK: Placement

    static func placeholderLines(for text: String) -> Int { min(3, max(1, text.count / 40 + 1)) }

    private static let width: CGFloat = 440

    /// Over to spell check with the same text, in the same spot.
    func switchToSpelling() {
        let frame = panel.isVisible ? panel.frame : nil
        let text: String = source
        job?.cancel()
        panel.orderOut(nil)
        SpellController.shared.show(text, from: selection?.app ?? .current, at: frame, selection: selection)
    }

    private func present() {
        let size = NSSize(width: Self.width, height: estimatedHeight(for: .working))
        if let anchor, !panel.isVisible {
            // Switching over: same top-left as the card it replaces, shown without a rise.
            self.anchor = nil
            panel.setFrame(fitted(NSRect(x: anchor.minX, y: anchor.maxY - size.height, width: size.width, height: size.height)), display: false)
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
            // Already open (maybe moved by the user): stay put, just fit the new text.
            var frame = panel.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            setPanelFrame(fitted(frame))
        }
        else { panel.present(at: fitted(NSRect(origin: origin, size: size))) }
    }

    /// Keeps the top edge where it is and grows or shrinks downwards.
    private func resize(for phase: Phase) {
        guard panel.isVisible else { return }
        var frame = panel.frame
        let height = estimatedHeight(for: phase)
        frame.origin.y += frame.height - height
        frame.size.height = height
        setPanelFrame(fitted(frame))
    }

    /// Long results would run off the bottom of the screen: slide the card up as far as it needs,
    /// and past a full screen's height let the result scroll instead.
    private func fitted(_ frame: NSRect) -> NSRect {
        let screen = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.active).visibleFrame.insetBy(dx: 8, dy: 8)
        var f = frame
        f.size.height = min(f.height, screen.height)
        if f.minY < screen.minY { f.origin.y = screen.minY }
        if f.maxY > screen.maxY { f.origin.y = screen.maxY - f.height }
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        return f
    }

    /// The SwiftUI content sits in a plain container view (see FloatingPanel.container), so the
    /// window can animate its size without the hosting view fighting it.
    private func setPanelFrame(_ frame: NSRect) {
        guard panel.isVisible, panel.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func estimatedHeight(for phase: Phase) -> CGFloat {
        let size = CGFloat(Pref.defaults.double(forKey: Pref.translateFontSize))
        // Hangul, kana and CJK are about twice as wide as Latin letters.
        func width(_ line: Substring, _ size: CGFloat) -> CGFloat {
            line.unicodeScalars.reduce(0) { w, c in
                let wide = (0x1100...0x11FF).contains(c.value) || (0x2E80...0x9FFF).contains(c.value)
                    || (0xAC00...0xD7AF).contains(c.value) || (0xFF00...0xFFEF).contains(c.value)
                return w + size * (wide ? 0.98 : 0.54)
            }
        }
        func lines(_ s: String, size: CGFloat, max cap: Int) -> Int {
            min(cap, s.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, Int(ceil(width($1, size) / 370))) })
        }
        let body: CGFloat = switch phase {
        case .done(let r): CGFloat(lines(r.text, size: size, max: 60)) * size * 1.5
        case .failed: 64
        // Matches the placeholder bars in TranslateCard.result.
        case .idle, .working: CGFloat(Self.placeholderLines(for: source)) * (size * 0.9 + 8)
        }
        let src = CGFloat(lines(source, size: 12, max: 3)) * 17
        // Capped by the screen in fitted(_:); beyond that the result scrolls.
        return 128 + src + max(size * 1.45, body)
    }
}

// MARK: - Card

private struct TranslateCard: View {
    @Bindable var model: TranslateController
    @AppStorage(Pref.translateFontSize) private var fontSize = 16.0
    @AppStorage(Pref.translateShowSource) private var showSource = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showSource {
                Text(model.source)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(3)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                    .textSelection(.enabled)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 18)
            result
                .padding(.horizontal, 18).padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .background(WindowDragArea()) // empty space anywhere on the card moves it too
        .focusEffectDisabled()
        .modifier(PanelShell())
        .background(KeyCatcher(model: model))
    }

    private var header: some View {
        HStack(spacing: 8) {
            PanelModeSwitch(spelling: false, translate: {}, spell: { model.switchToSpelling() })
            HStack(spacing: 4) {
                Text(sourceName).foregroundStyle(Palette.inkSecondary)
                    .padding(.leading, 9)
                Button { model.swapDirection() } label: {
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 18, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Swap direction (⌘⇧S)".loc)
                // The result language: pick any, and it translates again right away.
                Menu {
                    ForEach(TranslationLanguage.all) { lang in
                        Button { model.translate(to: lang.code) } label: {
                            if lang.code == model.target { Label(lang.name, systemImage: "checkmark") } else { Text(lang.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(TranslationLanguage.named(model.target)).foregroundStyle(Palette.ink)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.inkSecondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.trailing, 8)
                .help("Translate into…".loc)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(height: 24)
            .background(Capsule().fill(Palette.raised))
            Spacer()
            Menu {
                ForEach(TranslationEngine.available) { e in
                    Button { model.use(e) } label: {
                        if e == model.engine { Label(e.title, systemImage: "checkmark") } else { Text(e.title) }
                    }
                }
            } label: {
                Text(model.engine.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
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

    private var sourceName: String {
        if case .done(let r) = model.phase, let s = r.detectedSource { return TranslationLanguage.named(s.lowercased()) }
        return Translator.guessLanguage(model.source).map(TranslationLanguage.named) ?? "Auto".loc
    }

    @ViewBuilder private var result: some View {
        switch model.phase {
        case .idle, .working:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<TranslateController.placeholderLines(for: model.source), id: \.self) { i in
                    Shimmer().frame(width: i == 2 ? 180 : nil, height: fontSize * 0.9)
                }
            }
            .transition(.identity) // gone the moment the text arrives
        case .done(let r):
            ScrollView {
                Text(r.text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(fontSize * 0.2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .transition(.opacity)
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).font(.system(size: 13)).foregroundStyle(Palette.ink)
                    HStack(spacing: 8) {
                        Button("Try Again") { model.run() }.buttonStyle(PillButtonStyle(prominent: false))
                        if model.engine != .google { Button("Use Google") { model.use(.google) }.buttonStyle(PillButtonStyle(prominent: false)) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .done(let r) = model.phase {
                Text("%ld characters".loc(r.text.count)).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
            }
            Spacer()
            footerButton("Replace", keys: "⌘↩") { model.replaceSelection() }
            footerButton("Copy", keys: "↩ C", prominent: true) { model.copyResult() }
        }
        .disabled(model.output == nil)
        .padding(.horizontal, 14).frame(height: 44)
        .background { ZStack { Palette.surface.opacity(0.6); WindowDragArea() } }
    }

    private func footerButton(_ title: String, keys: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
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

/// Placeholder bar while a translation (or a spell check) is on its way.
struct Shimmer: View {
    var body: some View {
        // Driven by a timeline, not a repeatForever animation — that one leaks into every other
        // layout change in the card (text reflowing as the window opens).
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.raised)
                .opacity(0.725 + 0.275 * sin(t * .pi / 0.7))
        }
    }
}

/// ↩ or C copy, ⌘↩ replace, ⌘⇧S swap, esc close — handled while the card has focus. Esc is
/// caught here too: once the result text is clicked into, it takes the key and the panel's own
/// cancel never comes.
private struct KeyCatcher: NSViewRepresentable {
    let model: TranslateController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === view.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch (Int(event.keyCode), flags) {
            case (kVK_Return, []), (kVK_ANSI_C, []): MainActor.assumeIsolated { model.copyResult() }; return nil
            case (kVK_Escape, []): MainActor.assumeIsolated { model.hide() }; return nil
            case (kVK_Return, .command): MainActor.assumeIsolated { model.replaceSelection() }; return nil
            case (kVK_ANSI_S, [.command, .shift]): MainActor.assumeIsolated { model.swapDirection() }; return nil
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
