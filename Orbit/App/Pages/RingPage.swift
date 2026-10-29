import SwiftUI
import KeyboardShortcuts

/// Ring designer: edit the slots directly on a live ring, try it out, pick a preset, set the trigger.
struct RingPage: View {
    @State private var slots = OrbitRing.loadSlots()
    @State private var selected: Int? = 0
    @State private var practice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            PageHeader(title: "Orbit Ring", subtitle: "Actions around your pointer. Click a slot, then pick what it does.") {
                HStack(spacing: 10) {
                    SlotCountStepper(count: slots.count, change: resize)
                    ModeSwitch(practice: $practice)
                }
            }

            HStack(alignment: .top, spacing: 28) {
                RingEditor(slots: $slots, selected: $selected, practice: practice, save: save)
                    .frame(width: 360, height: 360)
                Group {
                    if practice {
                        PracticeHelp()
                    } else {
                        ActionLibrary(slots: slots, selected: selected) { action in
                            guard let i = selected else { return }
                            withAnimation(.spring(duration: 0.35, bounce: 0.35)) { slots[i] = action }
                            save()
                            // Move on to the next slot so filling the ring is a quick tap-tap-tap.
                            withAnimation(.spring(duration: 0.3)) { selected = (i + 1) % slots.count }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 360)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .animation(.spring(duration: 0.35, bounce: 0.1), value: practice)

            PresetRow(slots: slots) { preset in
                withAnimation(.spring(duration: 0.5, bounce: 0.3)) { slots = preset }
                // Applying a preset is not an edit: "My ring" keeps the user's own layout.
                OrbitRing.saveSlots(slots)
            }

            TriggerCards()
            BehaviorCard()
        }
    }

    /// Every edit lands in "My ring" too, so trying a preset never loses it.
    private func save() {
        OrbitRing.saveSlots(slots)
        RingPresets.shared.saveCustom(slots)
    }

    /// Adds actions not on the ring yet (defaults first), or drops the last slots.
    private func resize(_ count: Int) {
        let count = min(max(count, OrbitRing.slotRange.lowerBound), OrbitRing.slotRange.upperBound)
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) {
            if count < slots.count {
                slots.removeLast(slots.count - count)
            } else {
                let spare = (OrbitRing.defaultSlots + OrbitAction.allCases).filter { !slots.contains($0) }
                slots += spare.prefix(count - slots.count)
            }
            if let s = selected, s >= slots.count { selected = slots.count - 1 }
        }
        save()
    }
}

