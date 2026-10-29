import AVFoundation
import LocalAuthentication
import Observation
import Vision

/// Guided face setup: confirm it's the owner (Touch ID / password), then collect samples while the
/// head slowly circles, one per direction around the ring plus a few straight on.
@MainActor @Observable
final class FaceEnrollment {
    static let shared = FaceEnrollment()

    enum State: Equatable {
        case idle
        case running
        case saved
        case failed(String)
    }

    static let segmentCount = 12
    private static let centerSamples = 3

    private(set) var state: State = .idle
    /// Directions already captured, index 0 at the top going clockwise.
    private(set) var segments = Array(repeating: false, count: segmentCount)
    private(set) var hint = "Look straight at the camera"
    private(set) var enrolled = FaceStore.isEnrolled
    private(set) var sampleCount = FaceStore.isEnrolled ? FaceStore.load().count : 0

    @ObservationIgnored private var scanner: FaceScanner?
    @ObservationIgnored private var prints: [VNFeaturePrintObservation] = []
    @ObservationIgnored private var center = 0
    @ObservationIgnored private var timeout: DispatchWorkItem?

    var previewSession: AVCaptureSession? { scanner?.session }

    var progress: Double {
        Double(segments.filter { $0 }.count + min(center, Self.centerSamples)) / Double(Self.segmentCount + Self.centerSamples)
    }

    func begin() {
        guard state != .running else { return }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Set up face unlock for App Lock".loc) { ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { FaceEnrollment.shared.startCamera() }
                }
            }
        }
    }

    private func startCamera() {
        Task { @MainActor in
            guard await FaceScanner.requestAccess() else {
                state = .failed("Allow Orbit to use the camera in System Settings › Privacy & Security › Camera.")
                return
            }
            prints = []
            center = 0
            segments = Array(repeating: false, count: Self.segmentCount)
            hint = "Look straight at the camera"
            let s = FaceScanner()
            scanner = s
            state = .running
            let started = s.start(cameraID: Pref.defaults.string(forKey: Pref.appLockCamera)) { reading in
                DispatchQueue.main.async { MainActor.assumeIsolated { FaceEnrollment.shared.handle(reading) } }
            }
            guard started else { finish(error: "Orbit couldn’t start the camera."); return }
            let work = DispatchWorkItem { MainActor.assumeIsolated { FaceEnrollment.shared.timedOut() } }
            timeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)
        }
    }

    private func handle(_ r: FaceScanner.Reading) {
        guard state == .running else { return }
        guard r.face else { hint = "Looking for your face…"; return }
        if r.tooFar { hint = "Come a little closer"; return }
        guard let print = r.print else { return }
        let x = r.yaw, y = -r.pitch
        let magnitude = hypot(x, y)
        if magnitude < 0.12 {
            if center < Self.centerSamples { prints.append(print); center += 1 }
            hint = center < Self.centerSamples ? "Look straight at the camera" : "Slowly move your head in a circle"
        } else {
            // atan2 from the top, clockwise: 0 = up, 3 = right, 6 = down, 9 = left.
            let angle = (atan2(x, y) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let index = Int((angle / (2 * .pi) * Double(Self.segmentCount)).rounded()) % Self.segmentCount
            if !segments[index], magnitude > 0.16 {
                segments[index] = true
                prints.append(print)
            }
            hint = "Slowly move your head in a circle"
        }
        if center >= Self.centerSamples, segments.filter({ $0 }).count >= Self.segmentCount - 2 { finish(error: nil) }
    }

    private func timedOut() {
        guard state == .running else { return }
        // Enough to work with, even if some directions were missed.
        finish(error: prints.count >= 8 ? nil : "Not enough of your face was seen. Try again in good light.")
    }

    func cancel() {
        stopCamera()
        state = .idle
    }

    private func finish(error: String?) {
        stopCamera()
        if let error { state = .failed(error); return }
        do {
            try FaceStore.save(prints)
            enrolled = true
            sampleCount = prints.count
            state = .saved
        } catch {
            state = .failed("Orbit couldn’t save your face: %@".loc(error.localizedDescription))
        }
        prints = []
    }

    func delete() {
        cancel()
        FaceStore.delete()
        enrolled = false
        sampleCount = 0
    }

    private func stopCamera() {
        timeout?.cancel()
        timeout = nil
        scanner?.stop()
        scanner = nil
    }
}
