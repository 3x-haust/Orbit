import Foundation
@testable import Orbit

@objc private protocol HelperHandshake {
    func version(reply: @escaping (Int) -> Void)
}

private final class RejectingHelper: NSObject, NSXPCListenerDelegate, HelperHandshake {
    func version(reply: @escaping (Int) -> Void) { reply(1) }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperHandshake.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
}

/// Checks when Orbit starts its privileged helper again from the current build.
@main struct FanHelperTests {
    static func main() async {
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
        check(FanControl.helperNeedsRestart(.failure(interrupted)),
              "a legacy helper rejecting the new app identity is replaced after an interrupted handshake")
        check(!FanControl.helperNeedsRestart(.success(FanHelper.version + 1)), "a newer helper is left running")
        let otherDomain = NSError(domain: "test.unrelated", code: NSXPCConnectionInterrupted)
        check(!FanControl.helperNeedsRestart(.failure(otherDomain)), "an unrelated error does not replace the helper")
        let invalid = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid)
        check(!FanControl.helperNeedsRestart(.failure(invalid)), "an invalid connection alone does not replace the helper")
        check(!FanControl.helperNeedsRestart(nil), "a helper that didn't answer in time is left running")

        // Reproduce the legacy listener rejecting a client with a different signing identity.
        // An anonymous endpoint keeps this independent of the installed privileged helper.
        let service = RejectingHelper()
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.setConnectionCodeSigningRequirement(#"identifier "com.lyu.orbit.regression.nonexistent""#)
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperHandshake.self)
        connection.resume()
        for attempt in 1...2 {
            let rejection: Error? = await withCheckedContinuation { done in
                let once = FanControl.Once<Error?>(done)
                let helper = connection.remoteObjectProxyWithErrorHandler { once.resume($0) } as? HelperHandshake
                helper?.version { _ in once.resume(nil) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once.resume(nil) }
            }
            check((rejection as NSError?)?.code == NSXPCConnectionInterrupted,
                  "rejected handshake \(attempt) on the same connection reports interruption")
            if let rejection {
                check(FanControl.helperNeedsRestart(.failure(rejection)),
                      "the real XPC rejection triggers replacement of the legacy helper")
            } else {
                check(false, "the real XPC rejection triggers replacement of the legacy helper")
            }
        }
        connection.invalidate()
        listener.invalidate()
        withExtendedLifetime(service) {}
        exit(failed == 0 ? 0 : 1)
    }
}
