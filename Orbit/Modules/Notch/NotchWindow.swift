import AppKit
import SwiftUI

/// Sizes of the notch's shapes. Every one starts from the notch's own size, so each state reads as
/// the notch changing shape rather than something dropping in front of it.
enum NotchGeometry {
    /// The concave fillets where the shape flows into the top edge of the screen: how far out
    /// along it, and how far down. Small at rest, like the camera housing's own; fuller as it grows.
    static func ear(_ phase: NotchCenter.Phase) -> (width: CGFloat, depth: CGFloat) {
        switch phase {
        case .hidden, .idle: (6, 6)
        case .ears, .hud: (9, 11)
        case .peek, .banner, .expanded: (14, 18)
        }
    }

    /// Inside an ear: from the shape's rounded end, and from the camera.
    static let earOuterPadding: CGFloat = 11
    static let earInnerPadding: CGFloat = 6
    /// The camera housing's own bottom corners.
    static let restRadius: CGFloat = 8
    /// Narrower than this, an ear isn't worth showing.
    static let minEar: CGFloat = 26

    /// How wide each ear (either side of the camera) would like to be.
    static func earWidth(_ ear: NotchCenter.Ear) -> CGFloat {
        switch ear {
        case .music: 40
        case .timer: 54
        case .recording: 46
        case .download: 58
        case .awake: 38
        case .charging: 76
        }
    }

    static let hudEar: CGFloat = 92

    /// The shape's outer size, its fillets included. `room` caps the ears so they stay off the menus.
    static func shape(_ phase: NotchCenter.Phase, notch n: CGSize, config c: NotchCenter.Config, room: CGFloat = .infinity) -> CGSize {
        let s = ear(phase).width * 2
        switch phase {
        case .hidden, .idle: return CGSize(width: n.width + s, height: n.height)
        case .ears(let e): return CGSize(width: n.width + 2 * min(earWidth(e), room).rounded(.down) + s, height: n.height)
        // Brief, so it may cover a menu for a moment, but never less than it needs to read.
        case .hud: return CGSize(width: n.width + 2 * max(min(hudEar, room), 64).rounded(.down) + s, height: n.height)
        case .peek: return CGSize(width: max(n.width + 160, 330) + s, height: n.height + 52)
        case .banner: return CGSize(width: max(n.width + 180, 370) + s, height: n.height + 68)
        case .expanded: return CGSize(width: (560 * c.scale).rounded() + s, height: n.height + (184 * c.scale).rounded())
        }
    }

    static func radius(_ phase: NotchCenter.Phase, config c: NotchCenter.Config) -> CGFloat {
        switch phase {
        case .hidden, .idle: restRadius
        // Ears and HUDs end a little rounder than the housing, so they read as one pill.
        case .ears, .hud: restRadius + 3
        case .peek: min(c.radius, 28)
        case .banner: c.radius + 4
        case .expanded: c.radius + 10
        }
    }

    /// Room around the shape for its shadow, and for the spring's overshoot.
    static func margin(_ phase: NotchCenter.Phase, config c: NotchCenter.Config) -> (side: CGFloat, bottom: CGFloat) {
        guard c.shadow, !phase.collapsed, phase != .hidden else { return (4, 2) }
        return (30, 36)
    }
}

/// What a notch window's view needs from its window.
@MainActor @Observable
final class NotchWindowModel {
    var notch: CGSize
    @ObservationIgnored var onPhase: (() -> Void)?
    init(notch: CGSize) { self.notch = notch }
}

/// One per screen, flush with the top, and always the same size: big enough for the largest shape
/// (the open notch at its biggest, with its shadow). It never moves or resizes while the shape
/// morphs — resizing a window mid-animation moves its content for a frame (AppKit's origin is at
/// the bottom), which showed as the shape detaching from the top and rising. The shape is drawn
/// top-anchored inside it. It ignores the mouse except while the pointer is over the shape as it is
/// right now (NotchCenter watches the pointer and flips that), so the menu bar and the windows
/// under its clear part stay clickable.
@MainActor
final class NotchWindow: NSPanel {
    let display: CGDirectDisplayID
    private(set) var targetScreen: NSScreen?
    private let model: NotchWindowModel

