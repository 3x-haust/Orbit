import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

/// Drag files and press Shift: a ring opens under the pointer with what they can become (Convert);
/// press Shift again for Tools. Drop on a slot to run it. Every result is a new file beside the original.
@MainActor @Observable
final class FileTools {
    static let shared = FileTools()
    static let enabledKey = "files.shiftDrag"
    static var enabled: Bool { Pref.defaults.object(forKey: enabledKey) as? Bool ?? true }

    // Geometry, in points. The ring sits in the bottom square of the panel; the mode tabs above it.
    static let ringSize: CGFloat = 320
    static let tabsHeight: CGFloat = 40
    static let panelSize = CGSize(width: ringSize, height: ringSize + tabsHeight)
    static let hubRadius: CGFloat = 44
    static let innerRadius: CGFloat = 52
    static let outerRadius: CGFloat = 146

    enum Slot: Equatable { case hub, outer(Int) }

    private(set) var files: [URL] = []
    private(set) var mode: FileRingMode = .convert
    private(set) var menu = FileMenu()
    private(set) var selection: Slot?
    private(set) var isDraggingRing = false
    private(set) var appeared = false
    private(set) var jobs: [FileJob] = []
    /// Faces that have something to offer for the current files (worked out once per ring).
    private(set) var available: Set<FileRingMode> = []

    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var dragCount: Int?
    @ObservationIgnored private var dismissedDragCount: Int?
    @ObservationIgnored private var shiftWasDown = false
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var releasedAt: Date?
    @ObservationIgnored private var cachedFiles: (changeCount: Int, files: [URL])?
    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize))
        panel.level = .popUpMenu
        panel.hasShadow = false
        let drop = FileDropView(tools: self)
        let host = FirstMouseHostingView(rootView: FileRingView(tools: self).orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        panel.contentView = drop
        panel.onEscape = { [weak self] in self?.closeRing(); return true }
        panel.onResignKey = { [weak self] in
            guard let self, !self.isDraggingRing else { return }
            self.closeRing()
        }
        return panel
    }()
    @ObservationIgnored private lazy var hud: FloatingPanel = {
        let panel = FloatingPanel(contentRect: .zero, focusable: false)
        panel.level = .statusBar
        panel.hasShadow = false
        panel.setContent(FileJobsView(tools: self))
        return panel
    }()

    // MARK: Watching drags

    func start() {
        stop()
        guard Self.enabled else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .flagsChanged, .keyDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(monitor) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        dragCount = nil
        closeRing()
    }

    private func handle(_ event: NSEvent) {
        let pasteboard = NSPasteboard(name: .drag)
        switch event.type {
        case .leftMouseDown:
            guard event.window !== panel else { return }
            dragCount = pasteboard.changeCount
            dismissedDragCount = nil
        case .leftMouseUp:
            // Not closed here: the drop reaches the ring a moment after the button comes up (see show).
            dragCount = nil
        case .keyDown:
            if event.keyCode == 53, panel.isVisible { closeRing() }
        case .flagsChanged:
            let shift = event.modifierFlags.contains(.shift)
            defer { shiftWasDown = shift }
            guard shift, !shiftWasDown else { return }
            // Only a press during the drag counts. Shift held from before (a Shift-click selection, or
            // apps that want Shift held while dropping) never opens the ring. Each new press flips faces.
            if isDraggingRing, panel.isVisible { toggleMode(); return }
            openFromDrag(pasteboard)
        default:
            break
        }
    }

    private func openFromDrag(_ pasteboard: NSPasteboard) {
        guard !panel.isVisible, NSEvent.pressedMouseButtons & 1 != 0, let dragCount,
              pasteboard.changeCount != dragCount, dismissedDragCount != pasteboard.changeCount else { return }
        let files = files(in: pasteboard)
        guard !files.isEmpty else { return }
        show(files, dragging: true)
    }

    /// The drop view asks on every dragging update; the answer only changes with a new drag.
    func files(in pasteboard: NSPasteboard) -> [URL] {
        if let cached = cachedFiles, cached.changeCount == pasteboard.changeCount, pasteboard.name == .drag { return cached.files }
        let files = Self.files(from: pasteboard)
        if pasteboard.name == .drag { cachedFiles = (pasteboard.changeCount, files) }
        return files
    }

    static func files(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let usable = FileRingMode.allCases.contains { !FileMenu.menu(for: urls, mode: $0).isEmpty }
        return usable ? urls : []
    }

    // MARK: The ring

    /// Opens the ring for files picked or dropped in Orbit itself (no drag in progress): click a slot.
    func choose() {
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.message = "Choose files to convert or edit".loc
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            self?.offer(picker.urls)
        }
    }

    func offer(_ urls: [URL]) {
        guard FileRingMode.allCases.contains(where: { !FileMenu.menu(for: urls, mode: $0).isEmpty }) else {
            Toast.show("Orbit can’t convert these files", symbol: "questionmark.circle",
                       detail: "Pick pictures, PDFs, documents, videos or audio of one kind.")
            return
        }
        show(urls, dragging: false)
    }

    func show(_ urls: [URL], dragging: Bool) {
        files = urls
        let menus = Dictionary(uniqueKeysWithValues: FileRingMode.allCases.map { ($0, FileMenu.menu(for: urls, mode: $0)) })
        available = Set(menus.filter { !$0.value.isEmpty }.keys)
        mode = available.contains(.convert) ? .convert : .tools
        menu = menus[mode] ?? FileMenu()
        selection = nil
        isDraggingRing = dragging
        appeared = false
        if dragging {
            Shelf.shared.suspendForFileTools()
            NotchCenter.shared.suspendForFileTools()
        }
        // Centered on the pointer, so the pointer starts on the hub and every slot is one short move away.
        let screen = NSScreen.active
        let frame = screen.visibleFrame
        let mouse = dragging ? NSEvent.mouseLocation : CGPoint(x: frame.midX, y: frame.midY)
        let half = Self.ringSize / 2
        let center = CGPoint(x: min(max(mouse.x, frame.minX + half), frame.maxX - half),
                             y: min(max(mouse.y, frame.minY + half), frame.maxY - half - Self.tabsHeight))
        panel.setFrame(CGRect(x: center.x - half, y: center.y - half, width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        if dragging { panel.orderFrontRegardless() } else { panel.bringToFront() }
        withAnimation(Motion.adaptive(.spring(duration: 0.26, bounce: 0.18))) { appeared = true }
        if dragging {
            // A drag that ends anywhere else (or is cancelled) closes the ring. Not at once: a drop on
            // the ring arrives a little after the button comes up, and must still find it open.
            releasedAt = nil
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard NSEvent.pressedMouseButtons & 1 == 0 else { self.releasedAt = nil; return }
                    let released = self.releasedAt ?? Date()
                    self.releasedAt = released
                    if Date().timeIntervalSince(released) > 0.6 { self.closeRing() }
                }
            }
            endTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func setMode(_ next: FileRingMode) {
        guard next != mode, available.contains(next) else { return }
        let nextMenu = FileMenu.menu(for: files, mode: next)
        withAnimation(.spring(duration: 0.22, bounce: 0.1)) {
            mode = next
            menu = nextMenu
            selection = nil
        }
    }

    func toggleMode() { setMode(mode == .convert ? .tools : .convert) }

    func closeRing() {
        if isDraggingRing { dismissedDragCount = NSPasteboard(name: .drag).changeCount }
        panel.orderOut(nil)
        selection = nil
        isDraggingRing = false
        appeared = false
        releasedAt = nil
        endTimer?.invalidate()
        endTimer = nil
    }

    /// `point` is in the panel's own coordinates (AppKit: origin at the bottom left).
    static func slot(at point: CGPoint, menu: FileMenu) -> Slot? {
        let dx = point.x - ringSize / 2, dy = point.y - ringSize / 2
        let radius = hypot(dx, dy)
        if radius <= hubRadius { return menu.hub == nil ? nil : .hub }
        let count = menu.outer.count
        guard count > 0, radius >= innerRadius, radius <= outerRadius + 10 else { return nil }
        var angle = atan2(dx, dy) // 0 = up, clockwise
        if angle < 0 { angle += 2 * .pi }
        let step = 2 * .pi / Double(count)
        return .outer(Int((angle + step / 2) / step) % count)
    }

    /// Hovering a mode tab during a drag switches to it, so a mouse alone can reach both faces.
    static func tab(at point: CGPoint) -> FileRingMode? {
        guard point.y > ringSize, point.y <= panelSize.height else { return nil }
        return point.x < ringSize / 2 ? .convert : .tools
    }

    func target(_ point: CGPoint?) {
        guard let point else { selection = nil; return }
        if let tab = Self.tab(at: point) { setMode(tab); selection = nil; return }
        let next = Self.slot(at: point, menu: menu)
        if next != selection { withAnimation(.spring(duration: 0.16, bounce: 0.2)) { selection = next } }
    }

    func action(for slot: Slot) -> FileAction? {
        switch slot {
        case .hub: menu.hub
        case .outer(let i): menu.outer.indices.contains(i) ? menu.outer[i] : nil
        }
    }

    // MARK: Running

    func perform(_ action: FileAction, on files: [URL]) {
        closeRing()
        guard let first = files.first else { return }
        do {
            switch action {
            case .crop: ImageStudio.open(first, mode: .crop)
            case .background: ImageStudio.open(first, mode: .background)
            case .redact: ImageStudio.open(first, mode: .redact)
            case .annotate: try EditorWindow.openFile(first)
            default: run(action, on: files)
            }
        } catch {
            Toast.show("Couldn’t open the image", symbol: "exclamationmark.triangle", detail: error.localizedDescription)
        }
    }

    private func run(_ action: FileAction, on files: [URL]) {
        let job = FileJob(action: action, files: files)
        jobs.append(job)
        layoutHUD()
        job.task = Task {
            // Callbacks go through the main queue in order, so the last file lands before "done".
            let progress: FileEngine.Progress = { value in DispatchQueue.main.async { job.progress = value } }
            let saved: FileEngine.Saved = { url in DispatchQueue.main.async { job.outputs.append(url) } }
            let state: FileJob.State
            var note: String?
            do {
                note = try await FileEngine.run(action, files: files, progress: progress, saved: saved)?.text
                state = .done
            } catch is CancellationError {
                state = .cancelled
            } catch {
                state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            DispatchQueue.main.async { [weak self] in
                job.note = note
                job.state = state
                self?.finished(job)
            }
        }
    }

    private func finished(_ job: FileJob) {
        if job.state == .done, job.outputs.count == 1, job.note == nil {
            NSWorkspace.shared.noteFileSystemChanged(job.outputs[0].path)
        }
        // Successes clear themselves; failures wait to be read.
        guard job.state == .done || job.state == .cancelled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (job.state == .done ? 6 : 2)) { [weak self] in self?.dismiss(job) }
    }

    func cancel(_ job: FileJob) {
        if job.state == .running { job.task?.cancel() } else { dismiss(job) }
    }

    func dismiss(_ job: FileJob) {
        jobs.removeAll { $0 === job }
        layoutHUD()
    }

    /// A single saved file from a window (crop, background, redact, annotate).
    func announce(_ outputs: [URL]) {
        guard let first = outputs.first else { return }
        Toast.show("Saved", symbol: "checkmark.circle.fill", detail: first.lastPathComponent, actionTitle: "Show") {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    private func layoutHUD() {
        // orderOut, not the fading dismiss: a job started mid-fade would otherwise stay hidden.
        guard !jobs.isEmpty else { hud.orderOut(nil); return }
        let shown = min(jobs.count, FileJobsView.limit)
        let size = CGSize(width: FileJobsView.width, height: CGFloat(shown) * (FileJobsView.cardHeight + 8) + 8)
        let screen = NSScreen.active.visibleFrame
        let frame = CGRect(x: screen.midX - size.width / 2, y: screen.minY + 72, width: size.width, height: size.height)
        if hud.isVisible { hud.setFrame(frame, display: true) } else { hud.present(at: frame) }
    }
}

/// One run of a conversion or tool, shown on a card at the bottom of the screen.
@MainActor @Observable
final class FileJob: Identifiable {
    enum State: Equatable { case running, done, cancelled, failed(String) }

    let id = UUID()
    let action: FileAction
    let files: [URL]
    var progress: Double = 0
    var outputs: [URL] = []
    var state: State = .running
    var note: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(action: FileAction, files: [URL]) {
        self.action = action
        self.files = files
    }
}

/// Registers for file drags and accepts only a copy, so Finder never moves or deletes the original.
final class FileDropView: NSView {
    private let tools: FileTools

    init(tools: FileTools) {
        self.tools = tools
        super.init(frame: CGRect(origin: .zero, size: FileTools.panelSize))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private func accepted(_ sender: NSDraggingInfo) -> Bool {
        guard tools.isDraggingRing, sender.draggingSourceOperationMask.contains(.copy),
              tools.files(in: sender.draggingPasteboard) == tools.files else {
            tools.target(nil)
            return false
        }
        tools.target(convert(sender.draggingLocation, from: nil))
        return tools.selection != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { accepted(sender) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { accepted(sender) ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { tools.target(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepted(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepted(sender), let slot = tools.selection, let action = tools.action(for: slot) else { return false }
        let files = tools.files
        DispatchQueue.main.async { [tools] in tools.perform(action, on: files) }
        return true
    }
}

// MARK: - Ring

private struct FileRingView: View {
    let tools: FileTools

    var body: some View {
        VStack(spacing: 0) {
            ModeTabs(tools: tools)
                .frame(height: FileTools.tabsHeight, alignment: .top)
            ZStack {
                Circle()
                    .fill(Palette.canvas.opacity(0.96))
                    .background(VisualEffect(material: .popover).clipShape(Circle()))
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                    .frame(width: FileTools.outerRadius * 2 + 12, height: FileTools.outerRadius * 2 + 12)
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 10)

                let count = tools.menu.outer.count
                ForEach(Array(tools.menu.outer.enumerated()), id: \.offset) { index, action in
                    let step = 2 * Double.pi / Double(count)
                    let mid = Double(index) * step
                    let on = tools.selection == .outer(index)
                    let sector = FileSector(start: mid - step / 2, end: mid + step / 2,
                                            inner: FileTools.innerRadius, outer: FileTools.outerRadius)
                    sector
                        .fill(on ? Palette.accent : Palette.surface)
                        .shadow(color: on ? Palette.accent.opacity(0.4) : .clear, radius: 10)
                        .contentShape(sector)
                        .onTapGesture { tools.perform(action, on: tools.files) }
                        .onHover { inside in if inside, !tools.isDraggingRing { tools.hover(.outer(index)) } }
                    SlotLabel(action: action, selected: on)
                        .offset(x: sin(mid) * 99, y: -cos(mid) * 99)
                        .allowsHitTesting(false)
                }

                // Even gaps between slots: the disc shows through spokes of one width.
                SlotDividers(count: count, inner: FileTools.innerRadius - 1, outer: FileTools.outerRadius + 1)
                    .stroke(Palette.canvas, style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                    .allowsHitTesting(false)
                Circle()
                    .strokeBorder(Palette.hairline, lineWidth: 1)
                    .frame(width: FileTools.outerRadius * 2, height: FileTools.outerRadius * 2)
                    .allowsHitTesting(false)

                Hub(tools: tools)
            }
            .frame(width: FileTools.ringSize, height: FileTools.ringSize)
        }
        .frame(width: FileTools.panelSize.width, height: FileTools.panelSize.height)
        .scaleEffect(tools.appeared ? 1 : 0.86)
        .opacity(tools.appeared ? 1 : 0)
    }
}

extension FileTools {
    /// Clicking mode (no drag): hovering highlights like dragging does.
    func hover(_ slot: Slot?) { selection = slot }
}

private struct ModeTabs: View {
    let tools: FileTools

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FileRingMode.allCases, id: \.self) { mode in
                let on = tools.mode == mode
                let empty = !tools.available.contains(mode)
                Button { tools.setMode(mode) } label: {
                    HStack(spacing: 4) {
                        Text(mode.title.loc)
                        if !on, !empty, tools.isDraggingRing { Text("⇧").opacity(0.7) }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Palette.canvas : Palette.inkSecondary)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background { if on { Capsule().fill(Palette.ink) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .opacity(empty ? 0.35 : 1)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.canvas.opacity(0.96)).background(VisualEffect(material: .popover).clipShape(Capsule())))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

private struct SlotLabel: View {
    let action: FileAction
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let symbol = action.symbol {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(action.title.loc.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5)
            } else {
                Text(action.title).font(.system(size: 15, weight: .bold)).tracking(0.3)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: 76)
        .foregroundStyle(selected ? Color.white : Palette.ink)
        .scaleEffect(selected ? 1.08 : 1)
    }
}

private struct Hub: View {
    let tools: FileTools

    var body: some View {
        let on = tools.selection == .hub
        ZStack {
            Circle()
                .fill(on ? Palette.accent : (tools.menu.hub == nil ? Palette.canvas : Palette.raised))
                .overlay(Circle().strokeBorder(on ? Color.clear : Palette.hairline, lineWidth: 1))
                .frame(width: FileTools.hubRadius * 2, height: FileTools.hubRadius * 2)
            if let hub = tools.menu.hub {
                SlotLabel(action: hub, selected: on)
            } else {
                VStack(spacing: 2) {
                    Text("%ld files".loc(tools.files.count)).font(.system(size: 11, weight: .semibold))
                    Text(tools.mode.title.loc).font(.system(size: 10)).foregroundStyle(Palette.inkSecondary)
                }
                .foregroundStyle(Palette.ink)
                .opacity(tools.files.count > 1 ? 1 : 0)
            }
        }
        .contentShape(Circle())
        .onTapGesture { if let hub = tools.menu.hub { tools.perform(hub, on: tools.files) } }
        .onHover { inside in if !tools.isDraggingRing { tools.hover(inside && tools.menu.hub != nil ? .hub : nil) } }
    }
}

private struct FileSector: Shape {
    var start: Double, end: Double, inner: CGFloat, outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        // "0 = up, clockwise" in SwiftUI's angle space.
        let a0 = Angle(radians: start - .pi / 2), a1 = Angle(radians: end - .pi / 2)
        var p = Path()
        if end - start >= 2 * .pi - 0.001 {
            p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
            return p.normalized(eoFill: true)
        }
        p.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Progress cards

private struct FileJobsView: View {
    static let width: CGFloat = 360
    static let cardHeight: CGFloat = 76
    static let limit = 4
    let tools: FileTools

    var body: some View {
        VStack(spacing: 8) {
            ForEach(tools.jobs.suffix(Self.limit)) { job in
                FileJobCard(job: job, tools: tools).frame(height: Self.cardHeight)
            }
        }
        .padding(4)
        .frame(width: Self.width, alignment: .bottom)
    }
}

private struct FileJobCard: View {
    let job: FileJob
    let tools: FileTools

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { tools.cancel(job) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Palette.raised))
            }
            .buttonStyle(.plain)
            .help(job.state == .running ? "Cancel".loc : "Close".loc)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    switch job.state {
                    case .running: EmptyView()
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    case .cancelled: Image(systemName: "minus.circle.fill").foregroundStyle(Palette.inkSecondary)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Text(job.state == .done ? job.action.doneTitle : job.action.progressTitle)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
                    Spacer()
                    if !job.outputs.isEmpty, job.state != .running {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) }
                            .buttonStyle(PillButtonStyle(prominent: false))
                            .controlSize(.small)
                    }
                }
                Text(status).font(.orbitCaption).foregroundStyle(isFailure ? Color.red : Palette.inkSecondary)
                    .lineLimit(2)
                if job.state == .running {
                    ProgressView(value: max(0.02, job.progress)).progressViewStyle(.linear).tint(Palette.accent)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.canvas.opacity(0.97))
            .background(VisualEffect(material: .popover).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    private var isFailure: Bool { if case .failed = job.state { true } else { false } }

    private var status: String {
        let saved = job.outputs.count == 1 ? job.outputs[0].lastPathComponent : "%ld files saved".loc(job.outputs.count)
        switch job.state {
        case .running:
            return job.outputs.isEmpty ? "Working…".loc : saved
        case .done:
            if job.outputs.isEmpty { return job.note ?? "Nothing to save.".loc }
            return [saved, job.note].compactMap { $0 }.joined(separator: " · ")
        case .cancelled:
            return job.outputs.isEmpty ? "Cancelled".loc : "Cancelled — %@".loc(saved)
        case .failed(let reason):
            return job.outputs.isEmpty ? reason : "%@ — %@".loc(reason, saved)
        }
    }
}
