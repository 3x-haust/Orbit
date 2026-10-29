import AppKit
import SwiftUI
import Observation

/// The Orbit Ring: a radial launcher around the pointer.
///
/// - Hold the trigger, flick toward an action, release → runs it.
/// - Flick past the ring → runs it immediately.
/// - Rest on an action → it fills up and runs (hover-to-activate).
/// - Tap the trigger → ring stays open; click or flick to choose; Esc or the hub closes.
@MainActor @Observable
final class OrbitRing {
    static let shared = OrbitRing()

    static let defaultSlots: [OrbitAction] = [
        .captureArea, .captureText, .winRight, .clipboard, .winMaximize, .launcher, .winLeft, .captureWindow,
    ]

    // Geometry (pt)
    static let size: CGFloat = 340
    static let itemRadius: CGFloat = 112
    static let deadZone: CGFloat = 38
    static let flickRadius: CGFloat = 175

    private(set) var slots: [OrbitAction] = OrbitRing.defaultSlots
    private(set) var selection: Int?
    private(set) var pointerAngle: Double?
    private(set) var dwellProgress: Double = 0
    private(set) var appeared = false

    @ObservationIgnored private var center: CGPoint = .zero
    @ObservationIgnored private var openMouse: CGPoint = .zero
    @ObservationIgnored private var pointerMoved = false
    @ObservationIgnored private var targetWindow: AXUIElement?
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var dwellStart: Date?
    @ObservationIgnored private var dwellTimer: Timer?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero)
        p.level = .popUpMenu
        p.hasShadow = false
        p.acceptsMouseMovedEvents = true
        p.setContent(RingView(ring: self))
        p.onEscape = { [weak self] in self?.close(); return true }
        return p
    }()

    var isVisible: Bool { panel.isVisible }

    static var hoverActivates: Bool { Pref.defaults.object(forKey: "ring.hover") as? Bool ?? true }
    static var dwellSeconds: Double { max(0.2, Pref.defaults.object(forKey: "ring.dwell") as? Double ?? 0.45) }

    /// How many actions the ring can hold. Fewer is quicker to aim; more fits more.
    static let slotRange = 3...12

    static func loadSlots() -> [OrbitAction] {
        let raw = Pref.defaults.stringArray(forKey: "ring.slots") ?? []
        let parsed = raw.compactMap(OrbitAction.init(rawValue:))
        return slotRange.contains(parsed.count) ? parsed : defaultSlots
    }

    /// Items shrink a little past eight so neighbours never touch.
    static func itemScale(_ count: Int) -> CGFloat { count > 8 ? 8.6 / CGFloat(count) : 1 }

    /// "Top", "Top right"… where a slot lands on a compass point, otherwise its number.
    static func slotName(_ i: Int, of count: Int) -> String {
        let names = ["Top", "Top right", "Right", "Bottom right", "Bottom", "Bottom left", "Left", "Top left"]
        let degrees = Double(i) * 360 / Double(count)
        let compass = degrees / 45
        return compass == compass.rounded() ? names[Int(compass) % 8].loc : "Slot %ld".loc(i + 1)
    }

    static func saveSlots(_ slots: [OrbitAction]) {
        Pref.defaults.set(slots.map(\.rawValue), forKey: "ring.slots")
    }

    // MARK: Lifecycle

    /// - Parameter hold: true when opened by a held key/button; release then decides.
    func open(hold: Bool) {
        if isVisible { close(); return }
        slots = Self.loadSlots()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.active.frame
        let half = Self.size / 2
        center = CGPoint(x: min(max(mouse.x, screen.minX + half), screen.maxX - half),
                         y: min(max(mouse.y, screen.minY + half), screen.maxY - half))
        targetWindow = WindowManager.shared.window(at: mouse)
        openMouse = mouse
        pointerMoved = false
        selection = nil
        pointerAngle = nil
        dwellProgress = 0
        holding = hold
        openedAt = Date()
        appeared = false

        panel.present(at: NSRect(x: center.x - half, y: center.y - half, width: Self.size, height: Self.size))
        withAnimation(Motion.adaptive(.spring(duration: 0.32, bounce: 0.18))) { appeared = true }
        installMonitors()
    }

    /// Trigger released. Runs the selection; a quick tap leaves the ring open in "tap mode".
    func release() {
        guard isVisible, holding else { return }
        holding = false
        if let selection { fire(selection); return }
        if Date().timeIntervalSince(openedAt) > 0.35 { close() }
    }

    func close() {
        removeMonitors()
        stopDwell()
        withAnimation(Motion.adaptive(Motion.panelExit)) { appeared = false }
        panel.dismiss()
    }

    func fire(_ index: Int) {
        let action = slots[index]
        let window = targetWindow
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        close()
        // Let the ring fade before captures freeze the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + (action.group == "Capture" ? 0.16 : 0.02)) {
            action.perform(window: window)
        }
    }

    // MARK: Tracking

    private func installMonitors() {
        removeMonitors()
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: moves) { _ in
            MainActor.assumeIsolated { OrbitRing.shared.track(NSEvent.mouseLocation) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: moves) { event in
            MainActor.assumeIsolated { OrbitRing.shared.track(NSEvent.mouseLocation) }
            return event
        } as Any)
        // A click outside the ring dismisses it.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { OrbitRing.shared.close() }
        } as Any)
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    func track(_ p: CGPoint) {
        guard isVisible else { return }
        // Nothing is chosen until the pointer actually moves — the ring may be offset from it near screen edges.
        if !pointerMoved {
            guard hypot(p.x - openMouse.x, p.y - openMouse.y) > 6 else { return }
            pointerMoved = true
        }
        let dx = p.x - center.x, dy = p.y - center.y
        let distance = hypot(dx, dy)
        guard distance > Self.deadZone else {
            pointerAngle = nil
            select(nil)
            return
        }
        // 0 = up, clockwise — matches slot order.
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        pointerAngle = angle
        let step = 2 * .pi / Double(slots.count)
        let index = Int((angle + step / 2) / step) % slots.count
        select(index)

        if distance > Self.flickRadius { fire(index) }
    }

    /// Called from the view for direct clicks.
    func click(_ index: Int?) {
        if let index { fire(index) } else { close() }
    }

    private func select(_ index: Int?) {
        guard index != selection else { return }
        selection = index
        if index != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        startDwell()
    }

    private func startDwell() {
        stopDwell()
        guard Self.hoverActivates, selection != nil else { return }
        dwellStart = Date()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { OrbitRing.shared.tickDwell() }
        }
    }

    private func tickDwell() {
        guard let start = dwellStart, let selection else { stopDwell(); return }
        // Hold mode waits for release; dwell is for tap mode, after a short grace period.
        guard !holding else { dwellProgress = 0; return }
        let delay = 0.08
        dwellProgress = min(1, max(0, (Date().timeIntervalSince(start) - delay) / Self.dwellSeconds))
        if dwellProgress >= 1 { fire(selection) }
    }

    private func stopDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellStart = nil
        dwellProgress = 0
    }
}

