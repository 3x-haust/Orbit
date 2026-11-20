import Carbon
@testable import Orbit

/// Checks Orbit's Tavi state against what Text Input Sources reports on this Mac.
@main struct TaviTests {
    @MainActor static func main() {
        let filter = [kTISPropertyInputSourceID as String: TaviBridge.inputMethodID] as CFDictionary
        guard let source = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first,
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else {
            print("SKIP Tavi is not registered on this Mac")
            exit(2)
        }
        let enabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
        let tavi = TaviBridge.shared
        tavi.refresh()
        print("TIS enabled=\(enabled) isAdded=\(tavi.isAdded) status=\(tavi.status)")
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        check(tavi.isAdded == enabled, "#60 added state matches the enabled input source")
        if enabled { check(tavi.status != .needsAdding, "#60 an enabled Tavi isn't asked to be added again") }
        exit(failed == 0 ? 0 : 1)
    }
}
