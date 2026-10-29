import AppKit
import SwiftUI

/// The strip under the menu bar showing hidden (and always-hidden) items as they really look.
/// Clicking one unfolds the menu bar for a moment and opens that item's menu.
@MainActor @Observable
final class HiddenBar {
    static let shared = HiddenBar()

    var isVisible: Bool { panel.isVisible }

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var anchor: NSRect = .zero
    @ObservationIgnored private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(contentRect: .zero, focusable: false)
        p.level = .statusBar
        p.setContent(HiddenBarView(bar: self))
        return p
    }()

    var items: [MenuBarItems.Item] {
        // Hidden sections, plus anything macOS tucked behind its « button for lack of room.
        MenuBarItems.shared.items.filter { ($0.section != .visible || !$0.shown) && $0.mobility != .visibleOnly }
    }

    func show(below anchor: NSRect) {
        self.anchor = anchor
        let model = MenuBarItems.shared
        // Open straight away with what Orbit already knows; fresh pictures fill in a moment later.
        present()
        // Reading the menu bar runs on the main thread and would stall the slide-in, so wait for the
        // animation — and skip it entirely if Orbit looked a moment ago.
        guard Date().timeIntervalSince(model.snapshotAt) > 8 || !model.hasSnapshot else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard panel.isVisible else { return }
            // Unfold quietly only the very first time. On a full menu bar unfolding can't bring every
            // icon into view anyway (macOS keeps some behind its «), and the bar visibly jumping on
            // every click is worse than an app icon standing in for a missing picture.
            await model.refresh(reveal: !model.hasSnapshot)
            if panel.isVisible { relayout() }
        }
    }

    /// Resizes the open strip to fit (or opens it, the first time).
    private func relayout() {
        guard panel.isVisible else { present(); return }
        let f = frame()
        panel.setFrame(f, display: true, animate: true)
    }

    private func frame() -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.active
        let content = items.reduce(CGFloat(0)) { $0 + HiddenItemButton.width(for: $1) + 2 }
        let width = max(220, min(screen.frame.width - 16, content + 20))
        let height: CGFloat = items.isEmpty ? 64 : 36
        let menuBarBottom = screen.visibleFrame.maxY
        // Like Barbee: tucked right up under the menu bar, its right end lined up with the screen's
        // right edge (where the status icons live), however far left the button is.
        var x = screen.frame.maxX - width - 8
        x = max(screen.frame.minX + 8, x)
        return NSRect(x: x, y: menuBarBottom - height - 1, width: width, height: height)
    }

    private func present() {
        // Straight in, no slide: it should feel like part of the menu bar.
        let f = frame()
        panel.setFrame(f, display: false)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = 1 }
        }
        MenuBarHider.shared.updateToggleImage()
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                MainActor.assumeIsolated { HiddenBar.shared.hide() }
            }
        }
    }

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.dismiss()
        // After the fade-out, once the panel really reports hidden.
        for delay in [0.05, 0.35] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MenuBarHider.shared.updateToggleImage() } }
    }

    func open(_ item: MenuBarItems.Item) {
        hide()
        MenuBarHider.shared.openHidden(item)
    }
}

private struct HiddenBarView: View {
    let bar: HiddenBar