/// − 8 + : how many slots the ring has.
private struct SlotCountStepper: View {
    let count: Int
    let change: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            step("minus", count - 1, enabled: count > OrbitRing.slotRange.lowerBound, help: "Fewer slots")
            VStack(spacing: 0) {
                Text("\(count)").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: Double(count)))
                Text("slots").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            }
            .frame(width: 34)
            step("plus", count + 1, enabled: count < OrbitRing.slotRange.upperBound, help: "More slots")
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(Palette.raised))
        .animation(.spring(duration: 0.3), value: count)
    }

    private func step(_ symbol: String, _ to: Int, enabled: Bool, help: String) -> some View {
        Button { change(to) } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundStyle(enabled ? Palette.ink : Palette.inkSecondary.opacity(0.4))
                .background(Circle().fill(Palette.surface.opacity(enabled ? 1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
        .help(help.loc)
    }
}

// MARK: - Mode switch

private struct ModeSwitch: View {
    @Binding var practice: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            segment("Customize", symbol: "slider.horizontal.3", on: !practice) { practice = false }
            segment("Try it", symbol: "hand.point.up.left", on: practice) { practice = true }
        }
        .padding(3)
        .background(Capsule().fill(Palette.raised))
    }

    private func segment(_ title: String, symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(duration: 0.3, bounce: 0.2), action) } label: {
            Label(title.loc, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Palette.canvas : Palette.inkSecondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    if on { Capsule().fill(Palette.ink).matchedGeometryEffect(id: "seg", in: ns) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ring editor


private struct RingEditor: View {
    @Binding var slots: [OrbitAction]
    @Binding var selected: Int?
    let practice: Bool
    let save: () -> Void

    @AppStorage("ring.hover") private var hoverActivates = true
    @AppStorage("ring.dwell") private var dwell = 0.45
    @State private var pointerAngle: Double?
    @State private var aimed: Int?
    @State private var progress: Double = 0
    @State private var fired: OrbitAction?
    @State private var firedIndex: Int?
    @State private var dropTarget: Int?
    @State private var dwellToken = UUID()
    @State private var appeared = false

    private let size: CGFloat = 360
    private var radius: CGFloat { size * 0.335 }
    private var step: Double { 2 * .pi / Double(slots.count) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.canvas)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            SlotDividers(count: slots.count, inner: 56, outer: size / 2 - 10)
                .stroke(RadialGradient(colors: [Palette.ink.opacity(0), Palette.ink.opacity(0.08), Palette.ink.opacity(0)],
                                       center: .center, startRadius: 56, endRadius: size / 2 - 10),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
            Circle()
                .stroke(Palette.ink.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: radius * 2, height: radius * 2)

            if practice, let pointerAngle {
                EditorSector(mid: aimed.map { Double($0) * step } ?? pointerAngle, step: step, inner: 52, outer: size / 2 - 8)
                    .fill(Palette.ink.opacity(0.06))
                    .animation(.spring(duration: 0.18, bounce: 0), value: aimed)
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 2).padding(-2))
                    .offset(offset(pointerAngle, radius + 32))
            }

            ForEach(Array(slots.enumerated()), id: \.offset) { i, action in
                slot(i, action)
                    .offset(appeared ? offset(Double(i) * step, radius) : .zero)
                    .scaleEffect(appeared ? 1 : 0.3)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(duration: 0.5, bounce: 0.3).delay(Double(i) * 0.025), value: appeared)
            }

            hub
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard practice else { return }
            switch phase {
            case .active(let p): track(p)
            case .ended: resetAim()
            }
        }
        .onChange(of: practice) { resetAim() }
        .onAppear { appeared = true }
    }

    // MARK: Slots

    private func slot(_ i: Int, _ action: OrbitAction) -> some View {
        let isSelected = !practice && selected == i
        let isAimed = practice && aimed == i
        let isTarget = dropTarget == i
        let lit = isSelected || isAimed
        let scale = OrbitRing.itemScale(slots.count)
        return ZStack {
            Circle()
                .fill(lit ? Palette.accent : Palette.surface)
                .overlay(Circle().strokeBorder(lit ? .clear : Palette.hairline, lineWidth: 1))
                .frame(width: 58 * scale, height: 58 * scale)
                .shadow(color: lit ? Palette.accent.opacity(0.4) : .clear, radius: 12, y: 4)
            Image(systemName: action.symbol)
                .font(.system(size: 20 * scale, weight: .semibold))
                .foregroundStyle(lit ? Color.white : Palette.ink)
                .contentTransition(.symbolEffect(.replace))
            if isAimed, progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 66, height: 66)
            }
            if isTarget {
                Circle()
                    .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: 70, height: 70)
            }
        }
        .scaleEffect(lit || isTarget ? 1.14 : 1)
        .animation(.spring(duration: 0.25, bounce: 0.35), value: lit)
        .animation(.spring(duration: 0.25, bounce: 0.35), value: isTarget)
        .contentShape(Circle())
        .onTapGesture {
            if practice { fire(i) } else { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { selected = i } }
        }
        .draggable("slot:\(i)") { DragChip(action: action) }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first else { return false }
            drop(item, on: i)
            return true
        } isTargeted: { on in
            if on { dropTarget = i } else if dropTarget == i { dropTarget = nil }
        }
        .help("\(OrbitRing.slotName(i, of: slots.count)): \(action.title)")
        .accessibilityLabel("%@ slot".loc(OrbitRing.slotName(i, of: slots.count)) + ", " + action.title)
    }

    private func drop(_ item: String, on i: Int) {
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) {
            if item.hasPrefix("slot:"), let from = Int(item.dropFirst(5)), from != i {
                slots.swapAt(from, i)
            } else if item.hasPrefix("action:"), let a = OrbitAction(rawValue: String(item.dropFirst(7))) {
                slots[i] = a
            }
            selected = i
        }
        save()
    }

    // MARK: Hub

    private var hub: some View {
        ZStack {
            Circle()
                .fill(Palette.surface)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .frame(width: 104, height: 104)
            Group {
                if practice {
                    if let fired {
                        VStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.accent)
                            Text(fired.shortTitle).font(.system(size: 12, weight: .semibold))
                            Text("would run").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                        }
                        .id("fired-\(fired.rawValue)")
                    } else if let aimed {
                        hubLabel(slots[aimed].shortTitle, slots[aimed].groupTitle).id("aim-\(aimed)")
                    } else {
                        VStack(spacing: 4) {
                            OrbitMark(size: 34, dot: true)
                            Text("Point at an action").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                        }
                        .id("idle")
                    }
                } else if let selected {
                    hubLabel(slots[selected].shortTitle, OrbitRing.slotName(selected, of: slots.count)).id("sel-\(selected)-\(slots[selected].rawValue)")
                } else {
                    OrbitMark(size: 40, dot: true).id("mark")
                }
            }
            .frame(width: 92)
            .multilineTextAlignment(.center)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .animation(.spring(duration: 0.25), value: fired)
        .animation(.easeOut(duration: 0.12), value: aimed)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func hubLabel(_ title: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Text(caption).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
        }
    }

    // MARK: Practice

    private func track(_ p: CGPoint) {
        let dx = p.x - size / 2, dy = p.y - size / 2
        guard hypot(dx, dy) > 52 else {
            pointerAngle = nil
            aim(nil)
            return
        }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        pointerAngle = angle
        aim(Int((angle + step / 2) / step) % slots.count)
    }

    private func aim(_ i: Int?) {
        guard i != aimed else { return }
        aimed = i
        if i != firedIndex { firedIndex = nil }
        progress = 0
        dwellToken = UUID()
        guard let i, hoverActivates, firedIndex == nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.linear(duration: dwell)) { progress = 1 }
        let token = dwellToken
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell) {
            if token == dwellToken, aimed == i { fire(i) }
        }
    }

    private func fire(_ i: Int) {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        firedIndex = i
        progress = 0
        fired = slots[i]
        let shown = slots[i]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if fired == shown { fired = nil }
        }
    }

    private func resetAim() {
        pointerAngle = nil
        aimed = nil
        firedIndex = nil
        progress = 0
        dwellToken = UUID()
    }

    /// Angle 0 = up, clockwise. SwiftUI y grows downward.
    private func offset(_ angle: Double, _ r: CGFloat) -> CGSize {
        CGSize(width: sin(angle) * r, height: -cos(angle) * r)
    }
}

