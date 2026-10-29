import AppKit
import ScreenCaptureKit
import SwiftUI
import Observation

/// Scrolling screenshot: after you pick an area, Orbit watches it while you scroll and joins what
/// scrolls into view into one tall picture. A little panel by the area shows the picture growing,
/// with Done and Cancel; Auto-scroll scrolls for you until the page stops moving.
@MainActor @Observable
final class ScrollingCapture {
    static let shared = ScrollingCapture()

    enum Status: Equatable { case idle, waiting, capturing, lost, finishing }

    private(set) var status: Status = .idle
    private(set) var rows = 0
    private(set) var preview: NSImage?
    private(set) var autoScrolling = false

    @ObservationIgnored private var stitcher = ScrollStitcher()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scrollTask: Task<Void, Never>?
    @ObservationIgnored private var hud: FloatingPanel?
    @ObservationIgnored private var border: NSPanel?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var region: (rect: CGRect, screenID: CGDirectDisplayID, scale: CGFloat)?
    @ObservationIgnored private var quietFrames = 0

    var isRunning: Bool { status != .idle }
    var pixelScale: CGFloat { region?.scale ?? 2 }

    /// Starts on an area picked on screen (top-left origin, points, display-local).
    func begin(rect: CGRect, screenID: CGDirectDisplayID, scale: CGFloat) {
        guard !isRunning, rect.width >= 40, rect.height >= 40 else { return }
        region = (rect, screenID, scale)
        stitcher = ScrollStitcher()
        stitcher.maxHeight = 60_000
        rows = 0
        preview = nil
        quietFrames = 0
        status = .waiting
        showChrome(rect: rect, screenID: screenID)
        installKeys()
        task = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        guard isRunning else { return }
        tearDown()
        Toast.show("Scrolling capture cancelled", symbol: "xmark.circle.fill")
    }

    func done() {
        guard isRunning, status != .finishing else { return }
        status = .finishing
        let scale = region?.scale ?? 2
        let image = stitcher.image()
        tearDown()
        guard let image else { return }
        CaptureService.shared.finish(image, scale: scale)
    }

