import AppKit
import ScreenCaptureKit

/// Barbee rearranges the menu bar without the bar ever visibly churning. Orbit has to ⌘-drag icons,
/// open macOS's « overflow and unfold its dividers to do the same, so while it works it lays a still
/// picture of the menu bar over the real one — clicks and drags pass straight through it — and fades
/// it away once the bar has settled into its new layout.
@MainActor
enum MenuBarFreeze {
    private static var panel: NSPanel?
    private static var imageView: NSImageView?
    private static var holds = 0
    private static var releaseWork: DispatchWorkItem?

    /// Photographs the bar as it looks now and covers it. Nested holds share one picture.
    static func hold() async {
        holds += 1
        releaseWork?.cancel()
        releaseWork = nil
        if let panel, panel.isVisible { return }
        guard let screen = NSScreen.screens.first, let image = await snapshot(screen) else { return }
        // Released while the picture was being taken.
        guard holds > 0 else { return }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        let rect = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
        let p = panel ?? make()
        imageView?.image = image
        p.setFrame(rect, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
    }

    /// Lets go once the bar has had a moment to settle, then fades the picture out.
    static func release(after delay: TimeInterval = 0.35) {
        holds = max(0, holds - 1)
        guard holds == 0, let panel, panel.isVisible else { return }
        releaseWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard holds == 0, let panel = MenuBarFreeze.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { if holds == 0 { panel.orderOut(nil) } }
                })
            }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the « patch, below menus and the hidden-icons bar's level doesn't matter (it's lower down).
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary] // out of Mission Control
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.animationBehavior = .none
        p.sharingType = .none // never in Orbit's own captures of the bar
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        p.contentView = view
        imageView = view
        panel = p
        return p
    }

    private static func snapshot(_ screen: NSScreen) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return nil }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: height)
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(height * screen.backingScaleFactor)
        config.showsCursor = false
        // Everything but Orbit's open windows below the bar (the hidden-icons bar sits under it anyway).
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: screen.frame.width, height: height))
    }
}
