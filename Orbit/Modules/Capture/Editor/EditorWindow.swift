import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorWindow: NSWindow, NSWindowDelegate {
    private static var open: Set<EditorWindow> = []
    private let model: EditorModel
    private var monitors: [Any] = []
    private var onClose: (() -> Void)?

    /// - Parameter onClose: runs when the editor window closes (the thumbnail uses it to come back).
    static func open(image: NSImage, fileURL: URL?, onClose: (() -> Void)? = nil) {
        let window = EditorWindow(model: EditorModel(image: image, fileURL: fileURL))
        window.onClose = onClose
        open.insert(window)
        watchHelpers()
        window.bringToFront()
    }

    // MARK: Always on top

    /// "Always on top" in the editor's toolbar: the editor floats over other apps' windows (and
    /// full-screen apps), like the capture thumbnail. On unless turned off.
    static let floatingKey = "capture.editorFloating"
    static var floats: Bool { Pref.defaults.object(forKey: floatingKey) as? Bool ?? true }

    static func setFloating(_ on: Bool) {
        Pref.defaults.set(on, forKey: floatingKey)
        open.forEach { $0.applyFloating() }
        raiseHelpers()
    }

    /// The editor in front: the key window, or the one a popover in front belongs to.
    static var front: EditorWindow? {
        if let w = NSApp.keyWindow as? EditorWindow { return w }
        if let w = NSApp.keyWindow?.parent as? EditorWindow { return w }
        return open.first { $0.isVisible }
    }

    private func applyFloating() {
        if Self.floats {
            level = .floating
            collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        } else {
            level = .normal
            collectionBehavior = []
        }
    }

    /// Just above a floating editor: for the colour and font panels, open/save panels that aren't
    /// sheets, and popovers. (Menus, alerts and toasts already sit higher.)
    private static let helperLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    private static var helperWatch: [Any] = []

    private static func raiseHelpers() {
        guard floats, open.contains(where: \.isVisible) else { return }
        if NSColorPanel.sharedColorPanelExists { raise(NSColorPanel.shared) }
        if NSFontPanel.sharedFontPanelExists { raise(NSFontPanel.shared) }
    }

    private static func raise(_ window: NSWindow) {
        guard !(window is EditorWindow), window.sheetParent == nil, window.level < helperLevel else { return }
        window.level = helperLevel
    }

    private static func watchHelpers() {
        guard helperWatch.isEmpty else { return }
        let center = NotificationCenter.default
        helperWatch.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard floats, open.contains(where: \.isVisible), let window = note.object as? NSWindow else { return }
                if window is NSColorPanel || window is NSFontPanel || window is NSSavePanel { raise(window) }
            }
        })
        helperWatch.append(center.addObserver(forName: NSPopover.didShowNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard floats, let popover = note.object as? NSPopover,
                      let window = popover.contentViewController?.view.window,
                      window.parent is EditorWindow || open.contains(where: \.isKeyWindow) else { return }
                raise(window)
            }
        })
    }

    private init(model: EditorModel) {
        self.model = model
        let screen = NSScreen.active.visibleFrame
        let chrome = CGSize(width: 80, height: 140)
        let fit = min(1, (screen.width * 0.85 - chrome.width) / model.size.width, (screen.height * 0.85 - chrome.height) / model.size.height)
        let w = max(820, model.size.width * fit + chrome.width), h = max(480, model.size.height * fit + chrome.height)
        super.init(contentRect: NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Annotate"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 760, height: 420)
        delegate = self
        applyFloating()
        contentView = FloatingPanel.container(for: Self.host(EditorView(model: model, actions: .init(
            copy: { [weak self] in self?.copyImage() },
            save: { [weak self] in self?.saveImage(ask: false) },
            pin: { [weak self] in self?.pinImage() },
            delete: model.fileURL == nil ? nil : { [weak self] in self?.deleteCapture() }
        ))))
        installKeys()
    }

    private static func host<V: View>(_ view: V) -> NSView {
        let host = NSHostingView(rootView: view.orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = [] // no titlebar safe-area feedback into layout (constraint-loop crash)
        return host
    }

    func windowDidBecomeKey(_ notification: Notification) { Self.raiseHelpers() }

    func windowWillClose(_ notification: Notification) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        Self.open.remove(self)
        onClose?()
        onClose = nil
    }

    private func copyImage() {
        model.commitText()
        CaptureService.shared.copy(model.render())
        Toast.show("Copied")
    }

    private func saveImage(ask: Bool) {
        model.commitText()
        let image = model.render()
        guard let data = image.pngData else { return }
        let folder = URL(fileURLWithPath: Pref.defaults.string(forKey: Pref.captureSaveFolder) ?? NSHomeDirectory())
        let name = model.fileURL?.deletingPathExtension().lastPathComponent.appending(" (Annotated).png") ?? "Orbit Annotated.png"
        if ask {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            panel.allowedContentTypes = [.png]
            panel.beginSheetModal(for: self) { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        } else {
            let url = folder.appendingPathComponent(name)
            try? data.write(to: url)
            Toast.show("Saved", symbol: "arrow.down.circle.fill", detail: url.lastPathComponent)
        }
    }

    /// Throws the capture away, like the preview card's Move to Trash, and closes the editor.
    private func deleteCapture() {
        guard let url = model.fileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                Toast.show("Couldn’t move it to the Trash", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
                return
            }
        }
        if let c = CaptureService.shared.recent.first(where: { $0.fileURL == url }) { CaptureService.shared.remove(c) }
        // The thumbnail would come back when the editor closes; it's gone now.
        onClose = nil
        close()
        Toast.show("Moved to Trash", symbol: "trash", detail: "You can put it back from the Trash in Finder.".loc)
    }

    private func pinImage() {
        model.commitText()
        PinWindow.pin(model.render())
        close()
    }

    /// Single-letter tool keys (Shottr-style), zoom, space-to-pan, plus the usual ⌘ shortcuts.
    private func installKeys() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self else { return event }
            let model = self.model
            if event.keyCode == 49, model.editingText == nil, !(self.firstResponder is NSTextView) {
                // Hold space to drag the picture around.
                if event.type == .keyDown { if !event.isARepeat { model.panning = true } } else { model.panning = false }
                return nil
            }
            guard event.type == .keyDown else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags.contains(.command) {
                switch chars {
                case "z": flags.contains(.shift) ? model.redo() : model.undo(); return nil
                case "c" where model.selectingText && !model.selectedText.isEmpty:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.selectedText, forType: .string)
                    Toast.show("Text copied", symbol: "text.viewfinder", detail: model.selectedText.replacingOccurrences(of: "\n", with: " "))
                    return nil
                case "c" where model.editingText == nil: self.copyImage(); return nil
                case "s": self.saveImage(ask: flags.contains(.shift)); return nil
                case "=", "+": withAnimation(Motion.reflow) { model.setZoom(model.zoom * 1.25) }; return nil
                case "-": withAnimation(Motion.reflow) { model.setZoom(model.zoom / 1.25) }; return nil
                case "0": withAnimation(Motion.reflow) { model.setZoom(1); model.pan = .zero }; return nil
                default: return event
                }
            }
            // Typing into a field (the picture's text, or a popover's) is left alone.
            guard model.editingText == nil, !(self.firstResponder is NSTextView) else {
                if event.keyCode == 53, model.editingText != nil { model.commitText(); return nil } // Esc ends text editing
                return event
            }
            if event.keyCode == 51 || event.keyCode == 117 { model.deleteSelected(); return nil }
            if event.keyCode == 53 {
                if model.selectingText { model.selectingText = false }
                else if model.selectedID != nil { model.selectedID = nil } else { self.close() }
                return nil
            }
            guard flags.isDisjoint(with: [.control, .option]) else { return event }
            if chars == "l" { model.selectingText.toggle(); return nil }
            if let c = chars.first, let tool = Annotation.Tool.allCases.first(where: { $0.key == c }) {
                model.tool = tool
                return nil
            }
            if let d = Int(chars), (1...EditorModel.palette.count).contains(d) {
                model.color = EditorModel.palette[d - 1]
                return nil
            }
            return event
        }
        // Two-finger scroll moves a zoomed-in picture; ⌘-scroll zooms.
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self else { return event }
            let model = self.model
            if event.modifierFlags.contains(.command) {
                model.setZoom(model.zoom * (1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)))
                return nil
            }
            guard model.zoom > 1 else { return event }
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            model.pan.width += event.scrollingDeltaX * k
            model.pan.height += event.scrollingDeltaY * k
            return nil
        }
        monitors = [keys, scroll].compactMap { $0 }
    }
}