// MARK: - View

private struct RingView: View {
    let ring: OrbitRing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = OrbitRing.size
        ZStack {
            // Disc: solid canvas with a hairline — crisp on any wallpaper.
            Circle()
                .fill(Palette.canvas.opacity(0.96))
                .background(VisualEffect(material: .popover).clipShape(Circle()))
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .frame(width: size - 40, height: size - 40)
                .shadow(color: .black.opacity(0.28), radius: 26, y: 12)

            // Faint spokes between slots, so each action's area is visible.
            SlotDividers(count: ring.slots.count, inner: 44, outer: size / 2 - 24)
                .stroke(RadialGradient(colors: [Palette.ink.opacity(0), Palette.ink.opacity(0.07), Palette.ink.opacity(0)],
                                       center: .center, startRadius: 44, endRadius: size / 2 - 24),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round))

            // Orbit track + satellite following the pointer
            Circle()
                .stroke(Palette.ink.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: OrbitRing.itemRadius * 2, height: OrbitRing.itemRadius * 2) // runs through every item's center
            if let angle = ring.pointerAngle {
                SectorHighlight(angle: angle, count: ring.slots.count, selected: ring.selection)
                // Rides the dotted track itself and slips behind the items, like a moon passing a planet.
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 2).padding(-2))
                    .shadow(color: Palette.accent.opacity(0.5), radius: 4)
                    .offset(offset(angle: angle, radius: OrbitRing.itemRadius))
            }

            ForEach(Array(ring.slots.enumerated()), id: \.offset) { index, action in
                RingItem(action: action, scale: OrbitRing.itemScale(ring.slots.count), selected: ring.selection == index,
                         progress: ring.selection == index ? ring.dwellProgress : 0)
                    .offset(ring.appeared ? offset(index: index) : .zero)
                    .scaleEffect(ring.appeared ? 1 : 0.4)
                    .opacity(ring.appeared ? 1 : 0)
                    .onTapGesture { ring.click(index) }
            }

            Hub(action: ring.selection.map { ring.slots[$0] })
                .onTapGesture { ring.click(nil) }
        }
        .frame(width: size, height: size)
        .scaleEffect(ring.appeared ? 1 : 0.86)
    }

    private func offset(index: Int) -> CGSize {
        offset(angle: Double(index) * 2 * .pi / Double(ring.slots.count), radius: OrbitRing.itemRadius)
    }

    /// Angle 0 = up, clockwise. SwiftUI y grows downward.
    private func offset(angle: Double, radius: CGFloat) -> CGSize {
        CGSize(width: sin(angle) * radius, height: -cos(angle) * radius)
    }
}

private struct SectorHighlight: View {
    let angle: Double
    let count: Int
    let selected: Int?

    var body: some View {
        let step = 2 * .pi / Double(count)
        let mid = selected.map { Double($0) * step } ?? angle
        Sector(start: mid - step / 2, end: mid + step / 2, inner: 40, outer: OrbitRing.size / 2 - 20)
            .fill(RadialGradient(colors: [Palette.ink.opacity(0.0), Palette.ink.opacity(0.07)],
                                 center: .center, startRadius: 40, endRadius: OrbitRing.size / 2 - 20))
            .animation(.spring(duration: 0.18, bounce: 0), value: selected)
    }
}

