import AVFoundation
import AppKit
import Observation
import ScreenCaptureKit

extension Pref {
    /// 30 or 60.
    static let recordFPS = "record.fps"
    static let recordCursor = "record.cursor"
    static let recordClicks = "record.clicks"
    static let recordSystemAudio = "record.systemAudio"
    static let recordMic = "record.mic"
    /// Seconds before recording starts; 0 = none.
    static let recordCountdown = "record.countdown"
    /// "none" (just the preview) or "quicktime".
    static let recordOpen = "record.open"
}

/// Defaults for the recording prefs, which aren't registered with the rest.
enum RecordPrefs {
    static var fps: Int { (Pref.defaults.object(forKey: Pref.recordFPS) as? Int) ?? 60 }
    static var cursor: Bool { (Pref.defaults.object(forKey: Pref.recordCursor) as? Bool) ?? true }
    static var clicks: Bool { (Pref.defaults.object(forKey: Pref.recordClicks) as? Bool) ?? true }
    static var systemAudio: Bool { Pref.defaults.bool(forKey: Pref.recordSystemAudio) }
    static var mic: Bool { Pref.defaults.bool(forKey: Pref.recordMic) }
    static var countdown: Int { (Pref.defaults.object(forKey: Pref.recordCountdown) as? Int) ?? 3 }
    static var open: String { Pref.defaults.string(forKey: Pref.recordOpen) ?? "none" }
}

/// What gets recorded. Frames are Cocoa global coordinates (origin bottom-left of the main screen).
struct RecordTarget {
    enum Kind { case area, window, screen }
    let kind: Kind
    let screen: NSScreen
    var frame: CGRect
    var windowID: CGWindowID?

    static func screen(_ screen: NSScreen) -> RecordTarget { RecordTarget(kind: .screen, screen: screen, frame: screen.frame) }
}

/// Screen recording with ScreenCaptureKit: pick → countdown → record → preview, CleanShot-style.
/// Orbit's own recording controls (and its other passing chrome) never end up in the video.
@MainActor @Observable
final class Recorder: NSObject {
    static let shared = Recorder()

    enum Mode { case area, window, screen }
    enum State: Equatable { case idle, preparing, recording, finishing }

    private(set) var state: State = .idle
    private(set) var startedAt: Date?
    /// The microphone is part of this recording (allowed and turned on in settings).
    private(set) var micOn = false
    private(set) var micMuted = false
    /// Live switches in the controls; each change also becomes the default for the next recording.
    private(set) var showsCursor = true
    private(set) var highlightsClicks = true
    private(set) var systemAudioOn = false

    var isRecording: Bool { state == .recording }

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var config: SCStreamConfiguration?
    @ObservationIgnored private var target: RecordTarget?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var writer: RecordingWriter?
    /// Orbit draws its own click rings: an overlay for areas and screens, painted into the frames for a
    /// window. ScreenCaptureKit's are only the fallback, if neither can run.
    @ObservationIgnored private var ownClicks = false
    @ObservationIgnored private let chrome = RecordingChrome()

    /// Starting while a recording runs stops it, so one shortcut does both.
    func start(_ mode: Mode) {
        if state == .recording { stop(); return }
        guard state == .idle else { return }
        guard Permissions.shared.screenCapture || CGPreflightScreenCaptureAccess() else {
            PermissionPrompt.show(.screenCapture)
            return
        }
        state = .preparing
        Task {
            let picked: RecordTarget? = switch mode {
            case .screen: .screen(NSScreen.active)
            case .area, .window: await RecordPicker.run(windowMode: mode == .window)
            }
            guard let picked else { state = .idle; return }
            await prepare(picked)
        }
    }

    /// Records an area already picked elsewhere (V in the capture overlay): countdown, then record.
    func start(target: RecordTarget) {
        guard state == .idle else { return }
        guard Permissions.shared.screenCapture || CGPreflightScreenCaptureAccess() else {
            PermissionPrompt.show(.screenCapture)
            return
        }
        state = .preparing
        Task { await prepare(target) }
    }

    private func prepare(_ picked: RecordTarget) async {
        // The microphone track is there whenever the mic may be used, so it can be switched on
        // mid-recording; it's only listening while it's on.
        let micWanted = RecordPrefs.mic
        micOn = micWanted ? await Self.micAllowed() : AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        micMuted = !micWanted
        showsCursor = RecordPrefs.cursor
        highlightsClicks = RecordPrefs.clicks
        systemAudioOn = RecordPrefs.systemAudio
        let seconds = RecordPrefs.countdown
        if seconds > 0, !(await Countdown.run(seconds: seconds, over: picked)) { state = .idle; return }
        await begin(picked)
    }

