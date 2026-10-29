import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI
import Observation
import os

/// Scrolling screenshot: after you pick an area, Orbit watches it while you scroll and joins what
/// scrolls into view into one tall picture. A little panel by the area shows the picture growing,
/// with Done and Cancel; Auto-scroll scrolls for you until the page stops moving.
///
/// The area streams in at the display's frame rate (``ScrollCaptureEngine``) and every frame is
/// stitched on the stream's own queue, so fast scrolling doesn't outrun it; this class only keeps
/// the panel up to date, a few times a second.
@MainActor @Observable
final class ScrollingCapture {
    static let shared = ScrollingCapture()

    enum Status: Equatable { case idle, waiting, capturing, lost, finishing }

    private(set) var status: Status = .idle
    private(set) var rows = 0
    private(set) var preview: NSImage?
    private(set) var autoScrolling = false
    /// The scroll had to be held back more than once: worth suggesting a slower scroll.
    private(set) var slowHint = false

    @ObservationIgnored private var engine: ScrollCaptureEngine?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var scrollTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var hud: FloatingPanel?
    @ObservationIgnored private var border: NSPanel?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var region: (rect: CGRect, screenID: CGDirectDisplayID, scale: CGFloat)?
    /// Bumped whenever a capture starts or ends, so late callbacks from an old one are ignored.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var lastGrowth = ContinuousClock.now

    var isRunning: Bool { status != .idle }
    var pixelScale: CGFloat { region?.scale ?? 2 }