    init(screen: NSScreen) {
        display = screen.displayID
        model = NotchWindowModel(notch: screen.notchSize)
        targetScreen = screen
        super.init(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        let host = NotchHostingView(rootView: NotchRoot(display: display, model: model))
        host.display = display
        host.sizingOptions = []
        host.safeAreaRegions = []
        contentView = FloatingPanel.container(for: host)
        model.onPhase = { [weak self] in self?.sync() }
        place(on: screen)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// AppKit would otherwise nudge a window off the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Sizes and places the window for this screen and the current settings. Only on setup and
    /// when the screen or a setting changes — never during a morph.
    func place(on screen: NSScreen) {
        targetScreen = screen
        if model.notch != screen.notchSize { model.notch = screen.notchSize }
        let size = Self.size(notch: model.notch, config: NotchCenter.shared.config)
        let frame = NSRect(x: (screen.notchMidX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if self.frame != frame { setFrame(frame, display: true) }
        orderFrontRegardless()
    }

    /// The state just changed: the shape under the pointer may have come or gone.
    func sync() {
        let phase = NotchCenter.shared.phase(on: display)
        if phase.isEars { NotchCenter.shared.measureRooms() }
        NotchCenter.shared.pointerMoved(NSEvent.mouseLocation)
    }

    /// Where the shape is (where it's headed, mid-morph), in screen coordinates; nil while hidden.
    /// Closed, a little more below and beside the notch counts, so it's easy to point at.
    func hitRect() -> NSRect? {
        guard let s = targetScreen else { return nil }
        let c = NotchCenter.shared
        let phase = c.phase(on: display)
        guard phase != .hidden else { return nil }
        let shape = NotchGeometry.shape(phase, notch: model.notch, config: c.config, room: c.room(on: display))
        var r = NSRect(x: s.notchMidX - shape.width / 2, y: s.frame.maxY - shape.height, width: shape.width, height: shape.height)
        if phase.collapsed { r = NSRect(x: r.minX - 4, y: r.minY - 6, width: r.width + 8, height: r.height + 6) }
        // The very top row of the screen counts as inside.
        r.size.height += 1
        return r
    }

    /// Room for every shape there is, with the spring's overshoot and the shadow.
    static func size(notch: CGSize, config c: NotchCenter.Config) -> CGSize {
        let phases: [NotchCenter.Phase] = [.expanded, .banner, .peek, .hud, .ears(.charging(true))]
        var w: CGFloat = 0, h: CGFloat = 0
        for p in phases {
            let s = NotchGeometry.shape(p, notch: notch, config: c)
            w = max(w, s.width * 1.04 + 60)
            h = max(h, s.height * 1.04 + 40)
        }
        return CGSize(width: (w / 2).rounded(.up) * 2, height: h.rounded(.up))
    }
}

extension NotchCenter.Phase {
    var isEars: Bool { if case .ears = self { true } else { false } }
}

struct NotchRoot: View {
    let display: CGDirectDisplayID
    let model: NotchWindowModel

    var body: some View {
        NotchSurfaceView(display: display, model: model).orbitTint()
    }
}

/// Clicks land on the first try (the panel never activates Orbit), and two-finger swipes on the
/// notch open and close it.
final class NotchHostingView: NSHostingView<NotchRoot> {
    var display: CGDirectDisplayID = 0

    required init(rootView: NotchRoot) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        NotchCenter.shared.scroll(event, on: display)
    }
}

/// The notch itself: the black shape, and whatever it holds right now.
struct NotchSurfaceView: View {
    let display: CGDirectDisplayID
    let model: NotchWindowModel
    @State private var targeted = false
    private var center: NotchCenter { .shared }

    var body: some View {
        let p = center.phase(on: display)
        let c = center.config
        let size = NotchGeometry.shape(p, notch: model.notch, config: c, room: center.room(on: display))
        let radius = NotchGeometry.radius(p, config: c)
        let ear = NotchGeometry.ear(p)
        let shape = NotchBezelShape(radius: radius, ear: ear.width, earDepth: ear.depth, minBody: model.notch)
        ZStack(alignment: .top) {
            shape.fill(.black)
                .shadow(color: .black.opacity(NotchGeometry.margin(p, config: c).side > 4 ? 0.5 : 0), radius: 16, y: 6)
                .frame(width: size.width, height: size.height)
            NotchContent(phase: p, size: size, notch: model.notch, display: display)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { if p.collapsed { center.toggle(on: display) } }
        .onDrop(of: [.fileURL, .image, .plainText, .url], isTargeted: $targeted) { center.drop($0) }
        .onChange(of: targeted) { center.setDropTargeted(targeted, on: display) }
        .opacity(p == .hidden ? 0 : 1)
        // Out of full screen: a quick pop, not the morph's spring.
        .animation(.easeOut(duration: 0.12), value: p == .hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(NotchCenter.morph, value: p)
        .animation(NotchCenter.morph, value: size)
        .onChange(of: p) { model.onPhase?() }
        .onChange(of: size) { model.onPhase?() }
    }
}

/// The notch's outline, one path for every state and every frame of a morph: concave fillets
/// tangent to the screen's top edge at both ends, straight sides, rounded bottom corners. The top
/// edge is the widest part and the fillets only flare outward, so it reads as one shape grown out
/// of the bezel. Its body never gets smaller than the camera housing (`minBody`), however far the
/// spring swings back — so the menu bar beside the camera never shows through.
struct NotchBezelShape: Shape {
    var radius: CGFloat
    var ear: CGFloat
    var earDepth: CGFloat
    var minBody: CGSize = .zero

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(radius, AnimatablePair(ear, earDepth)) }
        set { radius = newValue.first; ear = newValue.second.first; earDepth = newValue.second.second }
    }

    func path(in rect: CGRect) -> Path {
        let e0 = max(0, ear)
        // Clamp a spring's inward swing: the body stays at least the housing's size, centred, top fixed.
        let w = max(rect.width, minBody.width + 2 * e0), h = max(rect.height, minBody.height)
        let x0 = rect.minX - (w - rect.width) / 2
        let e = min(e0, w / 4)
        // A continuous corner runs `reach` times its radius along each edge, so it needs that much room.
        let reach = Self.reach
        let d0 = max(0, min(earDepth, h / 2))
        let r = max(0, min(radius, (h - d0) / reach, (w - 2 * e) / (2 * reach)))
        let d = max(0, min(earDepth, h - r * reach))
        // The fillets are cubics a little longer than a quarter arc (0.74) so they flow.
        let soft: CGFloat = 0.74
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addCurve(to: CGPoint(x: e, y: d), control1: CGPoint(x: e * soft, y: 0), control2: CGPoint(x: e, y: d * (1 - soft)))
        Self.corner(&p, at: CGPoint(x: e, y: h), from: CGVector(dx: 0, dy: -1), to: CGVector(dx: 1, dy: 0), radius: r)
        Self.corner(&p, at: CGPoint(x: w - e, y: h), from: CGVector(dx: -1, dy: 0), to: CGVector(dx: 0, dy: -1), radius: r)
        p.addLine(to: CGPoint(x: w - e, y: d))
        p.addCurve(to: CGPoint(x: w, y: 0), control1: CGPoint(x: w - e, y: d * (1 - soft)), control2: CGPoint(x: w - e * soft, y: 0))
        p.closeSubpath()
        return p.applying(CGAffineTransform(translationX: x0, y: rect.minY))
    }

    static let reach: CGFloat = 1.528665

    /// Adds a line to, then around, the corner at `c` the way iOS rounds its continuous corners
    /// (and the Dynamic Island): curvature eases in along each edge instead of starting at once,
    /// so the corner reads softer and rounder than a quarter circle. `from` points back along the
    /// edge we arrive on, `to` along the edge we leave on.
    static func corner(_ p: inout Path, at c: CGPoint, from u: CGVector, to v: CGVector, radius r: CGFloat) {
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x + (u.dx * a + v.dx * b) * r, y: c.y + (u.dy * a + v.dy * b) * r)
        }
        p.addLine(to: pt(reach, 0))
        p.addCurve(to: pt(0.631494, 0.074911), control1: pt(1.088493, 0), control2: pt(0.868407, 0))
        p.addCurve(to: pt(0.074911, 0.631494), control1: pt(0.372824, 0.169057), control2: pt(0.169057, 0.372824))
        p.addCurve(to: pt(0, reach), control1: pt(0, 0.868407), control2: pt(0, 1.088493))
    }
}

/// Content is pinned at its final size and clipped by the moving shape, and its opacity follows the
/// morph itself: it starts showing a few points out of the notch and is fully there by half way, and
/// on the way back it fades as the shape closes over it. No frame is an empty black box,
/// and an interrupted morph just runs the same curve back from wherever it is.
struct NotchReveal: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let o = min(1, max(0, (progress - 0.04) / 0.36))
        content
            .opacity(o)
            .scaleEffect(0.94 + 0.06 * o, anchor: .top)
            .blur(radius: (1 - o) * 3)
    }
}

extension AnyTransition {
    static let notchContent: AnyTransition = .modifier(active: NotchReveal(progress: 0), identity: NotchReveal(progress: 1))
}
