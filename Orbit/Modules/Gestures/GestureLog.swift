import Foundation

/// ~/Library/Logs/Orbit/gestures.log: which gesture ran what, and why one didn't. Never what was typed:
/// keyboard rules are named by their rule, not their keys.
enum GestureLog {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Orbit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gestures.log")
    }()

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let queue = DispatchQueue(label: "Orbit gestures log")

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