private struct EditorSector: Shape {
    var mid: Double, step: Double, inner: CGFloat, outer: CGFloat

    var animatableData: Double {
        get { mid }
        set { mid = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let a0 = Angle(radians: mid - step / 2 - .pi / 2), a1 = Angle(radians: mid + step / 2 - .pi / 2)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct DragChip: View {
    let action: OrbitAction
    var body: some View {
        Label(action.title, systemImage: action.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.canvas)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Palette.ink))
    }
}

// MARK: - Action library

private struct ActionLibrary: View {
    let slots: [OrbitAction]
    let selected: Int?
    let assign: (OrbitAction) -> Void
    @State private var query = ""

    private let groups = ["Capture", "Clipboard", "Window", "Orbit", "System"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.map { "%@ slot".loc(OrbitRing.slotName($0, of: slots.count)) } ?? "Choose a slot".loc)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                        .contentTransition(.opacity)
                    Text("Click an action, or drag it onto the ring.")
                        .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            // The selected slot's action can also have its own shortcut: click and press the keys.
            if let i = selected, slots.indices.contains(i), let name = slots[i].shortcutName {
                HStack(spacing: 8) {
                    Image(systemName: slots[i].symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 16)
                    Text("Shortcut for “%@”".loc(slots[i].title)).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ShortcutRecorder(name: name, compact: true).id(name.rawValue)
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
                .transition(.opacity)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                TextField("Search actions", text: $query).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised))
            .padding(.horizontal, 12).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.self) { group in
                        let actions = filtered(group)
                        if !actions.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.loc.uppercased())
                                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(Palette.inkSecondary)
                                    .padding(.horizontal, 8).padding(.bottom, 3)
                                ForEach(actions) { a in
                                    LibraryRow(action: a,
                                               current: selected.map { slots[$0] == a } ?? false,
                                               used: slots.contains(a)) { assign(a) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func filtered(_ group: String) -> [OrbitAction] {
        OrbitAction.allCases.filter {
            $0.group == group && $0 != .settings &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query))
        }
    }
}