    /// Starts on an area picked on screen (top-left origin, points, display-local).
    func begin(rect: CGRect, screenID: CGDirectDisplayID, scale: CGFloat) {
        guard !isRunning, rect.width >= 40, rect.height >= 40 else { return }
        session += 1
        region = (rect, screenID, scale)
        rows = 0
        preview = nil
        slowHint = false
        status = .waiting
        lastGrowth = .now
        showChrome(rect: rect, screenID: screenID)
        installKeys()
        let current = session
        task = Task { [weak self] in await self?.run(current) }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1800))
            guard let self, !Task.isCancelled, self.session == current else { return }
            self.done()
        }
    }

    func cancel() {
        guard isRunning else { return }
        tearDown()
        Toast.show("Scrolling capture cancelled", symbol: "xmark.circle.fill")
    }

    func done() {
        guard isRunning, status != .finishing else { return }
        status = .finishing
        stopAutoScroll()
        let scale = pixelScale
        guard let engine else { tearDown(); return }
        let current = session
        engine.finish { [weak self] image in
            guard let self, self.session == current else { return }
            self.tearDown()
            guard let image else { return }
            CaptureService.shared.finish(image, scale: scale)
        }
    }

    func toggleAutoScroll() {
        if autoScrolling { stopAutoScroll(); return }
        guard let region else { return }
        autoScrolling = true
        lastGrowth = .now
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
                // Auto-scroll stops at the bottom of the page.
                if ContinuousClock.now - self.lastGrowth > .milliseconds(1500) {
                    self.stopAutoScroll()
                    self.done()
                    return
                }
            }
        }
    }

    private func stopAutoScroll() {
        autoScrolling = false
        scrollTask?.cancel()
        scrollTask = nil
    }

    // MARK: Frames

    private func run(_ current: Int) async {
        guard let region else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard session == current, isRunning else { return }
        guard let content, let display = content.displays.first(where: { $0.displayID == region.screenID }) else {
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
        config.scalesToFit = false
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // The display's own colour space: converting (to sRGB) can dither, and frames that aren't
        // bit for bit the same are harder to line up.
        config.queueDepth = 5
        let fps = (NSScreen.screens.first { $0.displayID == region.screenID }?.maximumFramesPerSecond ?? 60) >= 120 ? 120 : 60
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))

        let bounds = CGDisplayBounds(region.screenID)
        let area = region.rect.offsetBy(dx: bounds.minX, dy: bounds.minY)
        ScrollCaptureLog.shared.begin("area \(region.rect) pt on display \(region.screenID), scale \(region.scale), stream \(config.width)x\(config.height) px @\(fps) fps, global \(area)")
        let engine = ScrollCaptureEngine(area: area, scale: region.scale, maxHeight: 200_000) { [weak self] update in
            guard let self, self.session == current else { return }
            self.apply(update)
        }
        self.engine = engine
        do {
            try await engine.start(filter: filter, configuration: config)
        } catch {
            guard session == current, isRunning else { return }
            ScrollCaptureLog.shared.line("stream failed to start: \(error.localizedDescription)")
            Toast.show("Couldn’t capture the screen", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
            tearDown()
            return
        }
        // Cancelled while the stream was starting.
        if session != current || !isRunning { engine.stop() }
    }

    private func apply(_ update: ScrollCaptureEngine.Update) {
        guard isRunning, status != .finishing else { return }
        if update.failed {
            // The stream ended on its own (display gone, permission revoked): keep what there is.
            if rows > 0 { done() } else { cancel() }
            return
        }
        if update.rows > rows { lastGrowth = .now }
        rows = update.rows
        status = update.lost ? .lost : .capturing
        if let cg = update.preview { preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        if update.slowHint != slowHint { slowHint = update.slowHint }
        if update.full { done() }
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
        session += 1
        stopAutoScroll()
        // Stops the stream and lets go of the scroll tap right away, whatever the stitching queue is doing.
        engine?.stop()
        engine = nil
        task?.cancel()
        task = nil
        watchdog?.cancel()
        watchdog = nil
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

// MARK: - Engine

/// The stream of the area and the stitching, on a queue of their own.
///
/// Frames arrive at up to the display's refresh rate; ones ScreenCaptureKit marks idle (nothing
/// changed) are skipped before any pixel is read. Each new frame goes to the stitcher with the scroll
/// wheel's movement since the last one, and the panel hears about progress about four times a second.
final class ScrollCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Update: @unchecked Sendable {
        var lost = false
        var rows = 0
        var preview: CGImage?
        var slowHint = false
        var full = false
        var failed = false
    }

    let queue = DispatchQueue(label: "com.lyu.orbit.scrolling-capture", qos: .userInteractive)
    private let stitcher = ScrollStitcher()
    private let wheel: ScrollCaptureTap
    private let scale: CGFloat
    private let onUpdate: @MainActor (Update) -> Void
    /// Main thread only.
    private var stream: SCStream?

    // On `queue` only.
    private var stopped = false
    private var lastPublish: UInt64 = 0
    private var lastLost = false
    private var publishedRows = -1
    private var fastFrames = 0
    private var holding = false
    private let ticksPerMillisecond: Double
    private let started = mach_absolute_time()
    private var received = 0, idle = 0, early = 0, stitched = 0, quiet = 0
    private var colorSpaceSet = false

    init(area: CGRect, scale: CGFloat, maxHeight: Int, onUpdate: @escaping @MainActor (Update) -> Void) {
        self.scale = scale
        self.onUpdate = onUpdate
        wheel = ScrollCaptureTap(area: area, pixelsPerRaw: Double(scale))
        stitcher.maxHeight = maxHeight
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        ticksPerMillisecond = 1_000_000 * Double(info.denom) / Double(info.numer)
        super.init()
    }

    @MainActor
    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
        wheel.start()
    }

    /// Stops the stream and the scroll tap; frames still queued are dropped.
    @MainActor
    func stop() {
        wheel.stop()
        if let stream {
            self.stream = nil
            stream.stopCapture { _ in }
        }
        queue.async { self.stopped = true }
    }

    /// Stops, then hands over the whole picture (on the main thread).
    @MainActor
    func finish(_ done: @escaping @MainActor (CGImage?) -> Void) {
        stop()
        queue.async {
            ScrollCaptureLog.shared.line("done: \(self.stitcher.height) rows from \(self.stitched) frames (received \(self.received), idle \(self.idle), early \(self.early)), tap holds \(self.wheel.holds)")
            let image = self.stitcher.takeImage()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(image) } }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ScrollCaptureLog.shared.line("stream stopped: \(error.localizedDescription)")
        post(Update(failed: true))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else { return }
        received += 1
        let raw = info[.status] as? Int
        guard let raw, SCFrameStatus(rawValue: raw) == .complete, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            idle += 1 // nothing changed (or a blank/suspended frame)
            return
        }
        let now = mach_absolute_time()
        // The first moment after the area is picked, the picker may still be fading out.
        if Double(now &- started) < 200 * ticksPerMillisecond { early += 1; return }
        let shown = (info[.displayTime] as? UInt64) ?? now

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let bufferWidth = CVPixelBufferGetWidth(pixels), bufferHeight = CVPixelBufferGetHeight(pixels)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        // The picture may fill only part of the buffer: its content rect (points) times its scale.
        var crop = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight)
        if let dict = info[.contentRect], let content = CGRect(dictionaryRepresentation: dict as! CFDictionary) {
            let k = (info[.scaleFactor] as? CGFloat) ?? (info[.contentScale] as? CGFloat).map { _ in scale } ?? scale
            let px = CGRect(x: content.minX * k, y: content.minY * k, width: content.width * k, height: content.height * k).integral
            if px.width >= 16, px.height >= 16, px.minX >= 0, px.minY >= 0, px.maxX <= CGFloat(bufferWidth), px.maxY <= CGFloat(bufferHeight) {
                crop = px
            }
            if stitched == 0 {
                ScrollCaptureLog.shared.line("first frame: buffer \(bufferWidth)x\(bufferHeight) (row \(bytesPerRow) B), content \(content) pt × \(k) → crop \(crop)")
            }
        } else if stitched == 0 {
            ScrollCaptureLog.shared.line("first frame: buffer \(bufferWidth)x\(bufferHeight) (row \(bytesPerRow) B), no content rect")
        }
        if !colorSpaceSet {
            colorSpaceSet = true
            if let space = CVImageBufferGetColorSpace(pixels)?.takeUnretainedValue() { stitcher.colorSpace = space }
        }
        let frame = StitchFrame(base: UnsafeRawPointer(base + Int(crop.minY) * bytesPerRow + Int(crop.minX) * 4), bytesPerRow: bytesPerRow,
                                width: Int(crop.width), height: Int(crop.height))
        let motion = wheel.take(until: shown)
        let t0 = mach_absolute_time()
        let outcome = stitcher.add(frame, motion: motion)
        let ms = Double(mach_absolute_time() &- t0) / ticksPerMillisecond
        stitched += 1
        wheel.learned(pixelsPerRaw: stitcher.pixelsPerRaw)
        if outcome == .unchanged {
            quiet += 1
        } else {
            let m = motion.map { String(format: "%.0f", $0) } ?? "?"
            ScrollCaptureLog.shared.line(String(format: "#%d %@ shift %@ rows %d wheel %@ %.2f ms | %@ (quiet %d, idle %d)",
                                                stitched, "\(outcome)", stitcher.lastShift.map(String.init) ?? "-", stitcher.height, m, ms,
                                                stitcher.note, quiet, idle))
            quiet = 0
        }

        // Too fast to follow (or close to it): from now on the tap holds the scroll back to what a
        // frame can take. Only once tracking works and the wheel is understood, and only for jumps
        // the wheel itself reports as too big.
        let limit = Double(stitcher.frameHeight) * 0.6
        switch outcome {
        case .lost:
            if let px = stitcher.pixelsPerRaw, let m = motion, abs(m) * px > limit { fastFrames += 1 }
        case .appended, .moved:
            if let s = stitcher.lastShift, Double(abs(s)) > limit { fastFrames += 1 }
        default: break
        }
        if fastFrames >= 2, !holding {
            holding = true
            ScrollCaptureLog.shared.line("holding the scroll back to \(Int(limit)) px per frame")
            let wheel = self.wheel
            DispatchQueue.main.async { MainActor.assumeIsolated { wheel.holdBack(limit: limit) } }
        }

        let lost = outcome == .lost
        let full = outcome == .full || stitcher.height >= stitcher.maxHeight
        guard lost != lastLost || full || publishedRows < 0 || Double(now &- lastPublish) >= 250 * ticksPerMillisecond else { return }
        lastPublish = now
        lastLost = lost
        var update = Update(lost: lost, rows: stitcher.height, slowHint: wheel.holds >= 3, full: full)
        if stitcher.height != publishedRows {
            publishedRows = stitcher.height
            update.preview = stitcher.preview(maxWidth: 440)
        }
        post(update)
    }

    private func post(_ update: Update) {
        let onUpdate = self.onUpdate
        DispatchQueue.main.async { MainActor.assumeIsolated { onUpdate(update) } }
    }
}

