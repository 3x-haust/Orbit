import AppKit
import ObjectiveC
@preconcurrency import Vision

// Replace only the OS boundary in this standalone process; OCR itself is unchanged.
private enum VisionFixture {
    static let requestError = NSError(domain: "OCRRequestFixture", code: 11,
                                      userInfo: [NSLocalizedDescriptionKey: "Recognition failed"])
    static let performError = NSError(domain: "OCRPerformFixture", code: 22,
                                      userInfo: [NSLocalizedDescriptionKey: "Perform failed"])
    static let mode = CommandLine.arguments.dropFirst().first ?? "real"
}

private extension VNImageRequestHandler {
    @objc func fixturePerform(_ requests: [VNRequest]) throws {
        precondition(requests.count == 1)
        let request = requests[0] as! VNRecognizeTextRequest
        precondition(request.recognitionLevel == .accurate)
        precondition(request.usesLanguageCorrection && request.automaticallyDetectsLanguage)
        precondition(request.recognitionLanguages == ["ko-KR", "en-US", "ja-JP", "zh-Hans"])
        precondition(!Thread.isMainThread, "Vision must run off the main thread")
        switch VisionFixture.mode {
        case "callback-and-throw":
            request.completionHandler?(request, VisionFixture.requestError)
            throw VisionFixture.performError
        case "callback-only":
            request.completionHandler?(request, VisionFixture.requestError)
        case "throw-only":
            throw VisionFixture.performError
        case "success-then-throw":
            request.completionHandler?(request, nil)
            throw VisionFixture.performError
        default:
            fatalError("Unknown fixture mode")
        }
    }
}

@main struct OCRTests {
    @MainActor static func image(lines: [String]) -> CGImage {
        let image = NSImage(size: NSSize(width: 800, height: 300), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: 40, y: 220 - index * 90), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.black
                ])
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    @MainActor static func main() async throws {
        var passed = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                fputs("FAIL: \(message)\n", stderr)
                exit(1)
            }
            passed += 1
            print("PASS: \(message)")
            fflush(stdout)
        }

        let blank = image(lines: [])
        if VisionFixture.mode != "real" {
            let original = class_getInstanceMethod(VNImageRequestHandler.self,
                                                   NSSelectorFromString("performRequests:error:"))!
            let fixture = class_getInstanceMethod(VNImageRequestHandler.self,
                                                  #selector(VNImageRequestHandler.fixturePerform(_:)))!
            precondition(String(cString: method_getTypeEncoding(original)!)
                         == String(cString: method_getTypeEncoding(fixture)!))
            method_exchangeImplementations(original, fixture)
            defer { method_exchangeImplementations(original, fixture) }

            let expected = ["callback-and-throw", "callback-only"].contains(VisionFixture.mode)
                ? VisionFixture.requestError : VisionFixture.performError
            var completions = 0
            do {
                _ = try await OCR.recognize(blank)
                completions += 1
                check(false, "\(VisionFixture.mode) must throw instead of returning text")
            } catch {
                completions += 1
                let actual = error as NSError
                check(actual.domain == expected.domain && actual.code == expected.code
                      && actual.localizedDescription == expected.localizedDescription,
                      "\(VisionFixture.mode) preserves the original error")
            }
            check(completions == 1, "\(VisionFixture.mode) completes exactly once without trapping")
        } else {
            let textImage = image(lines: ["Orbit recognition", "Hello world"])
            let text = try await OCR.recognize(textImage)
            check(text == "Orbit recognition\nHello world", "real Vision preserves text and line order (got \(text.debugDescription))")
            let empty = try await OCR.recognize(blank)
            check(empty == "", "a blank image returns an empty string")
            let korean = try await OCR.recognize(image(lines: ["안녕하세요", "반갑습니다"]))
            check(korean == "안녕하세요\n반갑습니다", "real Vision recognizes Korean (got \(korean.debugDescription))")
            try await withThrowingTaskGroup(of: String.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await OCR.recognize(textImage) }
                }
                var count = 0
                for try await result in group {
                    check(result == text, "concurrent recognition preserves its own result")
                    count += 1
                }
                check(count == 8, "all concurrent recognitions complete")
            }
        }
        if VisionFixture.mode != "real" {
            let recovered = try await OCR.recognize(blank)
            check(recovered == "", "real recognition still works after the injected failure")
        }
        print("ocr \(VisionFixture.mode): \(passed) passed, 0 failed")
    }
}