struct EditorActions {
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void
    var delete: (() -> Void)?
}

struct EditorView: View {
    @Bindable var model: EditorModel
    let actions: EditorActions
    @State private var colorsOpen = false
    @State private var styleOpen = false
    @State private var canvasOpen = false
    @State private var canvasTab: CanvasPanel.Tab = .resize
    @State private var openKey: String?
    @State private var panStart: CGSize?
    @State private var magnifyBase: CGFloat?
    @State private var dropTargeted = false
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar.zIndex(1)
            canvasArea
        }
        .background(Color(white: 0.13))
        .ignoresSafeArea()
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    // MARK: Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let pad: CGFloat = 32
            let frame = model.backdrop?.padding ?? 0
            let outer = CGSize(width: model.size.width + frame * 2, height: model.size.height + frame * 2)
            let fit = min(1, (geo.size.width - pad * 2) / outer.width, (geo.size.height - pad * 2) / outer.height)
            let scale = fit * model.zoom
            let shown = CGSize(width: model.size.width * scale, height: model.size.height * scale)
            ZStack {
                if let backdrop = model.backdrop {
                    Rectangle().fill(backdrop.fill)
                        .frame(width: outer.width * scale, height: outer.height * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                }
                picture(scale: scale, shown: shown)
                    .clipShape(RoundedRectangle(cornerRadius: (model.backdrop?.radius ?? 6) * (model.backdrop == nil ? 1 : scale), style: .continuous))
                    .shadow(color: .black.opacity(model.backdrop.map { $0.shadow ? 0.35 : 0 } ?? 0.35),
                            radius: model.backdrop.map { $0.padding * 0.35 * scale } ?? 18, y: model.backdrop.map { $0.padding * 0.12 * scale } ?? 8)
            }
            .offset(model.pan)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .gesture(MagnifyGesture()
                .onChanged { v in
                    let base = magnifyBase ?? model.zoom
                    magnifyBase = base
                    model.setZoom(base * v.magnification)
                }
                .onEnded { _ in magnifyBase = nil })
            .overlay(alignment: .bottomTrailing) { zoomBadge }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .overlay(Label("Drop to put it next to this one", systemImage: "rectangle.split.2x1")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect(.regular, in: Capsule()))
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .background(Color(white: 0.13))
    }

    private func picture(scale: CGFloat, shown: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            AnnotatedImage(model: model, scale: scale)
                .frame(width: shown.width, height: shown.height)
                .gesture(canvasGesture(scale: scale))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        cursor.set()
                        model.hoverPoint = CGPoint(x: p.x / scale, y: p.y / scale)
                    case .ended:
                        model.hoverPoint = nil
                    }
                }
            if let editing = model.editingText {
                textEditor(editing, scale: scale)
            }
            if model.tool == .picker, !model.selectingText, let p = model.hoverPoint, let (hex, color) = model.hex(at: p) {
                pickerReadout(hex: hex, color: color)
                    .offset(x: p.x * scale + 16, y: p.y * scale + 16)
                    .allowsHitTesting(false)
            }
            // Always mounted so the words are read ahead of time; above the drawing gesture,
            // so with the text tool on, drags select words instead of drawing.
            LiveTextOverlay(image: model.image, model: model, active: model.selectingText)
                .frame(width: shown.width, height: shown.height)
                .allowsHitTesting(model.selectingText)
        }
        .frame(width: shown.width, height: shown.height)
    }

    private func pickerReadout(hex: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
            Text(hex).font(.system(size: 11, weight: .semibold).monospaced()).foregroundStyle(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.78)))
        .fixedSize()
    }

    @ViewBuilder private var zoomBadge: some View {
        if model.zoom != 1 {
            Button { withAnimation(Motion.reflow) { model.setZoom(1); model.pan = .zero } } label: {
                Text("\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 24)
                    .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(.plain)
            .hoverHint("Actual fit · ⌘0".loc, below: false)
            .padding(14)
        }
    }

    private var cursor: NSCursor {
        if model.panning { return .openHand }
        if model.selectingText { return .iBeam }
        return switch model.tool {
        case .select: .arrow
        case .text: .iBeam
        case .picker: .crosshair
        default: .crosshair
        }
    }

    private func canvasGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if model.panning || panStart != nil {
                    let start = panStart ?? model.pan
                    panStart = start
                    model.pan = CGSize(width: start.width + v.translation.width, height: start.height + v.translation.height)
                    return
                }
                let s = CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)
                let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
                model.dragChanged(from: s, to: p)
            }
            .onEnded { v in
                if panStart != nil { panStart = nil; return }
                let s = CGPoint(x: v.startLocation.x / scale, y: v.startLocation.y / scale)
                let p = CGPoint(x: v.location.x / scale, y: v.location.y / scale)
                model.dragEnded(at: p, start: s)
                if model.editingText != nil { textFocused = true }
            }
    }

    private func textEditor(_ editing: (point: CGPoint, text: String), scale: CGFloat) -> some View {
        TextField("Type… (⌥↩ new line)", text: Binding(get: { model.editingText?.text ?? "" }, set: { model.editingText?.text = $0 }), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: model.fontSize * scale, weight: model.weight.font))
            .foregroundStyle(model.textStyle == .pill ? AnnotatedImage.contrast(model.color) : model.color)
            .focused($textFocused)
            .frame(minWidth: 80, maxWidth: 520, alignment: .leading)
            .padding(.horizontal, model.textStyle == .pill ? model.fontSize * 0.4 * scale : 2)
            .padding(.vertical, 2)
            .background {
                if model.textStyle == .pill {
                    RoundedRectangle(cornerRadius: model.fontSize * 0.6 * scale, style: .continuous).fill(model.color)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .offset(x: editing.point.x * scale - (model.textStyle == .pill ? model.fontSize * 0.4 * scale : 2), y: editing.point.y * scale - 2)
            .onSubmit { model.commitText() }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSURL.self) {
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    guard let url = url as? URL, let image = NSImage(contentsOf: url) else { return }
                    Task { @MainActor in combine(image) }
                }
                return
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in combine(image) }
                }
                return
            }
        }
    }

    private func combine(_ image: NSImage) {
        model.combine(with: image)
        canvasTab = .combine
        canvasOpen = true
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Space.related) {
            Spacer().frame(width: 64) // traffic lights
            AlwaysOnTopToggle()

            // Narrow windows fold the colors and then the less-used tools into menus instead of
            // spilling over the window buttons.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.related) { tools(compact: false); colors(compact: false); styleButton; trailing }
                HStack(spacing: Space.related) { tools(compact: false); colors(compact: true); styleButton; trailing }
                HStack(spacing: Space.related) { tools(compact: true); colors(compact: true); styleButton; trailing }
            }
        }
        .controlSize(.large)
        .focusEffectDisabled()
        .padding(.horizontal, Space.standard)
        .frame(height: 56)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func hint(_ tool: Annotation.Tool) -> String { "\(tool.title.loc) · \(tool.key.uppercased())" }

    @ViewBuilder private func tools(compact: Bool) -> some View {
        let shown: [Annotation.Group] = compact ? [.select, .shapes, .draw, .text, .redact, .crop] : Annotation.Group.allCases
        HStack(spacing: 2) {
            ForEach(shown, id: \.self) { group in groupButton(group) }
            if compact { groupButton(nil) }
            liveText
        }
        .padding(ToolButton.inset)
        .glassEffect(.regular, in: Capsule())
    }

    /// One button per group: a click picks the group's last tool. Grouped buttons carry a small
    /// chevron; the chevron, a long press or a right-click opens the rest of the group below.
    /// `nil` is the compact toolbar's "more" button.
    private func groupButton(_ group: Annotation.Group?) -> some View {
        let tools = group?.tools ?? (Annotation.Group.counter.tools + Annotation.Group.inspect.tools)
        let current = group.map { model.lastTool[$0] ?? $0.tools[0] } ?? (tools.contains(model.tool) ? model.tool : nil)
        let active = tools.contains(model.tool) && !model.selectingText
        let key = group?.rawValue ?? "more"
        let open = openKey == key
        return ToolButton(symbol: current?.symbol ?? "ellipsis", isActive: active, grouped: tools.count > 1,
                          onTap: { if let current { model.tool = current } else { openKey = key } },
                          onMore: { openKey = key })
            .contextMenu {
                ForEach(tools, id: \.self) { tool in
                    Button { model.tool = tool } label: { Label(hint(tool), systemImage: tool.symbol) }
                }
            }
            // No hint while the group is open; it would sit on top of the choices.
            .hoverHint(open ? "" : (current.map(hint) ?? "More tools".loc))
            .popover(isPresented: Binding(get: { openKey == key }, set: { if !$0 { openKey = nil } }), arrowEdge: .bottom) {
                HStack(spacing: 4) {
                    ForEach(tools, id: \.self) { tool in
                        VStack(spacing: 4) {
                            ToolButton(symbol: tool.symbol, isActive: model.tool == tool && !model.selectingText, grouped: false,
                                       onTap: { model.tool = tool; openKey = nil }, onMore: {})
                            Text(tool.title.loc).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Text(tool.key.uppercased()).font(.system(size: 9, weight: .semibold).monospaced()).foregroundStyle(.tertiary)
                        }
                        .frame(minWidth: 56)
                    }
                }
                .padding(8)
            }
    }

    /// Live Text, as one more tool in the group: select and copy just some of the words.
    private var liveText: some View {
        ToolButton(symbol: "text.viewfinder", isActive: model.selectingText, grouped: false,
                   onTap: { model.selectingText.toggle() }, onMore: {})
            .hoverHint("Select Text · L".loc)
    }

    @ViewBuilder private func colors(compact: Bool) -> some View {
        if compact {
            // Narrow window: the current colour, and the same swatches in a little popover.
            Button { colorsOpen.toggle() } label: {
                swatch(model.color, selected: false)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .hoverHint("Color".loc)
            .popover(isPresented: $colorsOpen, arrowEdge: .bottom) {
                swatches { colorsOpen = false }.padding(8)
            }
        } else {
            swatches(onPick: {})
                .padding(.horizontal, 6)
                .frame(height: 34)
                .glassEffect(.regular, in: Capsule())
        }
    }

    private func swatches(onPick: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(EditorModel.palette.enumerated()), id: \.offset) { i, c in
                Button { model.color = c; onPick() } label: { swatch(c, selected: model.color == c) }
                    .buttonStyle(.plain)
                    .help("Color %ld".loc(i + 1))
            }
        }
    }

    private func swatch(_ c: Color, selected: Bool) -> some View {
        Circle().fill(c)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .padding(3)
            .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 1.5))
    }

    /// Options for the tool in hand (or the selected mark): thickness, fill, text size and style, strength.
    private var styleButton: some View {
        ToolButton(symbol: "slider.horizontal.3", isActive: styleOpen, grouped: false, onTap: { styleOpen.toggle() }, onMore: {})
            .hoverHint("Style".loc)
            .popover(isPresented: $styleOpen, arrowEdge: .bottom) {
                StylePanel(model: model).padding(14).frame(width: 260)
            }
    }

    @ViewBuilder private var trailing: some View {
        if model.crop != nil {
            Button("Reset Crop") { model.resetCrop() }.controlSize(.small)
        }

        Spacer(minLength: Space.compact)

        ToolButton(symbol: "photo.on.rectangle", isActive: canvasOpen, grouped: false, onTap: { canvasOpen.toggle() }, onMore: {})
            .hoverHint("Resize, background, combine".loc)
            .popover(isPresented: $canvasOpen, arrowEdge: .bottom) {
                CanvasPanel(model: model, tab: $canvasTab).frame(width: 320)
            }
        ToolButton(symbol: "arrow.uturn.backward", isActive: false, grouped: false, onTap: { model.undo() }, onMore: {}).disabled(!model.canUndo)
            .hoverHint("Undo · ⌘Z".loc)
        ToolButton(symbol: "arrow.uturn.forward", isActive: false, grouped: false, onTap: { model.redo() }, onMore: {}).disabled(!model.canRedo)
            .hoverHint("Redo · ⇧⌘Z".loc)
        ToolButton(symbol: "pin", isActive: false, grouped: false, onTap: actions.pin, onMore: {})
            .hoverHint("Pin to screen".loc)
        if let delete = actions.delete {
            ToolButton(symbol: "trash", isActive: false, grouped: false, onTap: delete, onMore: {})
                .hoverHint("Move to Trash".loc)
        }
        Button("Save", action: actions.save).help("Save (⌘S) · Save As (⇧⌘S)")
            .hoverHint("Save · ⌘S".loc)
        Button("Copy", action: actions.copy)
            .buttonStyle(.borderedProminent)
            .help("Copy (⌘C)")
            .hoverHint("Copy · ⌘C".loc)
    }
}

