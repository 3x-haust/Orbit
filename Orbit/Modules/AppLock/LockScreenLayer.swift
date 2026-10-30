import AppKit

/// Puts a window on top of the lock screen. No public API does: the lock screen hides every app
/// window. Like Glance (and Lakr233/SkyLightWindow, both MIT), this makes a window-server space at
/// the level Notification Center uses while locked and moves the window into it. These are private
/// SkyLight calls; if any is missing, `shared` is nil and the lock screen just shows nothing.
@MainActor
final class LockScreenLayer {
    static let shared = LockScreenLayer()

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows
    private let removeWindows: RemoveWindows
    private var lifted: Set<Int> = []

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let main = dlsym(handle, "SLSMainConnectionID"),
              let create = dlsym(handle, "SLSSpaceCreate"),
              let level = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let show = dlsym(handle, "SLSShowSpaces"),
              let add = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
              let remove = dlsym(handle, "SLSRemoveWindowsFromSpaces") else {
            AppLockLog.write("lock screen: SkyLight isn't available, nothing will show there")
            return nil
        }
        connection = unsafeBitCast(main, to: MainConnection.self)()
        // Flag 1: any other value has Finder draw the desktop icons into the space.
        space = unsafeBitCast(create, to: SpaceCreate.self)(connection, 1, 0)
        // 400: where Notification Center draws over the lock screen.
        _ = unsafeBitCast(level, to: SpaceSetLevel.self)(connection, space, 400)
        _ = unsafeBitCast(show, to: ShowSpaces.self)(connection, [space] as CFArray)
        addWindows = unsafeBitCast(add, to: AddWindows.self)
        removeWindows = unsafeBitCast(remove, to: RemoveWindows.self)
    }

    /// Shows `window` over the lock screen. Only while locked: in the space it sits above everything.
    func lift(_ window: NSWindow) {
        guard window.windowNumber > 0, !lifted.contains(window.windowNumber) else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        lifted.insert(window.windowNumber)
    }

    /// Back to an ordinary window, as soon as the Mac unlocks.
    func lower(_ window: NSWindow) {
        guard lifted.remove(window.windowNumber) != nil else { return }
        _ = removeWindows(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
