import AppKit
import IOKit.pwr_mgt
import ScreenCaptureKit
@testable import Orbit

private actor DelayedRoom {
    private var continuation: CheckedContinuation<CGFloat, Never>?
    var started: Bool { continuation != nil }

    func measure() async -> CGFloat {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume(returning: 14)
        continuation = nil
    }
}

@MainActor private final class RecordingRooms {
    var measuredStates: [Recorder.State] = []

    func measure() -> CGFloat {
        let state = Recorder.shared.state
        measuredStates.append(state)
        return state == .idle ? 64 : 14
    }
}

/// Runs the real recorder, keep-awake service and notch windows in a separate process.
/// Only the menu-bar space measurement is fixed; recordings contain a blank test window.
@main struct NotchRecordingTests {
    @MainActor static func main() async throws {
        guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Expected an artifact directory and optional --screenshots") }
        let screenshots = CommandLine.arguments.dropFirst(2).contains("--screenshots")
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard CGPreflightScreenCaptureAccess(), let screen = NSScreen.main else {
            print("SKIP: a logged-in macOS desktop and Screen Recording permission are required")
            exit(2)
        }
        // This executable has its own defaults domain; don't start Orbit's app delegate/services.
        UserDefaults.standard.setVolatileDomain([
            NotchPrefs.enabled: true, NotchPrefs.liveAwake: true, NotchPrefs.liveRecording: true,
            NotchPrefs.liveMusic: false, NotchPrefs.liveTimer: true, NotchPrefs.liveFocus: false,
            NotchPrefs.liveCharging: false, NotchPrefs.liveDownloads: false, NotchPrefs.liveBluetooth: false,
            NotchPrefs.hoverOpen: false, NotchPrefs.hideFullScreen: false,
            Pref.awakeClosedLid: false, Pref.awakeBatteryFloor: 0, Pref.awakeThermal: false,
            Pref.recordCountdown: 0, Pref.recordMic: false, Pref.recordSystemAudio: false,
            Pref.recordOpen: "none"
        ], forName: UserDefaults.argumentDomain)
        NotchPrefs.register()
        let center = NotchCenter.shared, recorder = Recorder.shared, awake = KeepAwake.shared
        // Keep captures outside the spring's transition frames; state changes still use real views.
        NotchCenter.debugSpeed = 100
        center.debugRoom = { 64 }
        center.apply()
        let window = NSWindow(contentRect: NSRect(x: screen.frame.midX - 160, y: screen.frame.midY - 100,
                                                  width: 320, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .darkGray
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer {
            awake.stop()
            window.orderOut(nil)
        }
        let target = RecordTarget(kind: .window, screen: screen, frame: window.frame,
                                  windowID: CGWindowID(window.windowNumber))
        var failed = 0, passed = 0
        func check(_ value: Bool, _ name: String) {
            if value { passed += 1 } else { failed += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
            fflush(stdout)
        }
        func settle(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0..<100 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return condition()
        }
        func assertions() -> Set<UInt32> {
            var value: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess,
                  let entries = value?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
            return Set((entries[NSNumber(value: getpid())] ?? []).filter {
                ($0["AssertName"] as? String) == "Orbit Keep Awake"
            }.compactMap { ($0["AssertionId"] as? NSNumber)?.uint32Value })
        }
        func snapshot(_ name: String) async {
            guard screenshots else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let notch = NSApp.windows.first(where: { $0 is NotchWindow }),
                      let captured = content.windows.first(where: { Int($0.windowID) == notch.windowNumber }) else {
                    throw NSError(domain: "NotchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notch window unavailable"])
                }
                let filter = SCContentFilter(desktopIndependentWindow: captured)
                let config = SCStreamConfiguration()
                config.width = Int(notch.frame.width * 2)
                config.height = Int(notch.frame.height * 2)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("\(name).png"))
            } catch {
                check(false, "capture \(name): \(error)")
            }
        }
        func start() async -> Bool {
            recorder.start(target: target)
            var frame = 0
            return await settle {
                // ScreenCaptureKit emits no new frames for a still window. Change only gray
                // pixels so each fixture produces a real video without capturing user content.
                frame += 1
                window.backgroundColor = NSColor(white: frame.isMultiple(of: 2) ? 0.2 : 0.3, alpha: 1)
                window.displayIfNeeded()
                return recorder.isRecording && (recorder.startedAt.map { Date().timeIntervalSince($0) >= 1 } ?? false)
            }
        }
        func finish() async -> Bool {
            recorder.stop()
            let idle = await settle { recorder.state == .idle }
            check(QuickAccess.shared.items.count == 1, "stop delivers one recorded video")
            for capture in QuickAccess.shared.items {
                let destination = output.appendingPathComponent(UUID().uuidString + ".mp4")
                do { try FileManager.default.moveItem(at: capture.fileURL, to: destination) }
                catch { check(false, "preserve test recording: \(error)") }
            }
            QuickAccess.shared.debugClear()
            return idle
        }

        // Complete an older measurement after a newer one, even though it was cancelled.
        await center.debugRoomTask?.value
        let delayed = DelayedRoom()
        center.debugRoom = { await delayed.measure() }
        center.measureRooms(force: true)
        let olderMeasurement = center.debugRoomTask
        for _ in 0..<100 {
            if await delayed.started { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(await delayed.started, "older room measurement starts")
        center.debugRoom = { 64 }
        center.measureRooms(force: true)
        await center.debugRoomTask?.value
        check(center.room(on: center.primary) == 64, "newer room measurement completes first")
        await delayed.finish()
        await olderMeasurement?.value
        check(center.room(on: center.primary) == 64, "cancelled older measurement cannot overwrite newer room")
        center.measureRooms(force: true)
        await center.debugRoomTask?.value

        awake.start(.duration(600))
        let session = awake.session, startedAt = awake.startedAt, until = awake.until, held = assertions()
        check(!held.isEmpty, "keep-awake owns power assertions")
        check(await settle { center.phase(on: center.primary) == .ears(.awake) }, "awake initially visible")
        await snapshot("awake-before")
        check(await start(), "recording starts")
        check(await settle { center.phase(on: center.primary) == .ears(.recording) }, "recording takes priority")
        await snapshot("recording")

        // Recording's status item can shrink the available bar space below the ear threshold.
        let recordingRooms = RecordingRooms()
        center.debugRoom = { await recordingRooms.measure() }
        center.measureRooms(force: true)
        await center.debugRoomTask?.value
        check(center.currentEar == .recording && center.phase(on: center.primary) == .idle, "crowded bar hides the ear only")
        // Space stays crowded throughout finishing. Only a measurement after idle can restore it.
        check(await finish(), "recording stops")
        check(await settle { center.phase(on: center.primary) == .ears(.awake) }, "awake automatically restores after recording in a crowded bar")
        check(recordingRooms.measuredStates.contains(.finishing), "room is measured while recording teardown is still finishing")
        check(recordingRooms.measuredStates.contains(.idle), "room is measured again after recording teardown reaches idle")
        center.debugRoom = { 64 }
        print("STATE after stop: awake=\(awake.isOn) ear=\(String(describing: center.currentEar)) room=\(center.room(on: center.primary)) phase=\(center.phase(on: center.primary))")
        check(awake.isOn && awake.session == session && awake.startedAt == startedAt && awake.until == until,
              "recording preserves the original awake session and deadline")
        check(assertions() == held, "recording preserves the same OS power assertions")
        await snapshot("awake-after")

        // The fallback uses current activity state, not a saved copy of the pre-recording ear.
        check(await start(), "second recording starts")
        awake.stop()
        center.debugRoom = { 14 }
        center.measureRooms(force: true)
        await center.debugRoomTask?.value
        center.debugRoom = { 64 }
        check(await finish(), "second recording stops")
        check(await settle { center.currentEar == nil && center.phase(on: center.primary) == .idle }, "awake disabled during recording is not restored")
        check(!awake.isOn && assertions().isEmpty, "turning awake off releases its power assertions")
        await snapshot("awake-off")
        check(await start(), "recording starts with awake already off")
        check(await finish(), "recording with awake off stops")
        check(center.currentEar == nil && !awake.isOn && assertions().isEmpty, "recording never enables an inactive awake session")

        awake.start(.indefinite)
        NotchTimer.shared.start(minutes: 10)
        check(center.currentEar == .timer, "timer retains priority over awake")
        check(await start(), "recording with timer starts")
        check(center.currentEar == .recording, "recording retains priority over timer")
        center.debugRoom = { 14 }
        center.measureRooms(force: true)
        await center.debugRoomTask?.value
        center.debugRoom = { 64 }
        recorder.discard()
        check(await settle { recorder.state == .idle && center.phase(on: center.primary) == .ears(.timer) }, "discard restores the active timer")
        NotchTimer.shared.stop()
        check(await settle { center.phase(on: center.primary) == .ears(.awake) }, "ending timer restores awake")
        awake.stop()
        window.orderOut(nil)
        print("notch-recording-tests: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
