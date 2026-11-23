import Foundation

// swiftc Orbit/Modules/Notch/NotchHomeLayout.swift tools/regressions/notch-home-layout-tests.swift -o <test-binary>
@main struct NotchHomeLayoutTests {
    static func main() throws {
        let standard = NotchHomeLayout.decode(Data())
        precondition(standard.widgets == [.music, .calendar] && standard.ratio == .leadingWide)

        let equal = NotchHomeLayout(widgets: [.music, .aiUsage], ratio: .equal)
        let saved = try JSONEncoder().encode(equal)
        precondition(NotchHomeLayout.decode(saved) == equal)
        precondition(equal.widths(total: 529, gap: 29) == [250, 250])

        let wide = NotchHomeLayout(widgets: [.aiUsage, .calendar])
        precondition(wide.widths(total: 529, gap: 29) == [500 - 500 / 3.0, 500 / 3.0])
        let reversed = NotchHomeLayout(widgets: [.calendar, .aiUsage], ratio: .trailingWide)
        precondition(reversed.widths(total: 529, gap: 29) == [500 / 3.0, 500 - 500 / 3.0])

        let all = NotchHomeLayout(widgets: [.aiUsage, .music, .aiUsage, .calendar])
        precondition(all.widgets == [.aiUsage, .music, .calendar])
        precondition(all.widths(total: 448, gap: 29) == [130, 130, 130])
        precondition(all.widths(total: 10, gap: 29) == [0, 0, 0])

        let onlyAI = NotchHomeLayout(widgets: [.aiUsage])
        precondition(onlyAI.widths(total: 448, gap: 29) == [448])
        let future = Data(#"{"widgets":["futureWidget","aiUsage","aiUsage"],"ratio":"futureRatio"}"#.utf8)
        precondition(NotchHomeLayout.decode(future) == onlyAI)
        precondition(NotchHomeLayout(widgets: []) == standard)
        print("PASS: notch Home defaults, persistence, order, ratios, and invalid layouts")
    }
}
