#!/usr/bin/env python3
"""Exercise the production quit delegate and KeepAwake in a real AppKit run loop.

Only the privileged helper, admin prompt and other Orbit services are substituted.
No installed app preferences or system sleep settings are changed.
"""
import argparse
import json
import os
import pathlib
import plistlib
import shlex
import signal
import subprocess
import sys
import tempfile
import time

MODES = ["normal", "lid", "system", "fallback", "failure", "version-timeout", "reply-timeout", "external", "window", "duplicate", "restart-normal", "restart-lid", "toggle-on", "toggle-off"]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("modes", nargs="*", help="Run only these scenarios: " + ", ".join(MODES))
args = parser.parse_args()
if any(mode not in MODES for mode in args.modes):
    parser.error("unknown scenario")

ROOT = pathlib.Path(__file__).resolve().parents[2]
source = (ROOT / "Orbit/App/OrbitApp.swift").read_text()
start = source.index("    func applicationShouldTerminate(")
end = source.index("\n    /// Clicking Orbit", start)
method = source[start:end]
fan_source = (ROOT / "Orbit/Modules/Fans/FanControl.swift").read_text()
helper_start = fan_source.index("    func setSleepDisabled(")
helper_end = fan_source.index("\n    /// The running helper", helper_start)
helper = fan_source[helper_start:helper_end].replace("NSXPCConnection", "TestConnection").replace("NSXPCInterface(with: FanHelperProtocol.self)", "0")
once_start = fan_source.index("    final class Once<")
once_end = fan_source.index("\n    private func proxy()", once_start)
once = fan_source[once_start:once_end]
proxy = fan_source[once_end:fan_source.rindex("\n}")].replace("NSXPCConnection", "TestConnection").replace("NSXPCInterface(with: FanHelperProtocol.self)", "0")
shared_proxy_start = fan_source.index("    func helperProxy()")
shared_proxy_end = fan_source.index("\n    /// Blocks for at most", shared_proxy_start)
shared_proxy = fan_source[shared_proxy_start:shared_proxy_end]
updater_source = (ROOT / "Orbit/Core/Updater.swift").read_text()
relaunch_start = updater_source.index("    private func relaunch(")
relaunch_end = updater_source.index("\n}\n", relaunch_start)
relaunch = updater_source[relaunch_start:relaunch_end]

