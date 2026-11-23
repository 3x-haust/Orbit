import AppKit
import SwiftUI
@testable import Orbit

/// The menu bar calendar's clock: which formats show seconds, and that the real status item's
/// text follows the clock every second for those and every minute for the rest.
@main struct CalendarTests {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Expected an artifact directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        var failed = 0, passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failed += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
            fflush(stdout)
        }

        typealias Style = MenuBarCalendar.Style
        for (pattern, seconds) in [("yyyy년 MM월 dd일 (E) a hh:mm:ss", true), ("yyyy년 MM월 dd일 (E) a hh:mm", false),
                                   ("H:m:s", true), ("HH:mm 'sec'", false), ("HH:mm 'o''clock' ss", true), ("  ", false)] {
            check(Style.custom.showsSeconds(custom: pattern) == seconds, "custom \"\(pattern)\" \(seconds ? "shows" : "has no") seconds")
        }
        for style in [Style.none, .weekday, .date, .dateTime] {
            check(!style.showsSeconds(custom: "ss"), "\(style) has no seconds")
        }

        // This executable has its own defaults domain; settings go in the volatile argument domain.
        func settings(format: String) {
            UserDefaults.standard.setVolatileDomain([
                Pref.calendarEnabled: true, Pref.calendarIcon: "none",
                Pref.calendarStyle: "custom", Pref.calendarFormat: format,
            ], forName: UserDefaults.argumentDomain)
        }
        func expected(_ format: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = .current
            f.dateFormat = format
            return f.string(from: date)
        }
        /// The status item's title every quarter second, with when it was read.
        func sample(for seconds: TimeInterval) -> [(title: String, at: Date)] {
            var samples: [(String, Date)] = []
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                samples.append((MenuBarCalendar.shared.button?.title ?? "", Date()))
            }
            return samples
        }
        func snapshot(_ name: String) {
            guard let button = MenuBarCalendar.shared.button,
                  let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
            button.cacheDisplay(in: button.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
        }

        // Minutes only, as before: the text stays put between minute boundaries.
        settings(format: "HH:mm")
        MenuBarCalendar.shared.apply()
        check(MenuBarCalendar.shared.button?.title == expected("HH:mm", Date()), "minute format renders now")

        // The Calendar page calls apply() on a format change; seconds then tick every second.
        let format = "yyyy-MM-dd a hh:mm:ss"
        settings(format: format)
        MenuBarCalendar.shared.apply()
        var samples = sample(for: 2)
        snapshot("calendar-seconds-1.png")
        samples += sample(for: 2)
        snapshot("calendar-seconds-2.png")
        for s in samples { print("  \(s.title)") }
        let distinct = samples.map(\.title).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        check(distinct.count >= 4, "seconds format changes at least 4 times in 4 seconds (\(distinct.count))")
        check(samples.allSatisfy { [expected(format, $0.at), expected(format, $0.at.addingTimeInterval(-0.1))].contains($0.title) },
              "every sample matches the clock within a tenth of a second")

        // #89: the item keeps its width while the digits change, so the items beside it stay put.
        // Eleven seconds walk the last digit through 0–9.
        settings(format: "HH:mm:ss")
        MenuBarCalendar.shared.apply()
        var widths: [CGFloat] = []
        let widthEnd = Date().addingTimeInterval(11)
        while Date() < widthEnd {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if let w = MenuBarCalendar.shared.button?.window?.frame.width { widths.append(w) }
        }
        let distinctWidths = Set(widths)
        print("  widths: \(distinctWidths.sorted())")
        check(!widths.isEmpty && distinctWidths.count == 1, "the status item keeps one width while seconds tick (\(distinctWidths.count) widths)")

        // Back to minutes: the next render drops the seconds again.
        settings(format: "HH:mm")
        MenuBarCalendar.shared.apply()
        check(MenuBarCalendar.shared.button?.title == expected("HH:mm", Date()), "back to the minute format")

        // The Menu Bar page itself: typing a format with seconds there starts the second ticks.
        // @AppStorage reads the runner's own persistent domain, so the volatile overrides go.
        let keys = [Pref.calendarEnabled, Pref.calendarIcon, Pref.calendarStyle, Pref.calendarFormat]
        UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        for (key, value) in zip(keys, [true, "none", "custom", "HH:mm"] as [Any]) { UserDefaults.standard.set(value, forKey: key) }
        defer { keys.forEach(UserDefaults.standard.removeObject(forKey:)) }
        let page = NSHostingView(rootView: MenuBarPage().frame(width: 640).padding(24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 690, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page
        window.orderFrontRegardless()
        MenuBarCalendar.shared.apply()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        UserDefaults.standard.set(format, forKey: Pref.calendarFormat)
        let pageSamples = sample(for: 3)
        check(pageSamples.map(\.title).reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }.count >= 3,
              "a seconds format typed on the Menu Bar page ticks every second")
        check(pageSamples.last.map { [expected(format, $0.at), expected(format, $0.at.addingTimeInterval(-0.1))].contains($0.title) } ?? false,
              "the page's format reaches the menu bar")
        if let rep = page.bitmapImageRepForCachingDisplay(in: page.bounds) {
            page.cacheDisplay(in: page.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("menu-bar-page.png"))
        }
        window.close()

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
