import AVFoundation
import Vision

/// One face check against the enrolled face: runs the camera until a few frames in a row match,
/// or the time runs out. Used by App Lock and by Mac unlock.
@MainActor
final class FaceMatcher {
    enum Event: Equatable {
        case noFace
        case tooFar
        case blink
        /// 0…1 as consecutive frames match.
        case progress(Double)
        case matched
        case failed
    }

    enum Unavailable {
        case notEnrolled
        case cameraOff
    }

    static var unavailable: Unavailable? {
        if !FaceStore.isEnrolled { return .notEnrolled }
        if !FaceScanner.authorized { return .cameraOff }
        return nil
    }

    private static let framesNeeded = 4

    private let onEvent: (Event) -> Void
    private var scanner: FaceScanner?
    private var enrolled: [VNFeaturePrintObservation] = []
    private var threshold: Float = 0.5
    private var streak = 0
    private var blink = BlinkDetector()
    private var timeout: DispatchWorkItem?
    private var done = false

    var session: AVCaptureSession? { scanner?.session }

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    /// False when there's no face to compare against or the camera won't start.
    func start(timeout seconds: TimeInterval) -> Bool {
        enrolled = FaceStore.load()
        guard !enrolled.isEmpty else { AppLockLog.write("scan: no enrolled face could be read"); return false }
        guard FaceScanner.authorized else { AppLockLog.write("scan: camera not authorized"); return false }
        let strictness = FaceStore.Strictness(rawValue: Pref.defaults.string(forKey: Pref.appLockStrictness) ?? "") ?? .normal
        threshold = FaceStore.threshold(for: enrolled, strictness: strictness)
        let s = FaceScanner()
        let started = s.start(cameraID: Pref.defaults.string(forKey: Pref.appLockCamera)) { [weak self] reading in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(reading) } }
        }
        guard started else { return false }
        scanner = s
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish(.failed) } }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return true
    }

    /// Turns the camera off; no further events.
    func stop() {
        done = true
        timeout?.cancel()
        timeout = nil
        scanner?.stop()
        scanner = nil
    }

    private func handle(_ r: FaceScanner.Reading) {
        guard !done else { return }
        guard r.face else { streak = 0; onEvent(.noFace); return }
        if r.tooFar { onEvent(.tooFar); return }
        blink.add(r.eyeOpenness)
        guard let print = r.print else { return }
        let best = enrolled.compactMap { e -> Float? in
            var d: Float = 0
            return (try? print.computeDistance(&d, to: e)) != nil ? d : nil
        }.min() ?? .infinity
        streak = best <= threshold ? streak + 1 : max(0, streak - 1)
        if streak >= Self.framesNeeded {
            if Pref.defaults.bool(forKey: Pref.appLockLiveness), !blink.blinked {
                onEvent(.blink)
                return
            }
            finish(.matched)
        } else {
            onEvent(.progress(Double(streak) / Double(Self.framesNeeded)))
        }
    }

    private func finish(_ event: Event) {
        guard !done else { return }
        stop()
        if event == .matched { onEvent(.progress(1)) }
        onEvent(event)
    }
}
