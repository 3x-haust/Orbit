import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

@MainActor @Observable
final class FileTools {
    static let shared = FileTools()
    static let enabledKey = "files.shiftDrag"
    static let size: CGFloat = 320
    static var enabled: Bool { Pref.defaults.object(forKey: enabledKey) as? Bool ?? true }

    enum Action: String, CaseIterable {
        case jpg, crop, background
        var title: String {
            switch self { case .jpg: "JPG"; case .crop: "Crop"; case .background: "Background" }
        }
        var symbol: String {
            switch self { case .jpg: "photo"; case .crop: "crop"; case .background: "photo.on.rectangle" }
        }
    }

    private(set) var source: URL?
    private(set) var actions: [Action] = []
    private(set) var selection: Int?
    private(set) var isDraggingRing = false
    private(set) var busy = false
    private(set) var result = FileConversion.Result()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var dragCount: Int?
    @ObservationIgnored private var dismissedDragCount: Int?
    @ObservationIgnored private var endTimer: Timer?
    @ObservationIgnored private var conversion: Task<FileConversion.Result, Never>?
    @ObservationIgnored private var resultWindow: NSWindow?
    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let panel = FloatingPanel(contentRect: .zero)
        panel.level = .popUpMenu
        panel.hasShadow = false
        let drop = FileDropView(tools: self)
        let host = NSHostingView(rootView: FileRingView(tools: self).orbitTint())
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        panel.contentView = drop
        panel.onEscape = { [weak self] in self?.closeRing(); return true }
        return panel
    }()

    static func actions(for url: URL) -> [Action] {
        switch FileConversion.kind(of: url) {
        case .pdf: [.jpg]
        case .image: [.crop, .background]
        case nil: []
        }
    }

    static func file(from pasteboard: NSPasteboard) -> URL? {
        guard let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              files.count == 1, !actions(for: files[0]).isEmpty else { return nil }
        return files[0]
    }

    /// AppKit coordinates: top is slot zero; the hub and outside the disc never accept a drop.
    static func index(at point: CGPoint, count: Int) -> Int? {
        let dx = point.x - size / 2, dy = point.y - size / 2
        let radius = hypot(dx, dy)
        guard count > 0, radius >= 48, radius <= 144 else { return nil }
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + .pi / Double(count)) / (2 * .pi / Double(count))) % count
    }

    func start() {
        stop()
        guard Self.enabled else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown]
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
        if event.type == .leftMouseDown {
            if event.window === panel { return }
            dragCount = pasteboard.changeCount
            dismissedDragCount = nil
            if panel.isVisible { closeRing() }
            return
        }
        if event.type == .keyDown, event.keyCode == 53 { closeRing(); return }
        if event.type == .leftMouseUp, isDraggingRing {
            // The destination receives performDragOperation before we retire its window.
            DispatchQueue.main.async { [weak self] in self?.closeRing() }
            dragCount = nil
            return
        }
        guard event.type == .leftMouseDragged || event.type == .flagsChanged,
              !panel.isVisible, !busy, NSEvent.pressedMouseButtons & 1 != 0,
              event.modifierFlags.contains(.shift), let dragCount,
              pasteboard.changeCount != dragCount, dismissedDragCount != pasteboard.changeCount,
              let file = Self.file(from: pasteboard) else { return }
        show(file, dragging: true)
    }

    func chooseFile() {
        guard !busy else { showResults(); return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.pdf, .image]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.begin { [weak self] response in
            guard response == .OK, let url = picker.url else { return }
            self?.show(url, dragging: false)
        }
    }

    func show(_ url: URL, dragging: Bool) {
        guard !busy else { return }
        let offered = Self.actions(for: url)
        guard !offered.isEmpty else { return }
        source = url
        actions = offered
        selection = nil
        isDraggingRing = dragging
        if dragging {
            Shelf.shared.suspendForFileTools()
            NotchCenter.shared.suspendForFileTools()
        }
        let anchorWindow = dragging ? nil : NSApp.keyWindow
        let frame = (anchorWindow?.screen ?? NSScreen.active).visibleFrame
        let mouse = anchorWindow.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        let half = Self.size / 2
        let center = CGPoint(x: min(max(mouse.x, frame.minX + half), frame.maxX - half),
                             y: min(max(mouse.y, frame.minY + half), frame.maxY - half))
        panel.setFrame(CGRect(x: center.x - half, y: center.y - half, width: Self.size, height: Self.size), display: true)
        if dragging { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil) }
        if dragging {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if NSEvent.pressedMouseButtons & 1 == 0 { self?.closeRing() }
                }
            }
            endTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func closeRing() {
        if isDraggingRing { dismissedDragCount = NSPasteboard(name: .drag).changeCount }
        panel.orderOut(nil)
        selection = nil
        isDraggingRing = false
        endTimer?.invalidate()
        endTimer = nil
    }

    func target(_ point: CGPoint?) { selection = point.flatMap { Self.index(at: $0, count: actions.count) } }

    func perform(_ action: Action, on url: URL) {
        guard !busy, Self.actions(for: url).contains(action) else { return }
        closeRing()
        if action != .jpg {
            do { try EditorWindow.openFile(url, action: action) }
            catch { Toast.show("Couldn’t open the image", symbol: "exclamationmark.triangle", detail: error.localizedDescription) }
            return
        }
        busy = true
        result = .init()
        showResults()
        let task = Task.detached(priority: .userInitiated) { FileConversion.convertPDF(url) }
        conversion = task
        Task {
            result = await task.value
            busy = false
            conversion = nil
            if resultWindow?.isVisible != true { showResults() }
        }
    }

    func saved(_ url: URL) {
        guard !busy else {
            Toast.show("Saved", symbol: "arrow.down.circle.fill", detail: url.lastPathComponent)
            return
        }
        if !result.files.contains(url) { result.files.append(url) }
        showResults()
    }

    func cancelConversion() { conversion?.cancel() }

    func showResults() {
        if resultWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "File Tools".loc
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 400, height: 260)
            window.contentView = FloatingPanel.container(for: NSHostingView(rootView: FileResultsView(tools: self).orbitTint()))
            window.center()
            resultWindow = window
        }
        resultWindow?.bringToFront()
    }
}

