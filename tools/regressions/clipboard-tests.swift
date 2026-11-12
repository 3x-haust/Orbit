import AppKit
@testable import Orbit

@main struct ClipboardTests {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: clipboard-tests <scratch directory>")
            exit(2)
        }
        let failed = try await run(scratch: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        exit(failed == 0 ? 0 : 1)
    }

    @MainActor static func run(scratch: URL) async throws -> Int {
        var passed = 0, failed = 0
        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1 } else { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func sameBytes(_ actual: String?, _ expected: String) -> Bool {
            actual.map { Data($0.utf8) == Data(expected.utf8) } ?? false
        }

        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments[Pref.historyLimit] = 100
        arguments[Pref.ignoredApps] = [String]()
        arguments[Pref.pausedUntil] = 0
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }

        let directory = scratch.appendingPathComponent("clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let historyURL = directory.appendingPathComponent("history.json")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Orbit.ClipboardTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        func publish(_ text: String) throws {
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw NSError(domain: "ClipboardTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot write the isolated pasteboard"])
            }
        }

        let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let legacyJSON = Data("""
        [{"id":"00000000-0000-0000-0000-000000000001","kind":"text",
          "text":"Legacy note","date":0,"pinned":true,"signature":"legacy"}]
        """.utf8)
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try legacyJSON.write(to: legacyURL)
        let legacyStore = ClipboardStore(pasteboard: pasteboard, historyURL: legacyURL)
        check(legacyStore.items.count == 1 && legacyStore.items.first?.id == legacyID
              && legacyStore.items.first?.pinned == true && legacyStore.items.first?.text == "Legacy note",
              "existing history decodes without new fields")
        check(legacyStore.items.first?.previewText == "Legacy note", "decoded history derives its preview")

        let ordinary = ClipItem(kind: .text, text: "  Ordinary note\n", signature: "normal")
        check(ordinary.previewText == "  Ordinary note\n" && ordinary.title == "Ordinary note",
              "ordinary preview preserves text while title trims whitespace")
        check(ordinary.footnote == "%ld characters · %ld lines".loc(16, 2),
              "ordinary multiline footnote preserves character and line counts")
        let smallUnicode = ClipItem(kind: .text, text: "e\u{301}👩🏽‍💻", signature: "unicode")
        check(smallUnicode.footnote == "%ld characters".loc(2), "small footnote counts graphemes, not scalars")
        check(ClipItem.preview("") == "", "empty preview stays empty")
        check(ClipItem.preview(String(repeating: "x", count: 2_048)) == String(repeating: "x", count: 2_048),
              "preview preserves the exact scalar limit")
        check(ClipItem.preview(String(repeating: "x", count: 2_049)) == String(repeating: "x", count: 2_047) + "…",
              "preview drops the last sampled grapheme above the scalar limit")
        for (name, prefixCount, cluster) in [
            ("combining mark", 2_047, "e\u{301}"),
            ("emoji joiner", 2_046, "👩🏽‍💻"),
            ("regional indicator", 2_047, "🇰🇷"),
        ] {
            let prefix = String(repeating: "x", count: prefixCount)
            check(ClipItem.preview(prefix + cluster + "tail") == prefix + "…",
                  "preview never exposes a partial \(name) at its boundary")
        }
        let atByteLimit = ClipItem(kind: .text, text: String(repeating: "x", count: 8_192), signature: "8192")
        let aboveByteLimit = ClipItem(kind: .text, text: String(repeating: "x", count: 8_193), signature: "8193")
        check(atByteLimit.footnote == "%ld characters".loc(8_192), "8192-byte footnote retains character counts")
        check(aboveByteLimit.footnote == ByteCountFormatter.string(fromByteCount: 8_193, countStyle: .file),
              "footnote switches to bytes above 8192 bytes")
        let shortLink = ClipItem(kind: .link, text: "https://example.com/path", signature: "link")
        check(shortLink.linkHost == "example.com" && shortLink.footnote == "example.com",
              "ordinary links retain host metadata")
        let smallColor = ClipItem(kind: .color, text: "#abc", signature: "color")
        check(smallColor.previewText == "#abc" && smallColor.footnote == "#abc" && smallColor.color != nil,
              "ordinary color preview and footnote remain unchanged")
        let urlPrefix = "https://example.com/"
        let boundaryLink = ClipItem(kind: .link, text: urlPrefix + String(repeating: "x", count: 8_192 - urlPrefix.utf8.count), signature: "boundary-link")
        check(boundaryLink.linkHost == "example.com", "link host is parsed at 8192 bytes")
        var oversizedLink = boundaryLink
        oversizedLink.text! += "x"
        check(oversizedLink.linkHost == nil && oversizedLink.footnote == "Link", "oversized link skips host parsing")
        check(ClipItem(kind: .text, text: "let value = 1;", signature: "code").looksLikeCode,
              "ordinary code still uses the code heuristic")
        check(!ClipItem(kind: .text, text: String(repeating: "x", count: 3_000) + "let value = 1;", signature: "tail-code").looksLikeCode,
              "code heuristic does not inspect text beyond the preview")
        check(!ClipItem(kind: .link, text: "https://example.com/{;}", signature: "not-code").looksLikeCode,
              "non-text items do not use the code heuristic")

        try publish("Present before initialization")
        let store = ClipboardStore(pasteboard: pasteboard, historyURL: historyURL)
        store.poll()
        check(store.items.isEmpty, "initial pasteboard contents are not captured as a new change")
        let smallCases: [(String, ClipItem.Kind)] = [
            ("Ordinary captured note", .text),
            ("https://example.com/path", .link),
            ("#abc", .color),
            ("#12abef", .color),
        ]
        var smallItems: [ClipItem] = []
        for (text, kind) in smallCases {
            try publish(text)
            store.poll()
            check(store.items.first?.kind == kind && sameBytes(store.items.first?.text, text),
                  "poll captures and classifies \(kind.rawValue): \(text)")
            guard let item = store.items.first else { continue }
            smallItems.append(item)
            store.copy(item)
            check(sameBytes(pasteboard.string(forType: .string), text), "copy preserves ordinary payload: \(text)")
            let snapshot = store.items
            store.poll()
            check(store.items == snapshot, "poll does not recapture our copy: \(text)")
        }
        if let original = smallItems.first {
            store.togglePin(original)
            let count = store.items.count
            try publish(original.text!)
            store.poll()
            check(store.items.first?.id == original.id && store.items.first?.pinned == true,
                  "external duplicate moves to top while retaining ID and pin")
            check(store.items.count == count, "external duplicate does not add another history row")
        }
        let beforeOwnWrite = store.items
        try publish("Explicit own write")
        store.markOwnWrite()
        store.poll()
        check(store.items == beforeOwnWrite, "markOwnWrite observes the injected pasteboard")
        try publish("After own write")
        store.poll()
        check(store.items.first?.text == "After own write", "a later external write is captured after markOwnWrite")

        let megabyte = 1_048_576
        let needle = "needle-beyond-preview"
        func megabyteText(pattern: String, prefix: String = "", suffix: String = "") -> String {
            let available = megabyte - prefix.utf8.count - suffix.utf8.count
            return prefix + String(repeating: pattern, count: available / pattern.utf8.count)
                + String(repeating: "x", count: available % pattern.utf8.count) + suffix
        }
        let fixtures = [
            ("base64-like", megabyteText(pattern: "aB7+/=", suffix: needle)),
            ("multilingual code", megabyteText(pattern: "let value = \"한글 👩🏽‍💻\";\n")),
            ("enormous grapheme", "é" + String(repeating: "\u{301}", count: 524_287)),
            ("oversized URL", megabyteText(pattern: "x", prefix: urlPrefix)),
        ]
        var largeItems: [ClipItem] = []
        for (name, text) in fixtures {
            let item = ClipItem(kind: .text, text: text, signature: name)
            check(item.title.utf8.count <= 8_195 && item.previewText.utf8.count <= 8_195
                  && item.previewText.hasSuffix("…"), "large title and preview stay bounded: \(name)")
            check(item.footnote == ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file),
                  "large footnote reports byte size: \(name)")
            let decoded = try JSONDecoder().decode(ClipItem.self, from: JSONEncoder().encode(item))
            check(sameBytes(decoded.text, text), "history round-trip preserves exact payload bytes: \(name)")
            try publish(text)
            store.poll()
            check(store.items.first?.kind == .text && sameBytes(store.items.first?.text, text),
                  "poll retains the full large payload as text: \(name)")
            guard let captured = store.items.first else { continue }
            largeItems.append(captured)
            store.copy(captured)
            check(sameBytes(pasteboard.string(forType: .string), text), "copy preserves every large payload byte: \(name)")
            store.copy(captured, plain: true)
            check(sameBytes(pasteboard.string(forType: .string), text), "plain copy preserves every large payload byte: \(name)")
            let snapshot = store.items
            store.poll()
            check(store.items == snapshot, "large copies are not recaptured: \(name)")
        }
        check(ClipItem.preview(fixtures[2].1) == "…", "a single enormous grapheme leaves only the truncation marker")
        check(ClipItem(kind: .color, text: fixtures[0].1, signature: "large-color").footnote.utf8.count <= 8_195,
              "legacy oversized color footnote is bounded")
        check(!ClipItem(kind: .text, text: fixtures[2].1, signature: "giant-code").looksLikeCode,
              "code heuristic handles a single enormous grapheme")
        if let large = largeItems.first {
            check(!large.previewText.contains(needle) && store.search(needle).map(\.id) == [large.id],
                  "search finds the original tail outside the preview")
            store.togglePin(large)
            check(store.search("  NEEDLE-BEYOND-PREVIEW  ", kind: .text, pinnedOnly: true).map(\.id) == [large.id],
                  "search combines normalized query, kind, and pin filters")
            check(store.search(needle, kind: .link).isEmpty, "kind filtering excludes a matching large text")
            let pinnedIDs = Set([smallItems.first?.id, large.id].compactMap { $0 })
            check(Set(store.search("", pinnedOnly: true).map(\.id)) == pinnedIDs,
                  "pinned filter returns exactly pinned history items")
            check(store.search("", kind: .link).map(\.id) == smallItems.filter { $0.kind == .link }.map(\.id),
                  "link filter excludes oversized URL text")
            if let pinnedLarge = store.items.first(where: { $0.id == large.id }) {
                store.copy(pinnedLarge)
            }
            check(store.items.first?.id == large.id && store.items.first?.pinned == true
                  && sameBytes(pasteboard.string(forType: .string), fixtures[0].1),
                  "copy moves an older large pinned item to the top without changing its payload")
        }

        let model = ClipboardViewModel(store: store)
        check(model.results.map(\.id) == store.items.map(\.id), "view model uses the injected store")
        model.move(10_000)
        check(model.selection == store.items.count - 1 && model.selected?.id == store.items.last?.id,
              "model movement clamps to the final result")
        model.move(-10_000)
        check(model.selection == 0 && model.selected?.id == store.items.first?.id,
              "model movement clamps to the first result")
        model.move(1)
        model.query = needle
        check(model.selection == 0 && model.results.map(\.id) == largeItems.prefix(1).map(\.id),
              "model query resets selection and searches beyond the preview")
        model.filter = .kind(.link)
        model.move(1)
        check(model.results.isEmpty && model.selected == nil && model.selection == 0,
              "model handles an empty filtered result")
        model.query = ""
        model.filter = .pinned
        check(model.results.count == 2 && model.results.allSatisfy(\.pinned), "model applies pinned filtering")
        model.filter = .all
        model.cycleFilter(backward: true)
        check(model.filter == .kind(.color), "model filter cycles backward with wraparound")
        model.cycleFilter()
        check(model.filter == .all, "model filter cycles forward with wraparound")

        let expected = store.items
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var saved = false
        repeat {
            if let data = try? Data(contentsOf: historyURL),
               let items = try? JSONDecoder().decode([ClipItem].self, from: data), items == expected {
                saved = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        } while clock.now < deadline
        check(saved, "asynchronous history save reaches the expected snapshot")
        let reloaded = ClipboardStore(pasteboard: pasteboard, historyURL: historyURL)
        check(reloaded.items == expected, "reload preserves history order, IDs, pins, and metadata")
        check(largeItems.count == fixtures.count && largeItems.enumerated().allSatisfy { index, item in
            sameBytes(reloaded.items.first(where: { $0.id == item.id })?.text, fixtures[index].1)
        }, "reload preserves every large payload byte")
        check(reloaded.search(needle).map(\.id) == largeItems.prefix(1).map(\.id),
              "reloaded history still searches beyond the preview")

        print("clipboard: \(passed) passed, \(failed) failed")
        print("history fixture: \(historyURL.path)")
        return failed
    }
}
