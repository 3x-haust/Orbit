@preconcurrency import Vision
import CoreGraphics

/// On-device text recognition shared by capture, clipboard indexing and the launcher.
enum OCR {
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans"]
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// QR / barcode payloads, if any.
    static func barcodes(_ image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