/// This view owns the file-URL registration and the copy-only destination contract.
final class FileDropView: NSView {
    private let tools: FileTools
    init(tools: FileTools) {
        self.tools = tools
        super.init(frame: CGRect(x: 0, y: 0, width: FileTools.size, height: FileTools.size))
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    private func accepted(_ sender: NSDraggingInfo) -> Bool {
        guard tools.isDraggingRing, sender.draggingSourceOperationMask.contains(.copy),
              FileTools.file(from: sender.draggingPasteboard) == tools.source else {
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
        guard accepted(sender), let index = tools.selection, let url = tools.source else { return false }
        let action = tools.actions[index]
        // Accepting a copy never tells Finder to move or delete the input.
        DispatchQueue.main.async { [tools] in tools.perform(action, on: url) }
        return true
    }
}

private struct FileRingView: View {
    let tools: FileTools
    var body: some View {
        ZStack {
            Circle().fill(Palette.canvas.opacity(0.97))
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .frame(width: 288, height: 288).shadow(color: .black.opacity(0.25), radius: 10)
            Circle().stroke(Palette.ink.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: 206, height: 206)
            ForEach(Array(tools.actions.enumerated()), id: \.offset) { index, action in
                let angle = Double(index) * 2 * .pi / Double(tools.actions.count)
                Button { if let url = tools.source { tools.perform(action, on: url) } } label: {
                    VStack(spacing: 5) {
                        Image(systemName: action.symbol).font(.system(size: 23))
                        Text(action.title.loc).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(tools.selection == index ? Color.white : Palette.ink)
                    .frame(width: 82, height: 66)
                    .background(Capsule().fill(tools.selection == index ? Palette.accent : Palette.surface))
                }
                .buttonStyle(.plain)
                .offset(x: sin(angle) * 103, y: -cos(angle) * 103)
            }
            Button { tools.closeRing() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "xmark").font(.system(size: 13))
                    Text(tools.isDraggingRing ? "Drop to apply".loc : "Choose an action".loc)
                        .font(.system(size: 10)).multilineTextAlignment(.center).frame(width: 76)
                }.foregroundStyle(Palette.inkSecondary)
            }.buttonStyle(.plain)
        }
        .frame(width: FileTools.size, height: FileTools.size)
    }
}

private struct FileResultsView: View {
    let tools: FileTools
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tools.busy {
                HStack { ProgressView().controlSize(.small); Text("Converting to JPG…"); Spacer(); Button("Cancel") { tools.cancelConversion() } }
                Text("Completed pages stay saved if you cancel.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(tools.result.cancelled ? "Conversion cancelled".loc : tools.result.failure == nil ? "Conversion complete".loc : "Conversion stopped".loc)
                    .font(.headline)
                if let error = tools.result.failure { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text("%ld files saved".loc(tools.result.files.count)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(tools.result.files, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(url.lastPathComponent).lineLimit(2)
                            HStack {
                                Button("Crop") { tools.perform(.crop, on: url) }
                                Button("Background") { tools.perform(.background, on: url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            }.controlSize(.small)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Choose File…") { tools.chooseFile() }.disabled(tools.busy)
        }.padding(20).frame(minWidth: 400, minHeight: 260)
    }
}