    func toggleAutoScroll() {
        if autoScrolling { stopAutoScroll(); return }
        guard let region else { return }
        autoScrolling = true
        // The scroll goes to whatever is under the pointer, so put it in the middle of the area.
        let display = CGDisplayBounds(region.screenID)
        let center = CGPoint(x: display.minX + region.rect.midX, y: display.minY + region.rect.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
        let step = Int32(max(40, region.rect.height * 0.22))
        scrollTask = Task { [weak self] in
            while !Task.isCancelled {
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0)?
                    .post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(180))
                guard let self, self.autoScrolling else { return }
            }
        }
    }

    private func stopAutoScroll() {
        autoScrolling = false
        scrollTask?.cancel()
        scrollTask = nil
    }

    // MARK: Frames

    private func run() async {
        guard let region else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == region.screenID }) else {
            Toast.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle.fill")
            tearDown()
            return
        }
        // Orbit's own panel and frame stay out of the picture.
        let own = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = region.rect
        config.width = Int((region.rect.width * region.scale).rounded())
        config.height = Int((region.rect.height * region.scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best

        let started = ContinuousClock.now
        var lastPreview = ContinuousClock.now - .seconds(1)
        while !Task.isCancelled, isRunning, status != .finishing {
            guard let frame = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            guard isRunning, status != .finishing else { return }
            switch stitcher.add(frame) {
            case .started:
                status = .capturing
            case .appended:
                status = .capturing
                quietFrames = 0
            case .unchanged:
                if status == .lost { status = .capturing }
                quietFrames += 1
                // Auto-scroll stops at the bottom of the page.
                if autoScrolling, quietFrames >= 8 { stopAutoScroll(); done(); return }
            case .lost:
                status = .lost
            }
            rows = stitcher.height
            if ContinuousClock.now - lastPreview > .milliseconds(350) {
                lastPreview = .now
                if let cg = stitcher.image() { preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
            }
            if ContinuousClock.now - started > .seconds(300) { done(); return }
            if stitcher.height >= stitcher.maxHeight { done(); return }
            try? await Task.sleep(for: .milliseconds(90))
        }
    }

    // MARK: Chrome

    private func showChrome(rect: CGRect, screenID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == screenID }) else { return }
        let area = CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)

        let frame = NSPanel(contentRect: area.insetBy(dx: -3, dy: -3), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        frame.level = .statusBar
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = false
        frame.ignoresMouseEvents = true
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 4])))
        host.sizingOptions = []
        frame.contentView = FloatingPanel.container(for: host)
        frame.orderFrontRegardless()
        border = frame

        let size = CGSize(width: 220, height: 300)
        let visible = screen.visibleFrame
        var origin: CGPoint
        if area.maxX + 16 + size.width <= visible.maxX {
            origin = CGPoint(x: area.maxX + 16, y: area.maxY - size.height)
        } else if area.minX - 16 - size.width >= visible.minX {
            origin = CGPoint(x: area.minX - 16 - size.width, y: area.maxY - size.height)
        } else {
            origin = CGPoint(x: area.maxX - size.width - 12, y: area.minY + 12)
        }
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        let panel = FloatingPanel(contentRect: .zero, focusable: false)
        panel.level = .statusBar
        panel.setContent(ScrollingHUD(session: self))
        panel.present(at: NSRect(origin: origin, size: size))
        hud = panel
    }

    private func installKeys() {
        let handler: (NSEvent) -> Bool = { [weak self] e in
            guard let self, self.isRunning else { return false }
            switch e.keyCode {
            case 53: self.cancel(); return true
            case 36, 76: self.done(); return true
            default: return false
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handler($0) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0) ? nil : $0 }) { monitors.append(l) }
    }

    private func tearDown() {
        stopAutoScroll()
        task?.cancel()
        task = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        border?.orderOut(nil)
        border = nil
        hud?.dismiss()
        hud = nil
        status = .idle
        region = nil
    }
}

private struct ScrollingHUD: View {
    let session: ScrollingCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(session.status == .lost ? Color.yellow : Palette.accent).frame(width: 7, height: 7)
                Text(title.loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                if session.rows > 0 {
                    Text("\(Int(CGFloat(session.rows) / session.pixelScale)) pt")
                        .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                }
            }
            Text(detail.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.raised)
                if let preview = session.preview {
                    // The newest part matters most: keep the bottom in view.
                    GeometryReader { geo in
                        let w = geo.size.width
                        let h = preview.size.height * w / max(1, preview.size.width)
                        Image(nsImage: preview).resizable().frame(width: w, height: h)
                            .frame(width: w, height: geo.size.height, alignment: h > geo.size.height ? .bottom : .top)
                            .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                Button { session.toggleAutoScroll() } label: {
                    Label(session.autoScrolling ? "Stop" : "Auto-scroll", systemImage: session.autoScrolling ? "pause.fill" : "arrow.down.to.line")
                        .font(.system(size: 11, weight: .semibold))
                }
                .controlSize(.small)
                .hoverHint("Orbit scrolls the area for you until the page ends".loc, below: false)
                Spacer()
                Button("Cancel") { session.cancel() }.controlSize(.small)
                Button("Done") { session.done() }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 220, height: 300)
        .modifier(PanelShell())
    }

    private var title: String {
        switch session.status {
        case .lost: "Scroll back a little"
        case .waiting: "Getting ready…"
        default: session.autoScrolling ? "Scrolling…" : "Scroll now"
        }
    }

    private var detail: String {
        switch session.status {
        case .lost: "That was too fast to follow — scroll up a bit, then keep going slower."
        default: "Scroll down through the area. Return finishes, esc cancels."
        }
    }
}