    func stop() {
        guard state == .recording else { return }
        state = .finishing
        Task {
            let url = fileURL
            await teardown()
            if let url { await deliver(url) }
            state = .idle
        }
    }

    /// Throws the recording away.
    func discard() {
        guard state == .recording else { return }
        state = .finishing
        Task {
            let url = fileURL
            await teardown()
            if let url { try? FileManager.default.removeItem(at: url) }
            state = .idle
            Toast.show("Recording discarded", symbol: "trash")
        }
    }

    /// Starts over on the same area, window or screen, without a countdown.
    func restart() {
        guard state == .recording, let target else { return }
        state = .preparing
        Task {
            let url = fileURL
            await teardown()
            if let url { try? FileManager.default.removeItem(at: url) }
            await begin(target)
        }
    }

    func toggleMic() {
        guard state == .recording, micOn, let stream, let config else { return }
        micMuted.toggle()
        Pref.defaults.set(!micMuted, forKey: Pref.recordMic)
        config.captureMicrophone = !micMuted
        Task {
            do { try await stream.updateConfiguration(config) } catch {
                micMuted.toggle()
                Pref.defaults.set(!micMuted, forKey: Pref.recordMic)
                config.captureMicrophone = !micMuted
                Toast.show("Couldn’t change the microphone", symbol: "mic.slash", detail: error.localizedDescription)
            }
        }
    }

    func toggleCursor() {
        guard state == .recording, let stream, let config else { return }
        showsCursor.toggle()
        Pref.defaults.set(showsCursor, forKey: Pref.recordCursor)
        config.showsCursor = showsCursor
        applyClicks()
        Task { try? await stream.updateConfiguration(config) }
    }

    func toggleClicks() {
        guard state == .recording, let stream, let config else { return }
        highlightsClicks.toggle()
        Pref.defaults.set(highlightsClicks, forKey: Pref.recordClicks)
        applyClicks()
        Task { try? await stream.updateConfiguration(config) }
    }

    /// App sound keeps being captured and is written as silence while off, so it can come back.
    func toggleSystemAudio() {
        guard state == .recording else { return }
        systemAudioOn.toggle()
        Pref.defaults.set(systemAudioOn, forKey: Pref.recordSystemAudio)
        writer?.systemAudioOn = systemAudioOn
    }

    /// Click rings show only with the pointer.
    private func applyClicks() {
        let on = showsCursor && highlightsClicks
        if ownClicks { ClickHighlighter.shared.enabled = on }
        config?.showMouseClicks = on && !ownClicks
    }

    // MARK: Recording