private struct LibraryRow: View {
    let action: OrbitAction
    let current: Bool
    let used: Bool
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(current ? Color.white : Palette.ink)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(current ? Palette.accent : Palette.raised))
                Text(action.title).font(.system(size: 12, weight: current ? .semibold : .regular)).foregroundStyle(Palette.ink)
                Spacer()
                if current {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accent)
                } else if used {
                    Text("On ring").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 8).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ink.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .draggable("action:\(action.rawValue)") { DragChip(action: action) }
    }
}

private struct PracticeHelp: View {
    @AppStorage("ring.hover") private var hoverActivates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Try it here").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink)
            step("1", "Move the pointer over the ring", "The orange satellite follows your direction.")
            step("2", hoverActivates ? "Rest on an action" : "Click an action",
                 hoverActivates ? "It fills up, then runs. Nothing actually runs on this page." : "Turn on “Rest to activate” below to choose without clicking.")
            step("3", "For real: hold the trigger, aim, let go", "Or flick past the edge — it runs the moment you cross.")
            Spacer()
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private func step(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n).font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.canvas)
                .frame(width: 24, height: 24).background(Circle().fill(Palette.ink))
            VStack(alignment: .leading, spacing: 3) {
                Text(title.loc).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(detail.loc).font(.system(size: 12)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Presets

/// The user's own ring ("My ring", kept up to date with every edit) and the presets they saved.
@MainActor @Observable
final class RingPresets {
    static let shared = RingPresets()

    struct Saved: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var slots: [OrbitAction]
    }

    private(set) var custom: [OrbitAction]
    private(set) var saved: [Saved]

    private init() {
        let raw = Pref.defaults.stringArray(forKey: "ring.custom")?.compactMap(OrbitAction.init(rawValue:)) ?? []
        // First run: whatever is on the ring now is the user's own.
        custom = OrbitRing.slotRange.contains(raw.count) ? raw : OrbitRing.loadSlots()
        saved = Pref.defaults.data(forKey: "ring.userPresets").flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        if raw.isEmpty { Pref.defaults.set(custom.map(\.rawValue), forKey: "ring.custom") }
    }

    func saveCustom(_ slots: [OrbitAction]) {
        custom = slots
        Pref.defaults.set(slots.map(\.rawValue), forKey: "ring.custom")
    }

    func add(_ name: String, slots: [OrbitAction]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.append(Saved(name: name.isEmpty ? "My preset".loc : name, slots: slots))
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[i].name = name
        persist()
    }

    func delete(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { Pref.defaults.set(data, forKey: "ring.userPresets") }
    }
}

private struct PresetRow: View {
    let slots: [OrbitAction]
    let apply: ([OrbitAction]) -> Void
    private var store: RingPresets { .shared }
    @State private var undo: [OrbitAction]?
    @State private var undoWork: DispatchWorkItem?
    @State private var naming = false
    @State private var newName = ""
    @State private var renaming: RingPresets.Saved?
    @State private var renameText = ""

    static let presets: [(String, String, [OrbitAction])] = [
        ("Balanced", "A bit of everything", OrbitRing.defaultSlots),
        ("Screenshots", "Every capture mode", [.captureArea, .captureText, .captureWindow, .captureScreen,
                                               .captureRepeat, .pinLastCapture, .clipboard, .launcher]),
        ("Windows", "Aim where the window goes", [.winTop, .winTopRight, .winRight, .winBottomRight,
                                                  .winBottom, .winBottomLeft, .winLeft, .winTopLeft]),
        ("Everyday", "Clipboard first", [.clipboard, .captureArea, .winRight, .launcher,
                                         .winMaximize, .keepAwake, .winLeft, .captureText]),
    ]

    private let columns = [GridItem(.adaptive(minimum: 124, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("PRESETS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.inkSecondary)
                if undo != nil {
                    HStack(spacing: 8) {
                        Text("Preset applied").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.inkSecondary)
                        Button("Undo") { revert() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                    }
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(Palette.raised))
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                Spacer()
            }
            .padding(.leading, 4)
            .animation(.spring(duration: 0.3), value: undo)

            LazyVGrid(columns: columns, spacing: 12) {
                PresetCard(name: "My ring", detail: "Your own layout, saved as you edit", preset: store.custom,
                           active: store.custom == slots, mine: true) { choose(store.custom) }
                ForEach(Self.presets, id: \.0) { name, detail, preset in
                    PresetCard(name: name, detail: detail, preset: preset, active: preset == slots) { choose(preset) }
                }
                ForEach(store.saved) { item in
                    PresetCard(name: item.name, detail: "Saved preset", preset: item.slots, active: item.slots == slots, localized: false) { choose(item.slots) }
                        .contextMenu {
                            Button("Rename…") { renameText = item.name; renaming = item }
                            Button("Update to Current Ring") { store.delete(item.id); store.add(item.name, slots: slots) }
                            Divider()
                            Button("Delete", role: .destructive) { withAnimation(Motion.reflow) { store.delete(item.id) } }
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                SaveCard { newName = ""; naming = true }
                    .popover(isPresented: $naming, arrowEdge: .bottom) { namePopover }
            }
            .animation(Motion.reflow, value: store.saved)
        }
        .alert("Rename preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let r = renaming { store.rename(r.id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var namePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save the current ring as a preset").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
            TextField("Preset name".loc, text: $newName)
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit(commitNew)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }.buttonStyle(PillButtonStyle(prominent: false))
                Button("Save") { commitNew() }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(14)
    }

    private func commitNew() {
        withAnimation(Motion.reflow) { store.add(newName, slots: slots) }
        naming = false
    }

    private func choose(_ preset: [OrbitAction]) {
        guard preset != slots else { return }
        let before = slots
        apply(preset)
        undo = before
        undoWork?.cancel()
        let work = DispatchWorkItem { withAnimation(.spring(duration: 0.3)) { undo = nil } }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func revert() {
        guard let before = undo else { return }
        undoWork?.cancel()
        apply(before)
        undo = nil
    }
}

private struct PresetCard: View {
    let name: String
    let detail: String
    let preset: [OrbitAction]
    let active: Bool
    var mine = false
    var localized = true
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 10) {
                MiniRing(slots: preset, size: 92)
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        if mine { Image(systemName: "person.crop.circle").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent) }
                        Text(localized ? name.loc : name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                    Text(detail.loc).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(active ? Palette.accent : (hovering ? Palette.ink.opacity(0.2) : Palette.hairline), lineWidth: active ? 2 : 1))
            .offset(y: hovering ? -2 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { h in withAnimation(.spring(duration: 0.25, bounce: 0.3)) { hovering = h } }
    }
}

/// "+ Save as preset" — the last card in the row.
private struct SaveCard: View {
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(hovering ? Palette.ink : Palette.inkSecondary)
                    .frame(width: 92, height: 92)
                    .background(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])).foregroundStyle(Palette.hairline))
                VStack(spacing: 1) {
                    Text("Save as preset").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Keep the ring as it is now").font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                        .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .top)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface.opacity(hovering ? 1 : 0.6)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
    }
}