// MARK: - Style

private struct StylePanel: View {
    @Bindable var model: EditorModel

    private var tool: Annotation.Tool {
        model.selectedID.flatMap { id in model.annotations.first { $0.id == id }?.tool } ?? model.tool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(tool.title.loc, systemImage: tool.symbol).font(.system(size: 13, weight: .semibold))
            switch tool {
            case .text:
                slider("Size", value: $model.fontSize, in: 10...120, format: "%.0f pt")
                picker("Weight", selection: $model.weight, options: Annotation.TextWeight.allCases, label: Self.weightTitle)
                picker("Style", selection: $model.textStyle, options: Annotation.TextStyle.allCases, label: Self.styleTitle)
                Text("Double-click a text to change it.").font(.orbitMicro).foregroundStyle(.secondary)
            case .arrow:
                slider("Thickness", value: $model.width, in: 1...16, format: "%.0f")
                picker("Shape", selection: $model.curved, options: [false, true]) { $0 ? "Curved" : "Straight" }
            case .rect, .ellipse:
                slider("Thickness", value: $model.width, in: 1...16, format: "%.0f")
                Toggle("Filled", isOn: $model.filled).toggleStyle(.switch)
                if tool == .rect { slider("Corners", value: $model.cornerRadius, in: 0...40, format: "%.0f") }
            case .line, .pen, .highlight, .measure:
                slider("Thickness", value: $model.width, in: 1...16, format: "%.0f")
            case .counter:
                slider("Size", value: $model.width, in: 1...16, format: "%.0f")
                Text("Each click places the next number.").font(.orbitMicro).foregroundStyle(.secondary)
            case .loupe:
                slider("Size", value: $model.width, in: 1...16, format: "%.0f")
                Text("Drag from the spot to where the lens goes.").font(.orbitMicro).foregroundStyle(.secondary)
            case .blur, .pixelate:
                slider("Strength", value: $model.strength, in: 1...10, format: "%.0f")
            case .erase:
                Text("Covers an area with the colour around it — good for removing text from a plain background.")
                    .font(.orbitCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .spotlight:
                Text("Dims everything outside the boxes you draw.").font(.orbitCaption).foregroundStyle(.secondary)
            case .picker:
                Text("Click to copy a colour’s hex code.").font(.orbitCaption).foregroundStyle(.secondary)
            case .select, .crop:
                Text("Nothing to adjust for this tool.").font(.orbitCaption).foregroundStyle(.secondary)
            }
        }
    }

