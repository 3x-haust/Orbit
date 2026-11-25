#!/usr/bin/env python3
"""Run production helper recovery with isolated service/XPC stand-ins, without launching Orbit."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "Orbit/Modules/Fans/FanControl.swift").read_text()
startup = source[source.index("    func start() {"):source.index("    func installHelper() {")]
version = source[source.index("    func helperVersion() async"):source.index("    /// The helper for other privileged features")]
removal = source[source.index("    func removeHelper() {"):source.index("    /// Ring / launcher")]
connection = source[source.index("    final class Once<"):source.rindex("\n}")]
production = (startup + version + removal + connection).replace("NSXPCConnection", "TestConnection").replace(
    "NSXPCInterface(with: FanHelperProtocol.self)", "0")
# Error constants are Foundation constants, not connection type names.
production = production.replace("TestConnectionInterrupted", "NSXPCConnectionInterrupted").replace(
    "TestConnectionCodeSigningRequirementFailure", "NSXPCConnectionCodeSigningRequirementFailure")

harness = r'''
import Foundation
let mode = CommandLine.arguments[1]
enum FanHelper { static let version = 4, label = "test", helperRequirement = "test" }
protocol FanHelperProtocol { func version(reply: @escaping (Int) -> Void) }
@MainActor enum Toast { static func show(_ text: String, symbol: String, detail: String) {} }
final class TestService {
    enum Status { case enabled, requiresApproval, notRegistered, notFound }
    static var state: Status = .enabled
    static var upgraded = false, registrations = 0, unregistrations = 0
    var status: Status { Self.state }
    func unregister() async throws {
        Self.unregistrations += 1
        if mode == "stale-enabled" { throw NSError(domain: "test.unregister", code: 1) }
        Self.state = .notRegistered
    }
    func register() throws {
        Self.registrations += 1
        if mode == "stale-enabled" { throw NSError(domain: "test.register", code: 2) }
        Self.upgraded = true
        Self.state = mode == "approval" ? .requiresApproval : .enabled
    }
}
final class TestProxy: FanHelperProtocol {
    static var probes = 0
    let error: (Error) -> Void
    init(_ error: @escaping (Error) -> Void) { self.error = error }
    func version(reply: @escaping (Int) -> Void) {
        Self.probes += 1
        if mode == "timeout" { return }
        if TestService.upgraded || mode == "current" || (mode == "transient" && Self.probes > 1) {
            reply(4)
        } else if mode == "older" {
            reply(3)
        } else {
            error(NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted))
        }
    }
}
final class TestConnection {
    enum Options { case privileged }
    static var invalidations = 0
    var remoteObjectInterface = 0
    var invalidationHandler: (() -> Void)?
    init(machServiceName: String, options: Options) {}
    func setCodeSigningRequirement(_ text: String) {}
    func resume() {}
    func invalidate() {
        Self.invalidations += 1
        // Deliver an old invalidation late, after replacement verification starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.invalidationHandler?() }
    }
    func remoteObjectProxyWithErrorHandler(_ error: @escaping (Error) -> Void) -> Any { TestProxy(error) }
}
@MainActor final class FanControl {
    static let shared = FanControl()
    enum HelperState { case ready, needsApproval, off }
    enum Mode { case auto }
    var mode: Mode = .auto
    var helper: HelperState = .ready
    var lastError: String?
    let service = TestService()
    var connection: TestConnection?
    var upgrade: Task<Bool, Never>?
    func apply() {}
''' + production + r'''
}
@main struct Tests {
    @MainActor static func main() async {
        let control = FanControl.shared
        control.start()
        if mode == "removal" {
            try? await Task.sleep(for: .milliseconds(600))
            control.removeHelper()
            try? await Task.sleep(for: .seconds(1))
            guard TestService.registrations == 0, TestService.state == .notRegistered else {
                fatalError("recovery reversed explicit helper removal")
            }
            print("PASS removal")
            return
        }
        // This is the battery's startup path; it must wait for replacement before probing.
        let version = await control.helperVersion()
        let recovered = await control.upgrade?.value
        switch mode {
        case "current", "transient":
            guard recovered == true, version == 4, TestService.registrations == 0,
                  TestConnection.invalidations == 0 else { fatalError("healthy helper was replaced") }
        case "legacy", "older":
            guard recovered == true, version == 4, TestService.unregistrations == 1,
                  TestService.registrations == 1, control.lastError == nil else {
                fatalError("battery did not wait for verified replacement")
            }
            let replacement = control.connection
            try? await Task.sleep(for: .seconds(1))
            guard replacement != nil, control.connection === replacement else {
                fatalError("late invalidation cleared the replacement")
            }
        case "stale-enabled":
            guard recovered == false, version == nil, TestService.registrations == 3,
                  control.lastError?.contains("test.unregister") == true else {
                fatalError("stale enabled service was reported as repaired or lost its registration error")
            }
        case "approval":
            guard recovered == false, version == nil, control.helper == .needsApproval else {
                fatalError("approval was reported as a working helper")
            }
            TestService.state = .enabled
            guard await control.helperVersion() == 4 else { fatalError("approval did not recover without relaunch") }
        case "timeout":
            guard recovered == false, version == nil, TestService.registrations == 0 else {
                fatalError("slow helper was replaced")
            }
        default: fatalError("unknown scenario")
        }
        print("PASS \(mode)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="orbit-helper-startup-") as scratch:
    path = pathlib.Path(scratch)
    swift = path / "tests.swift"
    swift.write_text(harness)
    binary = path / "tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    for mode in ["current", "transient", "legacy", "older", "stale-enabled", "approval", "timeout", "removal"]:
        subprocess.run([str(binary), mode], check=True, timeout=12)
