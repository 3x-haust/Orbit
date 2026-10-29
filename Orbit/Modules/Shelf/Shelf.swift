import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

extension Pref {
    /// Which screen edge the shelf slides out of: Shelf.Edge raw value.
    static let shelfPosition = "shelf.edge"
}

/// A temporary holding spot for files, images and text — drop things in, drag them out later.
/// Opens from the Ring/launcher/shortcut, or by dragging a file to the shelf's screen edge. It
/// slides out of the display's black bezel on that edge — out of the notch, when it's the top.
@MainActor @Observable
final class Shelf {
    static let shared = Shelf()

    enum Edge: String, CaseIterable, Identifiable {
        case right, left, top, bottom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .right: "Right"
            case .left: "Left"
            case .top: "Top"
            case .bottom: "Bottom"
            }
        }

        var isVertical: Bool { self == .left || self == .right }
    }

    static var edge: Edge { Edge(rawValue: Pref.defaults.string(forKey: Pref.shelfPosition) ?? "") ?? .right }

    struct Item: Identifiable, Equatable {
        enum Content: Equatable {
            case file(URL)
            case image(NSImage)
            case text(String)
        }
        let id = UUID()
        let content: Content
        let added = Date()

        var title: String {
            switch content {
            case .file(let url): url.lastPathComponent
            case .image: "Image".loc
            case .text(let s): s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? s
            }
        }

        var subtitle: String {
            switch content {
            case .file(let url):
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Double($0).orbitBytes }
                return [url.deletingLastPathComponent().lastPathComponent, size].compactMap { $0 }.joined(separator: " · ")
            case .image(let img): return "\(Int(img.size.width)) × \(Int(img.size.height))"
            case .text(let s): return "%ld characters".loc(s.count)
            }
        }

        var provider: NSItemProvider {
            switch content {
            case .file(let url): NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
            case .image(let img): NSItemProvider(object: img)
            case .text(let s): NSItemProvider(object: s as NSString)
            }
        }
    }

    private(set) var items: [Item] = []
    var isVisible: Bool { panel.isVisible }

    /// Where the shelf is showing now, for the view: which edge it's attached to, how far the notch
    /// reaches into it, and whether it's out (slid in from the edge) or tucked back.
    @ObservationIgnored let layout = Layout()

    @Observable final class Layout {
        var edge: Edge = .right
        /// Room the notch (or menu bar) takes at the top of a top-edge shelf.
        var notch: CGFloat = 0
        /// The notch's width, when a top-edge shelf grows out of one; 0 otherwise (it then grows out of
        /// a short stretch of the screen's top edge).
        var neck: CGFloat = 0
        var out = false
    }

    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        // Over the menu bar and the Dock: it comes out of the screen's very edge.
        p.level = .statusBar
        p.hasShadow = false
        p.setContent(ShelfView(shelf: self, layout: layout))
        p.onEscape = { [weak self] in self?.hide(); return true }
        return p
    }()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var dragCountAtMouseDown = 0
    @ObservationIgnored private var edgeSince: Date?
    @ObservationIgnored private var hideWork: DispatchWorkItem?

    /// The shelf's body on a left or right edge; turned on its side for the bottom. The ears take
    /// their share of the length, so the whole shape stays as long as it always was.
    static let size = CGSize(width: 290, height: 392)
    /// Room around the body on the sides away from the edge, for its shadow.
    static let margin: CGFloat = 26
    /// The concave "ears" where the body meets the bezel: long and gentle, so the body flows out of
    /// the edge instead of sitting on it.
    static let ear: CGFloat = 58
    /// How deep those ears reach in from the edge.
    static let earDepth: CGFloat = 30
    /// How far the window reaches past the screen edge, so no light seam is left at the bezel line.
    static let bleed: CGFloat = 2

    static func bodySize(_ edge: Edge) -> CGSize {
        switch edge {
        case .left, .right: size
        case .bottom: CGSize(width: 372, height: 330)
        // Out of the notch at full size: wide enough to read as the notch grown, not a box under it.
        case .top: CGSize(width: 440, height: 340)
        }
    }

    func toggle() { isVisible ? hide() : show() }

    func show(on target: NSScreen? = nil) {
        hideWork?.cancel()
        hideWork = nil
        let screen = target ?? NSScreen.active
        let edge = Self.edge
        let frame = Self.frame(edge, on: screen)
        layout.edge = edge
        layout.notch = edge == .top ? max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY) : 0
        layout.neck = 0
        if edge == .top, screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            layout.neck = max(0, r.minX - l.maxX)
        }
        if !isVisible || panel.frame != frame {
            layout.out = false
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        }
        // Next runloop turn, so the tucked-away state has drawn before it slides out. No bounce: an
        // overshoot would pull the body off the bezel for a moment and show the wallpaper behind.
        // At the top it grows out of the notch, so a little give in its size is fine: the top stays flush.
        let spring: Animation = edge == .top ? .spring(duration: 0.45, bounce: 0.14) : .spring(duration: 0.4, bounce: 0)
        DispatchQueue.main.async { [layout] in
            withAnimation(Motion.adaptive(spring)) { layout.out = true }
        }
    }

    func hide() {
        guard isVisible else { return }
        withAnimation(Motion.adaptive(.spring(duration: layout.edge == .top ? 0.3 : 0.28, bounce: 0))) { layout.out = false }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.layout.out else { return }
                self.panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34, execute: work)
    }

    /// Call after the edge setting changes: a showing shelf moves there right away.
    func edgeChanged() {
        if isVisible { show() }
    }

    /// The window: flush with the screen edge, the body centred along it (under the notch at the
    /// top), with ears on both sides at the edge and shadow room everywhere else.
    static func frame(_ edge: Edge, on screen: NSScreen) -> NSRect {
        let f = screen.frame
        let v = screen.visibleFrame
        let body = bodySize(edge)
        let m = margin, e = ear, b = bleed
        // The body is `bleed` deeper than it looks; that sliver sits past the screen edge.
        switch edge {
        case .right:
            let h = body.height + 2 * max(m, e)
            return NSRect(x: f.maxX - body.width - m, y: v.midY - h / 2, width: body.width + m + b, height: h)
        case .left:
            let h = body.height + 2 * max(m, e)
            return NSRect(x: f.minX - b, y: v.midY - h / 2, width: body.width + m + b, height: h)
        case .top:
            let w = body.width + 2 * max(m, e)
            var mid = f.midX
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea { mid = (l.maxX + r.minX) / 2 }
            return NSRect(x: mid - w / 2, y: f.maxY - body.height - m, width: w, height: body.height + m + b)
        case .bottom:
            let w = body.width + 2 * max(m, e)
            return NSRect(x: f.midX - w / 2, y: f.minY - b, width: w, height: body.height + m + b)
        }
    }

    func add(_ content: Item.Content) {
        if case .file(let url) = content, items.contains(where: { $0.content == .file(url) }) { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { items.insert(Item(content: content), at: 0) }
    }

    func remove(_ item: Item) {
        withAnimation(.spring(duration: 0.3)) { items.removeAll { $0.id == item.id } }
    }

    func clear() {
        withAnimation(.spring(duration: 0.3)) { items.removeAll() }
    }

    /// Accepts files, images and text from any drag.
    func accept(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in Shelf.shared.add(.file(url)) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage else { return }
                    Task { @MainActor in Shelf.shared.add(.image(img)) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s, !s.isEmpty else { return }
                    Task { @MainActor in Shelf.shared.add(.text(s)) }
                }
            }
        }
        return !providers.isEmpty
    }

    /// Puts every item on the pasteboard at once — paste into Finder, Mail, Slack…
    func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        let objects: [NSPasteboardWriting] = items.map {
            switch $0.content {
            case .file(let url): url as NSURL
            case .image(let img): img
            case .text(let s): s as NSString
            }
        }
        pb.writeObjects(objects)
        Toast.show(items.count == 1 ? "Copied 1 item".loc : "Copied %ld items".loc(items.count), symbol: "doc.on.doc.fill")
    }

    // MARK: Edge reveal

    /// Dragging something to the shelf's edge of the screen opens it there.
    func startEdgeReveal() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard Pref.defaults.bool(forKey: Pref.shelfEdge) else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in
            MainActor.assumeIsolated { Shelf.shared.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { _ in
            MainActor.assumeIsolated { Shelf.shared.dragMoved() }
        }) { monitors.append(m) }
    }

    private func dragMoved() {
        guard !isVisible, NSPasteboard(name: .drag).changeCount != dragCountAtMouseDown else { edgeSince = nil; return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let f = screen.frame
        // Corners belong to Hot Corners; the shelf answers along the rest of its edge.
        let corner: CGFloat = 48
        let atEdge: Bool
        switch Self.edge {
        case .right: atEdge = p.x >= f.maxX - 3 && p.y > f.minY + corner && p.y < f.maxY - corner
        case .left: atEdge = p.x <= f.minX + 2 && p.y > f.minY + corner && p.y < f.maxY - corner
        case .top: atEdge = p.y >= f.maxY - 3 && p.x > f.minX + corner && p.x < f.maxX - corner
        case .bottom: atEdge = p.y <= f.minY + 2 && p.x > f.minX + corner && p.x < f.maxX - corner
        }
        guard atEdge else { edgeSince = nil; return }
        // The Dock lives at the bottom too: there, hold the drag at the edge a moment first.
        if Self.edge == .bottom {
            if edgeSince == nil { edgeSince = Date() }
            guard let since = edgeSince, Date().timeIntervalSince(since) > 0.45 else { return }
        }
        edgeSince = nil
        show(on: screen)
    }
}