    var body: some View {
        Group {
            if bar.items.isEmpty {
                VStack(spacing: 2) {
                    Text("Nothing hidden yet").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Hold ⌘ and drag icons left of the divider").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                }
            } else {
                ScrollView(.horizontal) {
                    // Same rhythm as the menu bar itself.
                    HStack(spacing: 2) {
                        ForEach(bar.items) { HiddenItemButton(item: $0) { bar.open($0) } }
                    }
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // See-through like the menu bar itself (macOS 26 glass), not a solid panel.
        .orbitGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One item as the menu bar shows it, with nothing behind it: the real picture with the bar
/// background cut away, or — for items macOS keeps behind the notch, which can't be photographed —
/// the app's icon at menu bar size.
struct MenuBarItemImage: View {
    let item: MenuBarItems.Item

    var body: some View {
        if item.id == MenuBarItems.toggleID,
           let symbol = MenuBarHider.image(for: Pref.defaults.string(forKey: Pref.hiderIcon) ?? "sparkle", collapsed: true) {
            // Orbit's own button, drawn from its symbol: it's often tucked behind « where it can't be photographed.
            Image(nsImage: symbol).renderingMode(.template)
                .foregroundStyle(Palette.ink)
                .frame(width: max(22, symbol.size.width + 6), height: 22)
        } else if let image = item.image, let cut = Cutout.image(from: image) {
            Image(nsImage: cut).interpolation(.high)
                .frame(width: cut.size.width, height: cut.size.height)
        } else {
            Image(nsImage: item.appIcon).resizable().interpolation(.high)
                .frame(width: 22, height: 22)
                .padding(.horizontal, 3)
        }
    }
}

/// Removes the menu bar background from a snapshot of one item, keeping the icon's own colors.
/// Menu bar glyphs are drawn white on a dark or tinted bar (black on a light one), while the
/// wallpaper showing through the bar is mid-tone and colorful — so a pixel's alpha is how much
/// whiter (or blacker) than the brightest (darkest) edge pixels it is.
@MainActor
enum Cutout {
    private static var cache: [ObjectIdentifier: NSImage] = [:]

    static func image(from image: NSImage) -> NSImage? {
        if let cached = cache[ObjectIdentifier(image)] { return cached }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 2, h > 2 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lo(_ i: Int) -> Double { Double(min(px[i], px[i + 1], px[i + 2])) / 255 }
        func hi(_ i: Int) -> Double { Double(max(px[i], px[i + 1], px[i + 2])) / 255 }
        var edge: [Int] = []
        for y in 0..<h { edge += [(y * w) * 4, (y * w + w - 1) * 4] }
        for x in 0..<w { edge += [x * 4, ((h - 1) * w + x) * 4] }
        let lum = edge.map { (lo($0) + hi($0)) / 2 }.sorted()
        let darkBar = lum[lum.count / 2] < 0.6
        // The background's extreme: anything past it is the icon.
        let floor = darkBar ? edge.map(lo).sorted()[edge.count * 95 / 100] : edge.map(hi).sorted()[edge.count * 5 / 100]
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = darkBar ? (lo(i) - floor) / max(0.1, 1 - floor) : (floor - hi(i)) / max(0.1, floor)
            let alpha = max(0, min(1, a * 1.25))
            if alpha < 0.05 { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0; px[i + 3] = 0; continue }
            // Pixels are opaque in the snapshot; premultiply their color by the new alpha.
            for k in 0..<3 { px[i + k] = UInt8(Double(px[i + k]) * alpha) }
            px[i + 3] = UInt8(alpha * 255)
        }
        guard let out = ctx.makeImage() else { return nil }
        let result = NSImage(cgImage: out, size: image.size)
        cache[ObjectIdentifier(image)] = result
        return result
    }
}

private struct HiddenItemButton: View {
    let item: MenuBarItems.Item
    let tap: (MenuBarItems.Item) -> Void
    @State private var hovering = false

    static func width(for item: MenuBarItems.Item) -> CGFloat { (item.image?.size.width ?? 28) + 6 }

    var body: some View {
        Button { tap(item) } label: {
            MenuBarItemImage(item: item)
                .frame(width: Self.width(for: item), height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.raised : .clear))
                .overlay(alignment: .bottomTrailing) {
                    if item.section == .always {
                        Circle().fill(Palette.inkSecondary).frame(width: 4, height: 4).offset(x: -2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(item.name)
        .onHover { h in withAnimation(.spring(duration: 0.2, bounce: 0.3)) { hovering = h } }
    }
}