    private static func weightTitle(_ w: Annotation.TextWeight) -> String {
        switch w {
        case .regular: "Regular"
        case .semibold: "Medium"
        case .bold: "Bold"
        case .heavy: "Heavy"
        }
    }

    private static func styleTitle(_ s: Annotation.TextStyle) -> String {
        switch s {
        case .shadow: "Shadow"
        case .plain: "Plain"
        case .pill: "Label"
        case .outline: "Outline"
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, in range: ClosedRange<CGFloat>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.loc).font(.orbitCaption)
                Spacer()
                Text(String(format: format, value.wrappedValue)).font(.orbitCaption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    private func picker<T: Hashable>(_ title: String, selection: Binding<T>, options: [T], label: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.loc).font(.orbitCaption)
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { Text(label($0).loc).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

// MARK: - Canvas

struct CanvasPanel: View {
    enum Tab: String, CaseIterable { case resize, background, combine }

    @Bindable var model: EditorModel
    @Binding var tab: Tab

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                Text("Resize".loc).tag(Tab.resize)
                Text("Background".loc).tag(Tab.background)
                Text("Combine".loc).tag(Tab.combine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .resize: ResizePane(model: model)
            case .background: BackgroundPane(model: model)
            case .combine: CombinePane(model: model)
            }
        }
        .padding(14)
    }
}

private struct ResizePane: View {
    let model: EditorModel
    @State private var width = ""
    @State private var height = ""
    @State private var keepAspect = true

    var body: some View {
        let px = model.pixelSize
        VStack(alignment: .leading, spacing: 12) {
            Text("Now %@ × %@ px".loc("\(Int(px.width))", "\(Int(px.height))")).font(.orbitCaption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                field("Width", text: $width) { w in
                    if keepAspect, let v = Double(w) { height = "\(Int((v * px.height / max(1, px.width)).rounded()))" }
                }
                Image(systemName: keepAspect ? "link" : "link.badge.plus")
                    .foregroundStyle(keepAspect ? Palette.accent : .secondary)
                    .onTapGesture { keepAspect.toggle() }
                    .hoverHint(keepAspect ? "Keeping the shape".loc : "Free size".loc)
                field("Height", text: $height) { h in
                    if keepAspect, let v = Double(h) { width = "\(Int((v * px.width / max(1, px.height)).rounded()))" }
                }
            }
            HStack(spacing: 6) {
                ForEach([25, 50, 75, 150, 200], id: \.self) { pct in
                    Button("\(pct)%") { set(scale: CGFloat(pct) / 100) }.controlSize(.small)
                }
            }
            if model.pixelScale > 1.01 {
                Button { set(scale: 1 / model.pixelScale) } label: {
                    Label("Make it 1× (non-Retina)", systemImage: "rectangle.compress.vertical")
                }
                .controlSize(.small)
                .hoverHint("Same size on screen as you saw it, a quarter of the pixels".loc)
            }
            HStack {
                Spacer()
                Button("Apply") {
                    guard let w = Double(width), let h = Double(height), w > 0, h > 0 else { return }
                    model.resize(toPixels: CGSize(width: w, height: h))
                    reset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(Double(width) == nil || Double(height) == nil)
            }
            Text("Your marks are drawn into the picture when you resize.").font(.orbitMicro).foregroundStyle(.secondary)
        }
        .onAppear(perform: reset)
    }

    private func reset() {
        width = "\(Int(model.pixelSize.width))"
        height = "\(Int(model.pixelSize.height))"
    }

    private func set(scale: CGFloat) {
        width = "\(Int((model.pixelSize.width * scale).rounded()))"
        height = "\(Int((model.pixelSize.height * scale).rounded()))"
    }

    private func field(_ title: String, text: Binding<String>, onEdit: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.loc).font(.orbitMicro).foregroundStyle(.secondary)
            TextField("", text: Binding(get: { text.wrappedValue }, set: { text.wrappedValue = $0.filter(\.isNumber); onEdit(text.wrappedValue) }))
                .textFieldStyle(.roundedBorder)
                .font(.orbitBody.monospacedDigit())
        }
    }
}

private struct BackgroundPane: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Background", isOn: Binding(get: { model.backdrop != nil }, set: { model.setBackdrop($0 ? Backdrop() : nil) }))
                .toggleStyle(.switch)
            if let b = model.backdrop {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 9), spacing: 8) {
                    ForEach(Backdrop.styles.indices, id: \.self) { i in
                        Button { var n = b; n.style = i; model.setBackdrop(n) } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Backdrop(style: i).fill)
                                .overlay {
                                    if Backdrop.styles[i].isEmpty {
                                        Image(systemName: "circle.slash").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(b.style == i ? Palette.accent : .white.opacity(0.2), lineWidth: b.style == i ? 2 : 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                slider("Padding", value: b.padding, in: 0...160) { v in model.adjustBackdrop { $0.padding = v } }
                slider("Corners", value: b.radius, in: 0...40) { v in model.adjustBackdrop { $0.radius = v } }
                Toggle("Shadow", isOn: Binding(get: { b.shadow }, set: { v in var n = b; n.shadow = v; model.setBackdrop(n) }))
                    .toggleStyle(.switch)
            } else {
                Text("Puts the picture on a colourful background with rounded corners and a shadow — nice for sharing.")
                    .font(.orbitCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func slider(_ title: String, value: CGFloat, in range: ClosedRange<CGFloat>, set: @escaping (CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title.loc).font(.orbitCaption)
                Spacer()
                Text("\(Int(value))").font(.orbitCaption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range).controlSize(.small)
        }
    }
}

private struct CombinePane: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.combineAxis) {
                Label("Side by side", systemImage: "rectangle.split.2x1").tag(EditorModel.Axis.horizontal)
                Label("Stacked", systemImage: "rectangle.split.1x2").tag(EditorModel.Axis.vertical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: $model.combineAlignment) {
                ForEach(EditorModel.Alignment.allCases, id: \.self) { a in
                    Text(title(a).loc).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Gap".loc).font(.orbitCaption)
                    Spacer()
                    Text("\(Int(model.combineGap))").font(.orbitCaption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $model.combineGap, in: 0...80).controlSize(.small)
            }
            if model.canRelayout {
                Text("Changing these redoes the last join.").font(.orbitMicro).foregroundStyle(Palette.accent)
            }
            Text("Add a recent capture").font(.orbitCaption.weight(.semibold))
            let recent = CaptureService.shared.recent.filter { $0.fileURL != model.fileURL }.prefix(8)
            if recent.isEmpty {
                Text("No other captures yet.").font(.orbitCaption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(Array(recent)) { c in
                        Button { model.combine(with: c.image) } label: {
                            Image(nsImage: c.image).resizable().aspectRatio(contentMode: .fill)
                                .frame(height: 48).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("Choose a File…") { choose() }.controlSize(.small)
                Spacer()
                Text("or drop a picture on the editor").font(.orbitMicro).foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ a: EditorModel.Alignment) -> String {
        switch (model.combineAxis, a) {
        case (.horizontal, .start): "Top"
        case (.horizontal, .end): "Bottom"
        case (.vertical, .start): "Left"
        case (.vertical, .end): "Right"
        default: "Center"
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        let model = self.model
        // A sheet on the editor, so it can't open behind a floating editor.
        guard let window = EditorWindow.front else {
            guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            model.combine(with: image)
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            model.combine(with: image)
        }
    }
}

/// "Always on top": a small pin by the window buttons. Filled while the editor floats over other windows.
private struct AlwaysOnTopToggle: View {
    @AppStorage(EditorWindow.floatingKey) private var floating = true
    @State private var hovering = false

    var body: some View {
        Button { EditorWindow.setFloating(!floating) } label: {
            Image(systemName: floating ? "pin.fill" : "pin.slash")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(floating ? 45 : 0))
                .foregroundStyle(floating ? Palette.accent : Color.white.opacity(hovering ? 0.9 : 0.55))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .hoverHint(floating ? "Always on top".loc : "Always on top: off".loc)
        .accessibilityLabel("Always on top".loc)
        .accessibilityAddTraits(floating ? .isSelected : [])
    }
}

/// A toolbar tool: round, so the selected one sits in the capsule toolbar like a bead, inset evenly.
/// Grouped tools have a little chevron that opens the rest of their group.
private struct ToolButton: View {
    static let size: CGFloat = 32
    static let inset: CGFloat = 3

    let symbol: String
    let isActive: Bool
    let grouped: Bool
    let onTap: () -> Void
    let onMore: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: Self.size, height: Self.size)
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(enabled ? 1 : 0.35))
                .background(Circle().fill(isActive ? Color.white : Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
                .onTapGesture(perform: onTap)
                .onLongPressGesture(minimumDuration: 0.35, perform: { if grouped { onMore() } })
            if grouped {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .heavy))
                    .foregroundStyle(isActive ? Color.black.opacity(0.55) : Color.white.opacity(0.55))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onMore)
                    .offset(x: -1, y: -1)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

#if DEBUG
extension EditorWindow {
    /// Debug: draws in the open editor as a drag from `start` to `end` would (picture points), for promo
    /// frames; `done` ends the drag. Returns the editor's window number.
    /// `tool` switches tools first (by name); a nil `start` just clears the mark being drawn.
    static func debugDrag(from start: CGPoint?, to end: CGPoint, done: Bool, tool: String?) -> Int? {
        guard let window = Self.open.first(where: \.isVisible) else { return nil }
        let model = window.model
        if let tool = tool.flatMap(Annotation.Tool.init(rawValue:)), model.tool != tool { model.tool = tool }
        if let start {
            if done { model.dragEnded(at: end, start: start) } else { model.dragChanged(from: start, to: end) }
        } else {
            model.draft = nil
        }
        return window.windowNumber
    }

    static func debugCloseAll() {
        Self.open.forEach { $0.close() }
    }
}
#endif