/// Radial lines on the boundaries between slots (slot 0 is centered at the top).
struct SlotDividers: Shape {
    let count: Int
    let inner: CGFloat
    let outer: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard count > 1 else { return p }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let step = 2 * Double.pi / Double(count)
        for i in 0..<count {
            let a = (Double(i) + 0.5) * step
            p.move(to: CGPoint(x: c.x + sin(a) * inner, y: c.y - cos(a) * inner))
            p.addLine(to: CGPoint(x: c.x + sin(a) * outer, y: c.y - cos(a) * outer))
        }
        return p
    }
}

private struct Sector: Shape {
    var start: Double, end: Double, inner: CGFloat, outer: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { .init(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // Convert "0 = up, clockwise" to SwiftUI's angle space.
        let a0 = Angle(radians: start - .pi / 2), a1 = Angle(radians: end - .pi / 2)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct RingItem: View {
    let action: OrbitAction
    var scale: CGFloat = 1
    let selected: Bool
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(selected ? Palette.accent : Palette.surface)
                .overlay(Circle().strokeBorder(selected ? .clear : Palette.hairline, lineWidth: 1))
                .frame(width: 52 * scale, height: 52 * scale)
                .shadow(color: selected ? Palette.accent.opacity(0.45) : .clear, radius: 12, y: 4)
            Image(systemName: action.symbol)
                .font(.system(size: 19 * scale, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Palette.ink)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 60 * scale, height: 60 * scale)
            }
        }
        .scaleEffect(selected ? 1.16 : 1)
        .animation(.spring(duration: 0.2, bounce: 0.3), value: selected)
        .contentShape(Circle())
        .help(action.title)
        .accessibilityLabel(action.title)
    }
}

private struct Hub: View {
    let action: OrbitAction?

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.surface)
                .frame(width: 92, height: 92)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            if let action {
                VStack(spacing: 2) {
                    Text(action.shortTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(action.groupTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(width: 80)
                .transition(.opacity)
                .id(action)
            } else {
                OrbitMark(size: 46, dot: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: action)
    }
}

/// Orbit's glyph — the app icon's mark: a planet, a tilted ring with knock-out gaps, and the satellite.
/// Monochrome by default (follows the foreground color); `dot` adds the orange satellite.
struct OrbitMark: View {
    var size: CGFloat = 18
    var color: Color = Palette.ink
    var dot = false

    // Geometry in a unit square, matching tools/RenderIcons.swift (1024-pt master).
    static let tilt = -0.38
    static let a = 376.0 / 1024, b = 116.0 / 1024, ring = 46.0 / 1024, gap = 26.0 / 1024
    static let planet = 490.0 / 1024, dotD = 92.0 / 1024, dotGap = 30.0 / 1024, dotT = 2.45

    var body: some View {
        Canvas { ctx, s in
            let u = s.width
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let t = CGAffineTransform(rotationAngle: Self.tilt).concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            let ellipse = Path(ellipseIn: CGRect(x: -Self.a * u, y: -Self.b * u, width: Self.a * 2 * u, height: Self.b * 2 * u)).applying(t)
            let front = ellipse.trimmedPath(from: 0.06, to: 0.44)
            let ringW = max(1.2, Self.ring * u)
            let gapW = max(0.8, Self.gap * u)
            let shade = GraphicsContext.Shading.color(color)

            ctx.drawLayer { layer in
                layer.stroke(ellipse, with: shade, lineWidth: ringW)
                var cut = layer
                cut.blendMode = .destinationOut
                let pr = Self.planet * u / 2
                cut.fill(Path(ellipseIn: CGRect(x: c.x - pr - gapW, y: c.y - pr - gapW, width: (pr + gapW) * 2, height: (pr + gapW) * 2)), with: .color(.black))
                layer.fill(Path(ellipseIn: CGRect(x: c.x - pr, y: c.y - pr, width: pr * 2, height: pr * 2)), with: shade)
                cut.stroke(front, with: .color(.black), lineWidth: ringW + gapW * 2)
                layer.stroke(ellipse.trimmedPath(from: 0, to: 0.5), with: shade, lineWidth: ringW)
                let p = Self.dotPoint(u: u, c: c)
                let dr = Self.dotD * u / 2, dg = Self.dotGap * u
                cut.fill(Path(ellipseIn: CGRect(x: p.x - dr - dg, y: p.y - dr - dg, width: (dr + dg) * 2, height: (dr + dg) * 2)), with: .color(.black))
                layer.fill(Path(ellipseIn: CGRect(x: p.x - dr, y: p.y - dr, width: dr * 2, height: dr * 2)),
                           with: dot ? .color(Palette.accent) : shade)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static func dotPoint(u: CGFloat, c: CGPoint) -> CGPoint {
        let x = a * u * cos(dotT), y = b * u * sin(dotT)
        return CGPoint(x: x * cos(tilt) - y * sin(tilt) + c.x, y: x * sin(tilt) + y * cos(tilt) + c.y)
    }
}