// MARK: - View

private struct ShelfView: View {
    let shelf: Shelf
    let layout: Shelf.Layout
    @State private var targeted = false

    var body: some View {
        Group {
            if layout.edge == .top { notchBody } else { sideBody }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.25), value: targeted)
        .onDrop(of: [.fileURL, .image, .plainText], isTargeted: $targeted) { shelf.accept($0) }
    }

    /// Top edge: the notch itself grows into the shelf, Dynamic Island style — one pure-black shape,
    /// flush with the top of the screen across its whole width, its ears flowing into the screen's top
    /// edge. Closed, it's the notch's own size and sits inside it.
    private var notchBody: some View {
        let size = Shelf.bodySize(.top)
        let notched = layout.neck > 0
        let wide = 2 * Shelf.ear
        let full = CGSize(width: size.width + wide, height: size.height + Shelf.bleed)
        // Closed: the notch (or, without one, a sliver of the top edge), with ears and corners to match.
        let seed = notched ? CGSize(width: layout.neck - 2, height: max(0, layout.notch - 2)) : CGSize(width: 160 + wide, height: 0)
        let now = layout.out ? full : seed
        let shape = BezelShape(edge: .top, radius: layout.out || !notched ? 26 : 9,
                               ear: layout.out || !notched ? Shelf.ear : 3, earDepth: layout.out || !notched ? Shelf.earDepth : 3)
        return ZStack(alignment: .top) {
            Color.clear
            shape.fill(.black)
                .shadow(color: .black.opacity(layout.out ? 0.45 : 0), radius: 18, y: 8)
                .mask { edgeFade(.top, clear: layout.notch + Shelf.bleed + 6, solid: layout.notch + 70, spill: 44) }
                .frame(width: now.width, height: now.height)
            shape.fill(.black)
                .frame(width: now.width, height: now.height)
            content
                // Below the menu bar's line: up there it's the notch's black.
                .padding(.top, layout.notch)
                .frame(width: size.width, height: size.height)
                .padding(.horizontal, wide / 2)
                .padding(bleedInsets(.top))
                .overlay { dropTarget(.top) }
                // Shows once the shape is most of the way grown; goes first on the way back.
                .opacity(layout.out ? 1 : 0)
                .animation(layout.out ? .easeOut(duration: 0.2).delay(0.24) : .easeIn(duration: 0.1), value: layout.out)
                .mask(alignment: .top) { shape.frame(width: now.width, height: now.height) }
        }
    }

    /// Left, right and bottom: slides out of the bezel, pinned to it the whole way.
    private var sideBody: some View {
        let edge = layout.edge
        let size = Shelf.bodySize(edge)
        let shape = BezelShape(edge: edge, radius: 22, ear: Shelf.ear, earDepth: Shelf.earDepth)
        let outline = BezelShape(edge: edge, radius: 22, ear: Shelf.ear, earDepth: Shelf.earDepth, open: true)
        return ZStack(alignment: alignment(edge)) {
            Color.clear
            content
                .frame(width: size.width, height: size.height)
                .padding(earInsets(edge))
                .padding(bleedInsets(edge))
                .background {
                    ZStack {
                        // The shadow only falls away from the edge; next to the bezel there's nothing to lift.
                        shape.fill(.black)
                            .shadow(color: .black.opacity(0.5), radius: 18, x: shadowOffset(edge).width, y: shadowOffset(edge).height)
                            .mask { edgeFade(edge, clear: Shelf.ear + Shelf.bleed + 10, solid: Shelf.ear + 60, spill: 44) }
                        // Pure bezel black at the edge — held a while — then a hint of lift on the far side.
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5),
                                               .init(color: Color(white: 0.06), location: 1)],
                                       startPoint: from(edge), endPoint: to(edge))
                            .clipShape(shape)
                    }
                }
                .overlay {
                    // A faint hairline only on the far side, fading out well before the bezel.
                    outline.stroke(.white.opacity(0.08), lineWidth: 1)
                        .mask { edgeFade(edge, clear: Shelf.ear + Shelf.bleed + 20, solid: Shelf.ear + 80, spill: 4) }
                    dropTarget(edge)
                }
                .offset(hiddenOffset(edge, size: size))
        }
    }

    @ViewBuilder private func dropTarget(_ edge: Shelf.Edge) -> some View {
        if targeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .padding(earInsets(edge))
                .padding(bleedInsets(edge))
                .padding(8)
                .padding(.top, edge == .top ? layout.notch : 0)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                OrbitMark(size: 16, dot: true)
                Text("Shelf").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                if !shelf.items.isEmpty {
                    Text("\(shelf.items.count)").font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.canvas).padding(.horizontal, 6).frame(height: 16)
                        .background(Capsule().fill(Palette.ink))
                        .contentTransition(.numericText())
                }
                Spacer()
                if !shelf.items.isEmpty {
                    IconButton(symbol: "doc.on.doc", help: "Copy all") { shelf.copyAll() }
                    IconButton(symbol: "trash", help: "Clear shelf") { shelf.clear() }
                }
                IconButton(symbol: "xmark", help: "Close (Esc)") { shelf.hide() }
            }
            .padding(.horizontal, 12).frame(height: 44)
            Rectangle()
                .fill(LinearGradient(stops: hairlineStops(layout.edge), startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            if shelf.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(targeted ? Palette.accent : Palette.inkSecondary)
                        .symbolEffect(.bounce, value: targeted)
                    Text("Drop files here").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Keep them handy, then drag them\nwherever they need to go.")
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(shelf.items) { item in
                            ShelfRow(item: item, shelf: shelf)
                                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
            }
        }
    }

    /// Where the body sits in the window: against the screen edge.
    private func alignment(_ e: Shelf.Edge) -> Alignment {
        switch e {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }

    /// The sliver of body past the screen edge.
    private func bleedInsets(_ e: Shelf.Edge) -> EdgeInsets {
        let b = Shelf.bleed
        switch e {
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: b)
        case .left: return EdgeInsets(top: 0, leading: b, bottom: 0, trailing: 0)
        case .top: return EdgeInsets(top: b, leading: 0, bottom: 0, trailing: 0)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: b, trailing: 0)
        }
    }

    /// Away from the edge.
    private func shadowOffset(_ e: Shelf.Edge) -> CGSize {
        switch e {
        case .right: CGSize(width: -4, height: 4)
        case .left: CGSize(width: 4, height: 4)
        case .top: CGSize(width: 0, height: 6)
        case .bottom: CGSize(width: 0, height: -6)
        }
    }

    /// A mask that's clear for `clear` points from the edge and solid from `solid` on; `spill` grows it
    /// past the view's bounds so shadows outside them survive.
    private func edgeFade(_ e: Shelf.Edge, clear: CGFloat, solid: CGFloat, spill: CGFloat) -> some View {
        GeometryReader { g in
            let length = (e.isVertical ? g.size.width : g.size.height)
            let a = min(0.98, max(0, (clear + 0) / length)), b = min(0.99, max(a + 0.01, solid / length))
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: a), .init(color: .white, location: b),
                                   .init(color: .white, location: 1)],
                           startPoint: from(e), endPoint: to(e))
        }
        .padding(-spill)
        // Keep the spill off the edge side: past the bezel line nothing should draw.
        .padding(edgeOnly(e, spill))
    }

    private func edgeOnly(_ e: Shelf.Edge, _ x: CGFloat) -> EdgeInsets {
        switch e {
        case .right: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: x)
        case .left: EdgeInsets(top: 0, leading: x, bottom: 0, trailing: 0)
        case .top: EdgeInsets(top: x, leading: 0, bottom: 0, trailing: 0)
        case .bottom: EdgeInsets(top: 0, leading: 0, bottom: x, trailing: 0)
        }
    }

    /// The header's divider fades out toward the bezel, so it doesn't touch it.
    private func hairlineStops(_ e: Shelf.Edge) -> [Gradient.Stop] {
        let line = Palette.hairline
        switch e {
        case .right: return [.init(color: line, location: 0), .init(color: line, location: 0.7), .init(color: .clear, location: 1)]
        case .left: return [.init(color: .clear, location: 0), .init(color: line, location: 0.3), .init(color: line, location: 1)]
        default: return [.init(color: line, location: 0), .init(color: line, location: 1)]
        }
    }

    /// The ears stick out along the edge; the content stays clear of them.
    private func earInsets(_ e: Shelf.Edge) -> EdgeInsets {
        let x = Shelf.ear
        return e.isVertical ? EdgeInsets(top: x, leading: 0, bottom: x, trailing: 0) : EdgeInsets(top: 0, leading: x, bottom: 0, trailing: x)
    }

    private func from(_ e: Shelf.Edge) -> UnitPoint {
        switch e {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func to(_ e: Shelf.Edge) -> UnitPoint {
        switch e {
        case .right: .leading
        case .left: .trailing
        case .top: .bottom
        case .bottom: .top
        }
    }

    /// Tucked: pushed past the screen edge, where the window's own bounds cut it off — so it slides
    /// out from the bezel line itself.
    private func hiddenOffset(_ e: Shelf.Edge, size: CGSize) -> CGSize {
        guard !layout.out else { return .zero }
        let reach = (e.isVertical ? size.width : size.height + layout.notch) + 30
        switch e {
        case .right: return CGSize(width: reach, height: 0)
        case .left: return CGSize(width: -reach, height: 0)
        case .top: return CGSize(width: 0, height: -reach)
        case .bottom: return CGSize(width: 0, height: reach)
        }
    }
}

/// The shelf's outline: square against the screen edge with concave ears flaring into it (like the
/// notch's), rounded corners on the far side. `open` leaves out the edge side, for the hairline.
/// The corners and ears animate too, so the top shelf grows from the notch's own small corners.
private struct BezelShape: Shape {
    let edge: Shelf.Edge
    var radius: CGFloat
    /// The concave ears where the body meets the screen edge: `ear` along it, `earDepth` in from it.
    var ear: CGFloat
    var earDepth: CGFloat = 20
    var open = false

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(radius, AnimatablePair(ear, earDepth)) }
        set { radius = newValue.first; ear = newValue.second.first; earDepth = newValue.second.second }
    }

    /// Circle-like quarter arcs from cubics; the concave ones a touch longer, for a softer flow.
    private let k: CGFloat = 0.552, soft: CGFloat = 0.74

    func path(in rect: CGRect) -> Path {
        // Draw for a top edge, then turn the drawing to the real edge.
        let turned = edge.isVertical
        let w = turned ? rect.height : rect.width
        let h = turned ? rect.width : rect.height
        var p = eared(w, h)
        if !open { p.closeSubpath() }

        let t: CGAffineTransform
        switch edge {
        case .top: t = .identity
        case .bottom: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.height)
        // Rotate so the drawing's edge (y = 0) lands on x = maxX / x = 0.
        case .right: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.width, ty: 0)
        case .left: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        }
        return p.applying(t).applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Edge at y = 0: concave ears flaring out of the bezel, tangent to it, tapering into the body.
    private func eared(_ w: CGFloat, _ h: CGFloat) -> Path {
        let e = min(ear, w / 3)
        let r = min(radius, h / 2, (w - 2 * e) / 2)
        let d = min(earDepth, max(0, h - r))
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addCurve(to: CGPoint(x: e, y: d), control1: CGPoint(x: e * soft, y: 0), control2: CGPoint(x: e, y: d * (1 - soft)))
        p.addLine(to: CGPoint(x: e, y: h - r))
        p.addCurve(to: CGPoint(x: e + r, y: h), control1: CGPoint(x: e, y: h - r * (1 - k)), control2: CGPoint(x: e + r * (1 - k), y: h))
        p.addLine(to: CGPoint(x: w - e - r, y: h))
        p.addCurve(to: CGPoint(x: w - e, y: h - r), control1: CGPoint(x: w - e - r * (1 - k), y: h), control2: CGPoint(x: w - e, y: h - r * (1 - k)))
        p.addLine(to: CGPoint(x: w - e, y: d))
        p.addCurve(to: CGPoint(x: w, y: 0), control1: CGPoint(x: w - e, y: d * (1 - soft)), control2: CGPoint(x: w - e * soft, y: 0))
        return p
    }
}

