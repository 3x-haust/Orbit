import AVFoundation
import CoreImage
import Vision

/// The camera and on-device face pipeline: find the face, level and crop it by the eyes, and turn
/// the crop into a Vision feature print. Frames are processed and dropped; nothing is written.
final class FaceScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// One processed frame.
    struct Reading {
        var face = false
        /// Face too small in the picture: come closer.
        var tooFar = false
        /// Head turn, roughly −1…1 each (Vision's yaw and pitch in radians).
        var yaw: Double = 0
        var pitch: Double = 0
        var print: VNFeaturePrintObservation?
        /// Eye openness, for the blink check.
        var eyeOpenness: Double?
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.lyu.orbit.facescanner")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var handler: ((Reading) -> Void)?
    private var lastProcessed = Date.distantPast
    private var running = false

    static let cropSize: CGFloat = 160

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    static var denied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    static func requestAccess() async -> Bool {
        if authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Starts the camera; `onReading` is called on a background queue for every processed frame.
    func start(cameraID: String?, onReading: @escaping (Reading) -> Void) -> Bool {
        let device = Self.cameras.first { $0.uniqueID == cameraID }
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? Self.cameras.first
        guard let device else { AppLockLog.write("scan: no camera found"); return false }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            AppLockLog.write("scan: \(device.localizedName) won't open: \(error)")
            return false
        }
        handler = onReading
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        guard session.canAddInput(input) else { session.commitConfiguration(); AppLockLog.write("scan: can't add camera input"); return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        running = true
        queue.async { self.session.startRunning() }
        return true
    }

    /// Turns the camera off right away.
    func stop() {
        running = false
        handler = nil
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard running, let handler, Date().timeIntervalSince(lastProcessed) > 0.08,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastProcessed = Date()
        handler(read(pixels))
    }

    private func read(_ pixels: CVPixelBuffer) -> Reading {
        var reading = Reading()
        let rects = VNDetectFaceRectanglesRequest()
        let marks = VNDetectFaceLandmarksRequest()
        let request = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        guard (try? request.perform([rects])) != nil,
              let face = rects.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return reading }
        reading.face = true
        reading.yaw = face.yaw?.doubleValue ?? 0
        reading.pitch = face.pitch?.doubleValue ?? 0
        guard face.boundingBox.width > 0.14 else { reading.tooFar = true; return reading }

        marks.inputFaceObservations = [face]
        guard (try? request.perform([marks])) != nil, let landmarks = marks.results?.first?.landmarks,
              let left = landmarks.leftEye, let right = landmarks.rightEye else { return reading }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let size = CGSize(width: width, height: height)
        let l = left.pointsInImage(imageSize: size), r = right.pointsInImage(imageSize: size)
        reading.eyeOpenness = (Self.openness(l) + Self.openness(r)) / 2

        guard let crop = align(CIImage(cvPixelBuffer: pixels), leftEye: Self.center(l), rightEye: Self.center(r)) else { return reading }
        let printRequest = VNGenerateImageFeaturePrintRequest()
        printRequest.imageCropAndScaleOption = .scaleFill
        if (try? VNImageRequestHandler(cgImage: crop).perform([printRequest])) != nil {
            reading.print = printRequest.results?.first
        }
        return reading
    }

    /// Levels the eyes and scales so they're always the same distance apart in a square crop.
    /// Vision's image points and Core Image both put the origin at the bottom left.
    private func align(_ image: CIImage, leftEye: CGPoint, rightEye: CGPoint) -> CGImage? {
        let dx = rightEye.x - leftEye.x, dy = rightEye.y - leftEye.y
        let distance = hypot(dx, dy)
        guard distance > 8 else { return nil }
        let side = Self.cropSize
        let scale = side * 0.38 / distance
        let mid = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        let transform = CGAffineTransform(translationX: -mid.x, y: -mid.y)
            .concatenating(CGAffineTransform(rotationAngle: -atan2(dy, dx)))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: side / 2, y: side * 0.6))
        let out = image.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        return context.createCGImage(out, from: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private static func center(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Eye height over eye width: drops sharply during a blink.
    private static func openness(_ points: [CGPoint]) -> Double {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return 0 }
        return Double((maxY - minY) / (maxX - minX))
    }
}

/// Watches eye openness for a dip and recovery — a photo held up to the camera doesn't blink.
struct BlinkDetector {
    private var baseline: [Double] = []
    private var dipped = false
    private(set) var blinked = false

    mutating func add(_ openness: Double?) {
        guard let openness, !blinked else { return }
        if baseline.count < 6 { baseline.append(openness); return }
        let open = baseline.sorted()[baseline.count / 2]
        if openness < open * 0.55 { dipped = true }
        else if dipped, openness > open * 0.8 { blinked = true }
        else if !dipped { baseline = Array((baseline + [openness]).suffix(12)) }
    }
}
