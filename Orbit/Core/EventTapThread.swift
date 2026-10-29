import CoreGraphics
import Foundation

/// Runs an event tap on a thread of its own. On the main run loop every event the tap watches — for a
/// keyboard tap, every key press on the Mac — waits for whatever Orbit's main thread is busy with.
/// Callbacks on this thread pass events on right away and hop to the main thread only for the few
/// they actually act on.
final class EventTapThread: @unchecked Sendable {
    let port: CFMachPort
    private let source: CFRunLoopSource
    private var loop: CFRunLoop?

    init(port: CFMachPort, name: String) {
        self.port = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var runLoop: CFRunLoop?
        let source = source
        let thread = Thread {
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        loop = runLoop
    }

    /// For the timeout and user-input notices, which switch a tap off.
    func reenable() { CGEvent.tapEnable(tap: port, enable: true) }

    func stop() {
        CGEvent.tapEnable(tap: port, enable: false)
        guard let loop else { return }
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(port)
        CFRunLoopStop(loop)
        self.loop = nil
    }
}