harness = r'''
import AppKit
import IOKit.pwr_mgt
func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
let mode = CommandLine.arguments[1]
@MainActor enum Pref {
    static let defaults = UserDefaults(suiteName: "orbit-quit-regression-\(getpid())")!
    static let awakeDisplay = "display", awakeClosedLid = "lid", awakeBatteryFloor = "floor"
    static let awakeThermal = "thermal", awakeLidOwned = "owned"
}
extension String {
    var loc: String { self }
    func loc(_ args: CVarArg...) -> String { String(format: self, arguments: args) }
}
@MainActor enum Toast {
    static func show(_ text: String, symbol: String, detail: String? = nil) { log("toast: \(text)") }
}
enum Battery { static func read() -> (onAC: Bool, percent: Int)? { nil } }
enum FanHelper { static let label = "test", helperRequirement = "test" }
protocol FanHelperProtocol {
    func version(reply: @escaping (Int) -> Void)
    func setSleepDisabled(_ on: Bool, reply: @escaping (String?) -> Void)
}
final class TestConnection {
    enum Options { case privileged }
    static var created = 0, invalidated = 0
    var remoteObjectInterface = 0
    var invalidationHandler: (() -> Void)?
    init(machServiceName: String, options: Options) { Self.created += 1 }
    func setCodeSigningRequirement(_ requirement: String) {}
    func resume() {}
    func invalidate() {
        Self.invalidated += 1
        // The helper releases every fan and clears the discharge target on disconnect.
        TestHelper.shared.fanRPM = nil
        TestHelper.shared.dischargeTarget = 0
        invalidationHandler?()
    }
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
        TestHelper.shared
    }
}
final class TestHelper: FanHelperProtocol {
    static let shared = TestHelper()
    var fanRPM: Int? = 2400
    var dischargeTarget = 40
    func version(reply: @escaping (Int) -> Void) {
        if mode == "version-timeout" && restoring { return }
        DispatchQueue.global().async { reply(2) }
    }
    func setSleepDisabled(_ on: Bool, reply: @escaping (String?) -> Void) {
        log("helper \(on ? "on" : "off") started")
        if !on && mode == "reply-timeout" { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            log("helper \(on ? "on" : "off") finished")
            reply(!on && ["fallback", "failure"].contains(mode) ? "unavailable" : nil)
        }
    }
}
// Set before entering termination; helper reads only after the detached task starts.
var restoring = false
enum Shell {
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        (0, mode == "external" ? "SleepDisabled 1" : "SleepDisabled 0")
    }
    static func runAsAdmin(_ command: String, prompt: String) async -> Bool {
        log("admin restore")
        try? await Task.sleep(for: .milliseconds(30))
        return mode != "failure"
    }
}
@MainActor final class FanControl {
    static let shared = FanControl()
    enum State { case ready }
    var helper: State = .ready
    private var connection: TestConnection?
    var lastError: String?
    func refresh() {}
''' + helper + once + proxy + "\n" + shared_proxy + r'''
}
@MainActor enum AppQuit {
    static var confirmed = mode != "window" && mode != "system"
    static var systemIsEnding = mode == "system"
    static func now() { confirmed = true; NSApp.terminate(nil) }
}
@MainActor final class MainWindow {
    static let shared = MainWindow()
    var isOpen = mode == "window" || mode == "system"
    func close() { isOpen = false; log("window closed") }
}
@MainActor enum OrbitInstance { static var ready = true }
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var duplicateInstance = mode == "duplicate"
    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.defaults.setVolatileDomain([
            Pref.awakeClosedLid: !["normal", "restart-normal", "window", "duplicate"].contains(mode),
            Pref.awakeBatteryFloor: 0, Pref.awakeThermal: false
        ], forName: UserDefaults.argumentDomain)
        Task { @MainActor in
            if mode.hasPrefix("toggle-") {
                guard FanControl.shared.helperProxy() != nil else { exit(6) }
                let result = await FanControl.shared.setSleepDisabled(mode == "toggle-on")
                guard result == true, TestConnection.created == 1, TestConnection.invalidated == 0,
                      TestHelper.shared.fanRPM == 2400, TestHelper.shared.dischargeTarget == 40 else {
                    log("FAIL lid toggle reset fan/discharge: connections=\(TestConnection.created), invalidated=\(TestConnection.invalidated), fan=\(String(describing: TestHelper.shared.fanRPM)), discharge=\(TestHelper.shared.dischargeTarget)")
                    exit(6)
                }
                log("lid toggle preserved connection, fan and discharge")
                exit(0)
            }
            if !duplicateInstance { KeepAwake.shared.start(.indefinite) }
            if !["normal", "restart-normal", "window", "duplicate", "external"].contains(mode) {
                while !KeepAwake.shared.closedLidActive { await Task.yield() }
            } else if mode == "external" {
                while !KeepAwake.shared.lidDisabledElsewhere { await Task.yield() }
            }
            // Updater/relaunch termination runs on the main dispatch queue.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                MainActor.assumeIsolated {
                    log("request termination")
                    restoring = true
                    if mode.hasPrefix("restart-") {
                        self.relaunch(URL(fileURLWithPath: CommandLine.arguments[2]))
                    } else {
                        NSApp.terminate(nil)
                    }
                    if mode == "window" {
                        guard !MainWindow.shared.isOpen, OrbitInstance.ready,
                              KeepAwake.shared.isOn else { exit(3) }
                        log("window-only quit preserved")
                        Pref.defaults.removePersistentDomain(forName: "orbit-quit-regression-\(getpid())")
                        exit(0)
                    }
                }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        log("will terminate")
        if !["normal", "restart-normal", "duplicate", "external"].contains(mode) {
            let expectedOwned = mode == "failure"
            guard KeepAwake.shared.closedLidActive == expectedOwned,
                  Pref.defaults.bool(forKey: Pref.awakeLidOwned) == expectedOwned,
                  Pref.defaults.dictionary(forKey: "awake.resume")?["kind"] as? String == "indefinite"
            else { log("FAIL restoration or resume state"); exit(4) }
            var value: Unmanaged<CFDictionary>?
            _ = IOPMCopyAssertionsByProcess(&value)
            let entries = value?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
            let owned = (entries?[NSNumber(value: getpid())] ?? []).filter {
                ($0["AssertName"] as? String) == "Orbit Keep Awake"
            }
            guard owned.isEmpty else { log("FAIL assertions not released"); exit(5) }
            log("restoration and resume state preserved")
        }
        Pref.defaults.removePersistentDomain(forName: "orbit-quit-regression-\(getpid())")
    }
''' + method + relaunch + r'''
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = Delegate()
    app.delegate = delegate
    app.run()
}
'''

