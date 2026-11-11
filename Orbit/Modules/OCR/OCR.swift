@preconcurrency import Vision
import CoreGraphics

/// On-device text recognition shared by capture, clipboard indexing and the launcher.
enum OCR {
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Vision invokes the callback on this queue before perform returns.
                // Keep request errors, but complete only after perform has finished.
                var requestError: Error?
                let request = VNRecognizeTextRequest { _, error in requestError = error }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                request.recognitionLanguages = ["ko-KR", "en-US", "ja-JP", "zh-Hans"]
                let result = Result<String, Error> {
                    do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                    catch { throw requestError ?? error }
                    if let requestError { throw requestError }
                    let lines = (request.results ?? [])
                        .compactMap { $0.topCandidates(1).first?.string }
                    return lines.joined(separator: "\n")
                }
                continuation.resume(with: result)
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