// MARK: - Settings

/// Pick the shelf's edge on a little screen: click one of its four sides.
struct ShelfEdgePicker: View {
    @AppStorage(Pref.shelfPosition) private var raw = Shelf.Edge.right.rawValue
    @State private var hover: Shelf.Edge?

    var body: some View {
        let selected = Shelf.Edge(rawValue: raw) ?? .right
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .padding(3)
                // The notch.
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3).fill(Color.black)
                    .frame(width: 18, height: 5).frame(maxHeight: .infinity, alignment: .top).padding(.top, 3)
                ForEach(Shelf.Edge.allCases) { e in
                    tab(e, on: e == selected)
                }
            }
            .frame(width: 96, height: 62)
            .environment(\.colorScheme, .dark)
            Text((hover ?? selected).title.loc)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                .frame(minWidth: 44, alignment: .leading)
                .contentTransition(.opacity)
        }
        .animation(.spring(duration: 0.3, bounce: 0.25), value: raw)
        .animation(Motion.hover, value: hover)
    }

    private func tab(_ e: Shelf.Edge, on: Bool) -> some View {
        let long: CGFloat = e.isVertical ? 22 : 34
        let thick: CGFloat = on ? 7 : 5
        return Button {
            raw = e.rawValue
            Shelf.shared.edgeChanged()
        } label: {
            UnevenRoundedRectangle(cornerRadii: radii(e), style: .continuous)
                .fill(on ? Palette.accent : Color.white.opacity(hover == e ? 0.55 : 0.28))
                .frame(width: e.isVertical ? thick : long, height: e.isVertical ? long : thick)
                .padding(e.isVertical ? .vertical : .horizontal, 6)
                .padding(e.isVertical ? .horizontal : .vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hover = h ? e : (hover == e ? nil : hover) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align(e))
        .padding(e == .top ? EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0) : EdgeInsets())
        .help("Shelf on the %@ edge".loc(e.title.loc.lowercased()))
        .accessibilityLabel(e.title.loc)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func align(_ e: Shelf.Edge) -> Alignment {
        switch e {
        case .right: .trailing
        case .left: .leading
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func radii(_ e: Shelf.Edge) -> RectangleCornerRadii {
        let r: CGFloat = 3
        switch e {
        case .right: return RectangleCornerRadii(topLeading: r, bottomLeading: r)
        case .left: return RectangleCornerRadii(bottomTrailing: r, topTrailing: r)
        case .top: return RectangleCornerRadii(bottomLeading: r, bottomTrailing: r)
        case .bottom: return RectangleCornerRadii(topLeading: r, topTrailing: r)
        }
    }
}

private struct ShelfRow: View {
    let item: Shelf.Item
    let shelf: Shelf
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Text(item.subtitle).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Palette.inkSecondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Palette.raised : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .onDrag { item.provider }
        .onTapGesture(count: 2) { open() }
        .contextMenu {
            Button("Open") { open() }
            if case .file(let url) = item.content {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(objects)
            }
            Divider()
            Button("Remove", role: .destructive) { shelf.remove(item) }
        }
        .help("Drag out, or double-click to open")
    }

    private var objects: [NSPasteboardWriting] {
        switch item.content {
        case .file(let url): [url as NSURL]
        case .image(let img): [img]
        case .text(let s): [s as NSString]
        }
    }

    @ViewBuilder private var thumbnail: some View {
        switch item.content {
        case .file(let url):
            if let img = NSImage(contentsOf: url), ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"].contains(url.pathExtension.lowercased()) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().padding(2)
            }
        case .image(let img):
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        case .text:
            Image(systemName: "text.alignleft").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.raised)
        }
    }

    private func open() {
        switch item.content {
        case .file(let url): NSWorkspace.shared.open(url)
        case .image(let img): EditorWindow.open(image: img, fileURL: nil)
        case .text(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            Toast.show("Text copied")
        }
    }
}