/// Small static Ring used for presets and the home page.
struct MiniRing: View {
    let slots: [OrbitAction]
    var size: CGFloat = 92
    var highlight: Int? = nil

    var body: some View {
        ZStack {
            Circle().fill(Palette.canvas).overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            SlotDividers(count: slots.count, inner: size * 0.16, outer: size * 0.47)
                .stroke(Palette.ink.opacity(0.06), lineWidth: 0.75)
            ForEach(Array(slots.enumerated()), id: \.offset) { i, a in
                let angle = Double(i) * 2 * .pi / Double(slots.count)
                Image(systemName: a.symbol)
                    .font(.system(size: size * 0.09, weight: .semibold))
                    .foregroundStyle(highlight == i ? Color.white : Palette.ink)
                    .frame(width: size * 0.2 * OrbitRing.itemScale(slots.count), height: size * 0.2 * OrbitRing.itemScale(slots.count))
                    .background(Circle().fill(highlight == i ? Palette.accent : Palette.surface))
                    .offset(x: sin(angle) * size * 0.34, y: -cos(angle) * size * 0.34)
            }
            OrbitMark(size: size * 0.2, dot: true)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Trigger & behavior

private struct TriggerCards: View {
    @AppStorage("ring.mouse") private var mouse = true
    @AppStorage("ring.mouseButton") private var button = 2
    private var permissions: Permissions { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OPEN THE RING").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.inkSecondary).padding(.leading, 4)
            HStack(alignment: .top, spacing: 12) {
                card(symbol: "keyboard", title: "Keyboard", detail: "Hold, aim, release. Or tap, then choose.") {
                    ShortcutRecorder(name: .ring)
                }
                card(symbol: "computermouse", title: "Open with a mouse button",
                     detail: permissions.accessibility ? "Hold the button you pick to open the ring. A quick click still does what it always did." : "Needs Accessibility permission.",
                     trailing: { Toggle("", isOn: $mouse.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden().onChange(of: mouse) { MouseTrigger.shared.start() } }) {
                    HStack(spacing: 12) {
                        MouseGlyph(button: mouse ? button : nil)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                ForEach([(2, "Middle button"), (3, "Back button"), (4, "Forward button")], id: \.0) { tag, name in
                                    Button {
                                        withAnimation(.spring(duration: 0.25)) { button = tag }
                                        MouseTrigger.shared.start()
                                    } label: {
                                        Text(name.loc).font(.system(size: 12, weight: .semibold))
                                            .fixedSize()
                                            .foregroundStyle(button == tag ? Palette.canvas : Palette.ink)
                                            .padding(.horizontal, 12).frame(height: 28)
                                            .background(Capsule().fill(button == tag ? Palette.ink : Palette.raised))
                                    }
                                    .buttonStyle(.plain)
                                    .focusEffectDisabled()
                                    .hoverHint((tag == 2 ? "The wheel — press it down" : (tag == 3 ? "Side button nearer your wrist" : "Side button further forward")).loc)
                                }
                            }
                            .disabled(!mouse)
                            .opacity(mouse ? 1 : 0.4)
                            Text((mouse ? "Back and forward are the two buttons on the side of most mice." : "Turn it on to pick a button.").loc)
                                .font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func card<Body: View>(symbol: String, title: String, detail: String,
                                  @ViewBuilder trailing: () -> some View = { EmptyView() },
                                  @ViewBuilder content: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.canvas)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.ink))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.loc).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text(detail.loc).font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                trailing()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// A little mouse with the chosen button lit: the wheel for middle, the side buttons for back/forward.
private struct MouseGlyph: View {
    let button: Int?

    var body: some View {
        ZStack {
            // Body
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.55), lineWidth: 1.5)
                .frame(width: 30, height: 44)
            // Split between left and right buttons
            Rectangle().fill(Palette.ink.opacity(0.35)).frame(width: 1, height: 13).offset(y: -12)
            // Wheel
            Capsule().fill(button == 2 ? Palette.accent : Palette.ink.opacity(0.35))
                .frame(width: 5, height: 10).offset(y: -11)
            // Side buttons on the left edge: forward above, back below.
            Capsule().fill(button == 4 ? Palette.accent : Palette.ink.opacity(0.3))
                .frame(width: 4, height: 8).offset(x: -17, y: -4)
            Capsule().fill(button == 3 ? Palette.accent : Palette.ink.opacity(0.3))
                .frame(width: 4, height: 8).offset(x: -17, y: 6)
        }
        .frame(width: 40, height: 48)
        .animation(.spring(duration: 0.25), value: button)
        .accessibilityHidden(true)
    }
}

private struct BehaviorCard: View {
    @AppStorage("ring.hover") private var hover = true
    @AppStorage("ring.dwell") private var dwell = 0.45

    var body: some View {
        SettingsGroup(title: "Choosing", footer: "Shorter feels snappier; longer prevents accidental picks.") {
            SettingsRow(title: "Rest to activate", subtitle: "Resting on an action fills it, then runs it.", symbol: "hand.point.up.left") {
                Toggle("", isOn: $hover.animation(.spring(duration: 0.3))).toggleStyle(.switch).labelsHidden()
            }
            if hover {
                RowDivider()
                SettingsRow(title: "Rest time", symbol: "timer") {
                    DwellPreview(seconds: dwell)
                    Slider(value: $dwell, in: 0.25...1.0, step: 0.05).frame(width: 150)
                    Text("\(dwell, specifier: "%.2f")s").font(.orbitCaption.monospacedDigit()).foregroundStyle(Palette.inkSecondary).frame(width: 40)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Loops the dwell fill at the chosen speed so the number has a feel.
private struct DwellPreview: View {
    let seconds: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let cycle = seconds + 0.5
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            let p = min(1, t / seconds)
            ZStack {
                Circle().fill(p >= 1 ? Palette.accent : Palette.raised)
                Circle().trim(from: 0, to: p)
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(-3)
            }
            .frame(width: 18, height: 18)
        }
        .padding(.trailing, 6)
    }
}