with tempfile.TemporaryDirectory(prefix="orbit-quit-tests-") as tmp:
    work = pathlib.Path(tmp)
    (work / "main.swift").write_text(harness)
    binary = work / "quit-tests"
    subprocess.run([
        "swiftc", "-swift-version", "5", str(ROOT / "Orbit/Core/KeepAwake.swift"),
        str(work / "main.swift"), "-o", str(binary)
    ], check=True)
    marker = work / "relaunched"
    app = work / "QuitMarker.app"
    executable = app / "Contents/MacOS/QuitMarker"
    executable.parent.mkdir(parents=True)
    executable.write_text("#!/bin/sh\n/usr/bin/touch " + shlex.quote(str(marker)) + "\n")
    executable.chmod(0o755)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "QuitMarker", "CFBundleIdentifier": "com.lyu.orbit.quit-regression",
        "CFBundlePackageType": "APPL", "LSBackgroundOnly": True,
    }))
    results = []
    for mode in args.modes or MODES:
        try:
            marker.unlink(missing_ok=True)
            log_path = work / (mode + ".log")
            with log_path.open("w") as output:
                process = subprocess.Popen([str(binary), mode, str(app)], stdout=output, stderr=output, start_new_session=True)
                code = process.wait(timeout=8)
            # Reap the app before waiting for its relaunch shell; kill -0 sees zombies too.
            run = subprocess.CompletedProcess([], code, log_path.read_text(), "")
            ok = run.returncode == 0 and ("will terminate" in run.stdout or mode == "window")
            if mode.startswith("toggle-"):
                ok = run.returncode == 0 and "lid toggle preserved connection, fan and discharge" in run.stdout
            if mode in ["lid", "system", "fallback", "failure", "restart-lid"]:
                ok = ok and "helper off finished" in run.stdout and "restoration and resume state preserved" in run.stdout
            if mode in ["version-timeout", "reply-timeout"]:
                ok = ok and "admin restore" in run.stdout and "restoration and resume state preserved" in run.stdout
            if mode == "external":
                ok = ok and "helper off" not in run.stdout
            if mode.startswith("restart-"):
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                ok = ok and marker.exists()
            result = dict(mode=mode, ok=ok, exit=run.returncode, output=run.stdout, stderr=run.stderr)
            if mode.startswith("restart-"):
                result["relaunched"] = marker.exists()
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            result = dict(mode=mode, ok=False, timedOut=True, output=log_path.read_text())
        results.append(result)
        print(json.dumps(result), flush=True)
    sys.exit(0 if all(result["ok"] for result in results) else 1)