// MARK: - Scroll wheel

/// Watches the scroll wheel while a scrolling capture runs, for the stitcher's guess of where the page
/// went: point deltas of scrolls over the area, timed, so each frame gets the ones from before it was
/// on screen. Direction and scale (natural scrolling, Orbit's own scroll reverser, app acceleration)
/// are left to the stitcher, which learns them from frames it placed.
///
/// Listen-only at first. Only if frames still fall behind does it become an active tap that trims
/// scrolls over the area, so the page never moves more than a set distance between two frames;
/// scrolls anywhere else pass untouched. It's gone the moment the capture ends.
final class ScrollCaptureTap: @unchecked Sendable {
    private struct Event { var time: UInt64; var raw: Double; var inside: Bool }
    private struct State {
        var events: [Event] = []
        var pixelsPerRaw: Double
        /// Pixels the page may move per frame; infinite until holding back.
        var limit = Double.infinity
        var holds = 0
    }

    private let area: CGRect
    private let state: OSAllocatedUnfairLock<State>
    /// Between a scroll and the frame that shows it.
    private let lagTicks: UInt64
    /// Scrolls older than this no longer count as on their way to the screen.
    private let staleTicks: UInt64
    private let tapLock = NSLock()
    nonisolated(unsafe) private var thread: EventTapThread?
    /// Main thread only.
    nonisolated(unsafe) private var ended = false
    nonisolated(unsafe) private var active = false

