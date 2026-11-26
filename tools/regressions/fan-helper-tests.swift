import Foundation
@testable import Orbit

/// Checks when Orbit starts its privileged helper again from the current build.
@main struct FanHelperTests {
    static func main() {
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let unverified = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionCodeSigningRequirementFailure)
        let interrupted = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        check(FanControl.helperNeedsRestart(.failure(unverified)),
              "a helper whose binary was replaced by an update is started again")
        check(FanControl.helperNeedsRestart(.success(FanHelper.version - 1)), "an older helper is started again")
        check(!FanControl.helperNeedsRestart(.success(FanHelper.version)), "a current helper is left running")
        check(!FanControl.helperNeedsRestart(.failure(interrupted)), "an interrupted connection is left to launchd")
        check(!FanControl.helperNeedsRestart(nil), "a helper that didn't answer in time is left running")
        exit(failed == 0 ? 0 : 1)
    }
}