    private func begin(_ target: RecordTarget) async {
        self.target = target
        // Orbit's own click rings. For areas and screens, an overlay that's up before the filter, so it
        // can be kept in — always, so the rings can be switched on mid-recording; it draws nothing while
        // off. A window recording can't include another window, so the writer paints them instead.
        ownClicks = true
        if target.kind != .window {
            ClickHighlighter.shared.start(on: target.screen)
            ClickHighlighter.shared.enabled = showsCursor && highlightsClicks
            try? await Task.sleep(for: .milliseconds(60))
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let (filter, size) = try Self.filter(for: target, in: content)
            let config = SCStreamConfiguration()
            config.width = Self.even(size.width)
            config.height = Self.even(size.height)
            if target.kind == .area {
                let s = target.screen.frame
                config.sourceRect = CGRect(x: target.frame.minX - s.minX, y: s.maxY - target.frame.maxY,
                                           width: target.frame.width, height: target.frame.height)
            }
            let fps = RecordPrefs.fps
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 8
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorSpaceName = CGColorSpace.sRGB
            config.showsCursor = showsCursor
            config.showMouseClicks = showsCursor && highlightsClicks && !ownClicks
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.captureMicrophone = micOn && !micMuted
            if micOn { config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID }

            let url = Self.newURL()
            let writer = try RecordingWriter(url: url, size: CGSize(width: config.width, height: config.height), fps: fps,
                                             systemAudioOn: systemAudioOn, mic: micOn, paintsClicks: target.kind == .window)
            if target.kind == .window, let id = target.windowID {
                ClickHighlighter.shared.capture { [weak writer] point, secondary in
                    guard let bounds = Self.bounds(of: id) else { return }
                    writer?.addClick(at: point, windowBounds: bounds, secondary: secondary)
                }
                ClickHighlighter.shared.enabled = showsCursor && highlightsClicks
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
            if micOn { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
            try await stream.startCapture()
            self.writer = writer

            self.stream = stream
            self.config = config
            fileURL = url
            startedAt = Date()
            state = .recording
            chrome.show(target, mic: micOn)
        } catch {
            ClickHighlighter.shared.stop()
            if let writer { _ = await writer.finish() }
            writer = nil
            state = .idle
            self.target = nil
            Toast.show("Couldn’t start recording", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
        }
    }

    /// Stops the stream and waits for the file to be written.
    private func teardown() async {
        chrome.hide()
        ClickHighlighter.shared.stop()
        guard let stream else { return }
        self.stream = nil
        config = nil
        try? await stream.stopCapture()
        if let writer {
            self.writer = nil
            if let error = await writer.finish() {
                Toast.show("Recording failed", symbol: "exclamationmark.triangle.fill", detail: error.localizedDescription)
            }
        }
        startedAt = nil
    }

    /// Hands the finished file to the preview stack (and QuickTime, if asked).
    private func deliver(_ url: URL) async {
        fileURL = nil
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard FileManager.default.fileExists(atPath: url.path), seconds > 0.3 else {
            try? FileManager.default.removeItem(at: url)
            Toast.show("The recording was too short", symbol: "record.circle")
            return
        }
        VideoTools.durations[url] = seconds
        let thumbnail = await VideoTools.thumbnail(url, scale: target?.screen.backingScaleFactor ?? 2)
        let capture = Capture(image: thumbnail, fileURL: url)
        QuickAccess.shared.add(capture)
        if RecordPrefs.open == "quicktime" { VideoTools.open(url) }
    }

    /// Picked mode → what ScreenCaptureKit should look at, and the output size in pixels.
    private static func filter(for target: RecordTarget, in content: SCShareableContent) throws -> (SCContentFilter, CGSize) {
        if target.kind == .window {
            guard let id = target.windowID, let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecordError.windowGone
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            return (filter, CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale))
        }
        guard let display = content.displays.first(where: { $0.displayID == target.screen.displayID }) else { throw RecordError.noDisplay }
        // Leave out every Orbit window (the controls, toasts, previews…) except its real windows and menu bar icons.
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == me }
        let clicks = ClickHighlighter.shared.windowID
        let notch = notchWindowIDs(on: target.screen)
        let keep = content.windows.filter { w in
            w.owningApplication?.processID == me
                && (w.windowLayer == 0 || w.windowLayer == Int(CGWindowLevelForKey(.statusWindow)) || w.windowID == clicks
                    || notch.contains(w.windowID))
                && !RecordingChrome.windowIDs.contains(w.windowID)
        }
        RecordingLog.write("filter: click overlay \(clicks.map(String.init) ?? "none"), kept in \(keep.contains { $0.windowID == clicks })")
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: keep)
        let scale = target.screen.backingScaleFactor
        return (filter, CGSize(width: target.frame.width * scale, height: target.frame.height * scale))
    }

    /// The window's frame right now (global, top-left origin), or nil once it's gone.
    /// What grows out of the notch (the notch itself, its player and HUDs, the top shelf) is part of
    /// the screen people see, so it's recorded like a real window: anything of Orbit's hanging from
    /// the top edge across the notch's middle.
    private static func notchWindowIDs(on screen: NSScreen) -> Set<CGWindowID> {
        let top = screen.frame.maxY, mid = screen.frame.midX
        let ids = NSApp.windows.filter { w in
            guard w.isVisible else { return false }
            let named = String(describing: type(of: w)).contains("Notch")
            let hanging = w.frame.maxY >= top - 2 && w.frame.minX <= mid && w.frame.maxX >= mid && w.frame.height < screen.frame.height * 0.8
            return (named || hanging) && screen.frame.intersects(w.frame)
        }.compactMap { CGWindowID(exactly: $0.windowNumber) }
        return Set(ids)
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as! CFDictionary? else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    private static func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }

    private static func micAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            Toast.show("Microphone access is off", symbol: "mic.slash", detail: "Recording without your voice — allow Orbit in Privacy & Security.")
            return false
        }
    }

    private static func newURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return CaptureService.dir.appendingPathComponent("Orbit Recording \(f.string(from: Date())).mp4")
    }

    enum RecordError: LocalizedError {
        case windowGone, noDisplay
        var errorDescription: String? {
            switch self {
            case .windowGone: "The window closed before recording started.".loc
            case .noDisplay: "That display isn’t available.".loc
            }
        }
    }

    // MARK: Delegate events

    /// The system stopped the stream (the window closed, the display went away, "Stop Sharing" in the
    /// menu bar…): keep what was recorded.
    fileprivate func streamStopped(_ error: Error) {
        guard state == .recording else { return }
        stop()
    }
}

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in Recorder.shared.streamStopped(error) }
    }
}