    init(area: CGRect, pixelsPerRaw: Double) {
        self.area = area
        state = OSAllocatedUnfairLock(initialState: State(pixelsPerRaw: pixelsPerRaw))
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ms = 1_000_000 * Double(info.denom) / Double(info.numer)
        lagTicks = UInt64(12 * ms)
        staleTicks = UInt64(150 * ms)
    }

    deinit { thread?.stop() }

    var holds: Int { state.withLock { $0.holds } }

    @MainActor func start() {
        guard !ended, thread == nil else { return }
        install(active: false)
    }

    /// Becomes an active tap and trims scrolls over the area to `limit` pixels per frame.
    @MainActor func holdBack(limit: Double) {
        guard !ended, !active else { return }
        if install(active: true) {
            active = true
            state.withLock { $0.limit = limit }
        }
    }

    @MainActor func stop() {
        ended = true
        tapLock.lock()
        let old = thread
        thread = nil
        tapLock.unlock()
        old?.stop()
        // A callback already running on the tap's thread may still be using this object.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(self) {} }
    }

    @MainActor @discardableResult
    private func install(active: Bool) -> Bool {
        defer { ScrollCaptureLog.shared.line("scroll tap \(active ? "active" : "listening"): \(thread != nil ? "on" : "unavailable")") }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let options: CGEventTapOptions = active ? .defaultTap : .listenOnly
        // Where events have been annotated for their app: after every session tap, Orbit's scroll
        // reverser included, so the deltas are what the page will actually get.
        guard let port = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: options,
                                           eventsOfInterest: mask, callback: scrollCaptureCallback, userInfo: me)
                ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: options,
                                     eventsOfInterest: mask, callback: scrollCaptureCallback, userInfo: me) else { return false }
        let next = EventTapThread(port: port, name: "Orbit scrolling capture")
        tapLock.lock()
        let old = thread
        thread = next
        tapLock.unlock()
        old?.stop()
        return true
    }

    fileprivate func reenable() {
        tapLock.lock()
        let current = thread
        tapLock.unlock()
        current?.reenable()
    }

    /// On the tap's thread.
    fileprivate func handle(_ event: CGEvent) {
        let point = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        guard point != 0 else { return }
        let inside = area.contains(event.location)
        let now = mach_absolute_time()
        let stale = staleTicks
        state.withLock { s in
            let keep = stale * 7 // about a second
            let cutoff = now > keep ? now - keep : 0
            if let first = s.events.first, first.time < cutoff { s.events.removeAll { $0.time < cutoff } }
            var raw = Double(point)
            if inside, s.limit.isFinite {
                // What's on its way to the screen already, in the same direction.
                var pending = 0.0
                for e in s.events where e.inside && now &- e.time < stale { pending += e.raw }
                if pending == 0 || (pending > 0) == (raw > 0) {
                    let allowed = s.limit - abs(pending) * s.pixelsPerRaw
                    let wanted = abs(raw) * s.pixelsPerRaw
                    if wanted > allowed {
                        // Slowed, never stopped: a scroll that does nothing feels broken.
                        let k = max(0.25, max(0, allowed) / wanted)
                        Self.scale(event, by: k)
                        raw *= k
                        s.holds += 1
                    }
                }
            }
            s.events.append(Event(time: now, raw: raw, inside: inside))
        }
    }

    /// Wheel movement over the area up to a frame shown at `shown` (mach time); nil when some scroll
    /// happened elsewhere, which may or may not have moved the area.
    func take(until shown: UInt64) -> Double? {
        let cut = shown > lagTicks ? shown - lagTicks : 0
        return state.withLock { s -> Double? in
            var sum = 0.0, outside = false, n = 0
            for e in s.events {
                guard e.time <= cut else { break }
                if e.inside { sum += e.raw } else { outside = true }
                n += 1
            }
            s.events.removeFirst(n)
            return outside ? nil : sum
        }
    }

    func learned(pixelsPerRaw: Double?) {
        guard let pixelsPerRaw else { return }
        state.withLock { $0.pixelsPerRaw = pixelsPerRaw }
    }

    private static func scale(_ e: CGEvent, by k: Double) {
        let fixed = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let point = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        // Lines first: setting them makes macOS recompute the other two, which are set after.
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64((fixed * k).rounded(.towardZero)))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixed * k)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64((Double(point) * k).rounded(.towardZero)))
    }
}

