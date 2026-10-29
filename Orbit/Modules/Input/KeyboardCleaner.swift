import AppKit
import SwiftUI

/// Wipe-the-keyboard mode: every key press — media and brightness keys too — is swallowed while a
/// calm overlay is up. Only the pointer ends it (the trackpad keeps working). The tap lives in this
/// process, so it can never outlive Orbit; a timer ends it after five minutes no matter what.
@MainActor @Observable
final class KeyboardCleaner {
    static let shared = KeyboardCleaner()

    /// Seconds; 0 waits for the button.
    static let durations: [Int] = [30, 60, 0]
    private static let durationKey = "keyboardClean.duration"
    private static let safetyLimit: TimeInterval = 5 * 60

    private(set) var active = false
    private(set) var endsAt: Date?
    var duration: Int {
        didSet {
            Pref.defaults.set(duration, forKey: Self.durationKey)
            if active { schedule() }
        }
    }

    /// On its own thread, so swallowing keys never waits on the main thread.
    nonisolated(unsafe) fileprivate static var live: EventTapThread?
    private var panels: [NSPanel] = []
    private var endTimer: Timer?
    private var safetyTimer: Timer?

    private init() {
        duration = Pref.defaults.object(forKey: Self.durationKey) as? Int ?? 60
    }

    func start() {
        guard !active else { return }
        guard AXIsProcessTrusted(), installTap() else {
            Toast.show("Orbit needs Accessibility to block the keyboard", symbol: "lock.shield")
            MainWindow.show(.setup)
            return
        }
        active = true
        showOverlay()
        schedule()
        let safety = Timer(timeInterval: Self.safetyLimit, repeats: false) { _ in MainActor.assumeIsolated { KeyboardCleaner.shared.stop() } }
        RunLoop.main.add(safety, forMode: .common)
        safetyTimer = safety
        ScrollLog.write("keyboard cleaning on")
    }

    func stop() {
        guard active else { return }
        active = false
        endsAt = nil
        endTimer?.invalidate(); endTimer = nil
        safetyTimer?.invalidate(); safetyTimer = nil
        removeTap()
        for p in panels {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        panels = []
        Toast.show("Keyboard is back", symbol: "keyboard")
        ScrollLog.write("keyboard cleaning off")
    }

    private func schedule() {
        endTimer?.invalidate(); endTimer = nil
        guard duration > 0 else { endsAt = nil; return }
        endsAt = Date().addingTimeInterval(TimeInterval(duration))
        let t = Timer(timeInterval: TimeInterval(duration), repeats: false) { _ in MainActor.assumeIsolated { KeyboardCleaner.shared.stop() } }
        RunLoop.main.add(t, forMode: .common)
        endTimer = t
    }

    // MARK: Tap

    private func installTap() -> Bool {
        // keyDown, keyUp, flagsChanged, and NX_SYSDEFINED (14) for media, volume and brightness keys.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue) | (1 << 14)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyboardCallback, userInfo: nil) else { return false }
        Self.live = EventTapThread(port: tap, name: "Orbit keyboard cleaning")
        return true
    }

    private func removeTap() {
        Self.live?.stop()
        Self.live = nil
    }

    // MARK: Overlay

    private func showOverlay() {
        for (i, screen) in NSScreen.screens.enumerated() {
            let panel = CleanerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            let host = FirstMouseHostingView(rootView: KeyboardCleanerView(main: i == 0).orbitTint())
            host.sizingOptions = []
            host.safeAreaRegions = []
            panel.contentView = FloatingPanel.container(for: host)
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
    }
}

private final class CleanerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private func keyboardCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        KeyboardCleaner.live?.reenable()
        return Unmanaged.passUnretained(event)
    }
    return nil
}

private struct KeyboardCleanerView: View {
    /// Only the main display carries the controls; the others just dim.
    let main: Bool
    private var cleaner: KeyboardCleaner { .shared }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.55)
            if main { content }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(spacing: 22) {
            ZStack {
                if let ends = cleaner.endsAt {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let left = max(0, ends.timeIntervalSince(ctx.date))
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
                            Circle().trim(from: 0, to: left / Double(max(cleaner.duration, 1)))
                                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                    }
                } else {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
                }
                Image(systemName: "keyboard")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white)
            }
            .frame(width: 140, height: 140)

            VStack(spacing: 8) {
                Text("Cleaning the keyboard".loc)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Keys do nothing right now — wipe away. Click Done Cleaning when you’re finished.".loc)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                if let ends = cleaner.endsAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("Ends by itself in %ld s".loc(Int(max(0, ends.timeIntervalSince(ctx.date)).rounded(.up))))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(KeyboardCleaner.durations, id: \.self) { d in
                    let on = cleaner.duration == d
                    Button { KeyboardCleaner.shared.duration = d } label: {
                        Text(d == 0 ? "Until I click Done".loc : d == 60 ? "1 min".loc : "%ld s".loc(d))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? .black : .white.opacity(0.75))
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button { KeyboardCleaner.shared.stop() } label: {
                Text("Done Cleaning".loc)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 200, height: 50)
                    .background(Capsule().fill(Palette.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(40)
    }
}