private func scrollCaptureCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<ScrollCaptureTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput: tap.reenable()
    case .scrollWheel: tap.handle(event)
    default: break
    }
    return Unmanaged.passUnretained(event)
}

// MARK: - Log

/// ~/Library/Logs/Orbit/scrolling.log: what each capture saw, frame by frame, so a capture that went
/// wrong can be told apart afterwards. Written on a queue of its own; starts over past 1 MB.
final class ScrollCaptureLog: @unchecked Sendable {
    static let shared = ScrollCaptureLog()
    private let queue = DispatchQueue(label: "com.lyu.orbit.scrolling-log", qos: .utility)
    private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit/scrolling.log")
    private var handle: FileHandle?
    private var start = Date()

    func begin(_ text: String) {
        queue.async {
            self.start = Date()
            self.open()
            self.write("\n=== \(ISO8601DateFormatter().string(from: Date())) scrolling capture: \(text)")
        }
    }

    func line(_ text: String) {
        let t = Date()
        queue.async { self.write(String(format: "%7.3f ", t.timeIntervalSince(self.start)) + text) }
    }

    private func open() {
        guard handle == nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 { try? fm.removeItem(at: url) }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func write(_ text: String) {
        open()
        handle?.write(Data((text + "\n").utf8))
    }
}

// MARK: - Panel

private struct ScrollingHUD: View {
    let session: ScrollingCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(session.status == .lost ? Color.yellow : Palette.accent).frame(width: 7, height: 7)
                Text(title.loc).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                if session.rows > 0 {
                    // The saved picture's height, in pixels (what the file will be).
                    Text("\(session.rows.formatted()) px")
                        .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                }
            }
            Text(detail.loc).font(.orbitMicro).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            if session.slowHint, session.status != .lost {
                Label("Slower scrolling is more accurate".loc, systemImage: "tortoise")
                    .font(.orbitMicro).foregroundStyle(Palette.inkSecondary)
                    .transition(.opacity)
            }
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
        .animation(.easeOut(duration: 0.2), value: session.slowHint)
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
