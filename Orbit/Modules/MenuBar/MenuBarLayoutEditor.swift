import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Barbee-style arrangement: visible, hidden and always-hidden rows with each item's real picture.
/// Dropping an item on another row moves it in the actual menu bar (Orbit does the ⌘-drag).
struct MenuBarLayoutEditor: View {
    private var model: MenuBarItems { .shared }
    @State private var target: MenuBarItems.Section?
    @State private var dragging: String?
    /// The icon a dragged one would land in front of.
    @State private var gap: String?
    /// Icons glide from one row to the other instead of blinking out and in.
    @Namespace private var glide

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("Arrange icons")
                Spacer()
                if model.busy { ProgressView().controlSize(.small).padding(.trailing, 4) }
                Button {
                    // Re-reads the bar where it stands; nothing is unfolded or moved.
                    Task { await model.refresh(reveal: false) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(prominent: false))
                .disabled(model.busy)
            }

            VStack(alignment: .leading, spacing: 14) {
                // Folded, Orbit hides icons by letting macOS tuck them behind « (which Orbit covers),
                // so a full bar is the point, not a problem. Only warn about icons in the Visible row
                // that macOS tucked away anyway.
                if model.systemOverflow, model.items.contains(where: { $0.section == .visible && !$0.shown && $0.mobility != .visibleOnly }) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "chevron.left.2").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.accent)
                            .frame(width: 26, height: 26).background(Circle().fill(Palette.accent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The menu bar is full").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.ink)
                            Text("macOS is hiding some icons behind its own « button. Move a few to Hidden and it goes away.")
                                .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ForEach(MenuBarItems.Section.allCases) { section in
                    row(section)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Drag icons between rows, or onto another icon to put it in front of that one — Orbit moves them in the real menu bar for you. Always-hidden icons only show in the bar under the menu bar.")
                    .font(.system(size: 11)).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .card()
            .opacity(model.busy ? 0.85 : 1)
            .animation(.easeOut(duration: 0.2), value: model.busy)
            .animation(.spring(duration: 0.4, bounce: 0.25), value: model.items.map { "\($0.id)\($0.section.rawValue)" })
            .animation(.spring(duration: 0.3), value: model.systemOverflow)
        }
        .focusEffectDisabled()
        .task { if !model.hasSnapshot { await model.refresh(reveal: true) } }
    }

    private func row(_ section: MenuBarItems.Section) -> some View {
        let items = model.items(in: section)
        let on = target == section
        return VStack(alignment: .leading, spacing: 6) {
            Text(section.title.loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if items.isEmpty {
                        Text("Drop icons here").font(.system(size: 11)).foregroundStyle(Palette.inkSecondary.opacity(0.7))
                            .padding(.horizontal, 6)
                    }
                    ForEach(items) { item in
                        HStack(spacing: 0) {
                            // Insertion mark: drop on an icon to put the dragged one right in front of it.
                            Capsule().fill(Palette.accent)
                                .frame(width: gap == item.id && dragging != item.id ? 3 : 0, height: 22)
                                .padding(.trailing, gap == item.id && dragging != item.id ? 6 : 0)
                            MenuBarItemImage(item: item)
                                .frame(height: 30)
                                .padding(.horizontal, 3)
                                .opacity(item.mobility == .fixed ? 0.45 : 1)
                        }
                        .matchedGeometryEffect(id: item.id, in: glide)
                        .contentShape(Rectangle())
                        .opacity(dragging == item.id ? 0.35 : 1)
                        .help(item.mobility == .fixed ? "%@ — macOS keeps this one in place".loc(item.name) : item.name)
                        .animation(.spring(duration: 0.22), value: gap)
                        .modifier(DragIf(enabled: item.mobility != .fixed) {
                            dragging = item.id
                            return NSItemProvider(object: item.id as NSString)
                        })
                        .onDrop(of: [UTType.plainText], isTargeted: Binding(get: { gap == item.id }, set: { gap = $0 ? item.id : (gap == item.id ? nil : gap) })) { providers in
                            drop(providers, into: section, before: item.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
            }
            .scrollIndicators(.never)
            .background(
                Capsule(style: .continuous)
                    .fill(on ? Palette.accent.opacity(0.14) : Palette.raised)
            )
            .clipShape(Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(on ? Palette.accent : .clear, lineWidth: 1.5)
            )
            .onDrop(of: [UTType.plainText], isTargeted: Binding(get: { target == section }, set: { target = $0 ? section : (target == section ? nil : target) })) { providers in
                drop(providers, into: section, before: nil)
            }
            .animation(.spring(duration: 0.25), value: on)
        }
    }

    private func drop(_ providers: [NSItemProvider], into section: MenuBarItems.Section, before neighbor: String?) -> Bool {
        dragging = nil
        gap = nil
        guard !model.busy, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String else { return }
            Task { @MainActor in await MenuBarItems.shared.move(id, to: section, before: neighbor) }
        }
        return true
    }
}

/// `.onDrag` only for icons that can actually move.
private struct DragIf: ViewModifier {
    let enabled: Bool
    let provider: () -> NSItemProvider

    func body(content: Content) -> some View {
        if enabled { content.onDrag(provider) } else { content }
    }
}

#if DEBUG
/// `com.lyu.orbit.debug` "menubar-editor" opens the editor on its own, for screenshots.
enum MenuBarLayoutEditorDebug {
    nonisolated(unsafe) private static var window: NSWindow?

    @MainActor static func install() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.lyu.orbit.debug"), object: nil, queue: .main) { note in
            if let cmd = note.object as? String, cmd == "collapse" || cmd == "expand" {
                MainActor.assumeIsolated { MenuBarHider.shared.setCollapsed(cmd == "collapse", quietly: true) }
                return
            }
            if let cmd = note.object as? String, cmd == "reveal-on" || cmd == "reveal-off" {
                MainActor.assumeIsolated { MenuBarHider.shared.reveal(cmd == "reveal-on") }
                return
            }
            if note.object as? String == "mb-windows" {
                MainActor.assumeIsolated {
                    let lines = NSApp.windows.map { "\($0.className) \($0.frame) alpha \($0.alphaValue) visible \($0.isVisible)" }
                    MenuBarLog.write("windows: overflow \(String(describing: MenuBarItems.overflowButtonFrame())) collapsed \(MenuBarHider.shared.collapsed)\n  " + lines.joined(separator: "\n  "))
                }
                return
            }
            if note.object as? String == "applock-diag" {
                // Everything the face check needs, short of switching the camera on.
                MainActor.assumeIsolated {
                    let cams = FaceScanner.cameras.map { "\($0.localizedName) [\($0.uniqueID)] connected \($0.isConnected) suspended \($0.isSuspended) inUse \($0.isInUseByAnotherApplication)" }
                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    var input = "n/a"
                    if let device { do { _ = try AVCaptureDeviceInput(device: device); input = "ok" } catch { input = "\(error)" } }
                    AppLockLog.write("diag: enrolled file \(FaceStore.isEnrolled), prints \(FaceStore.load().count) (\(FaceStore.diagnose())), auth \(AVCaptureDevice.authorizationStatus(for: .video).rawValue), default \(device?.localizedName ?? "nil"), input \(input), cameras \(cams)")
                }
                return
            }
            // "mb-allow:<bundle id>:<0|1>[:agent|cc|none]" flips one app's switch, for testing the mechanism.
            if let cmd = note.object as? String, cmd.hasPrefix("mb-allow:") {
                let parts = cmd.split(separator: ":").map(String.init)
                guard parts.count >= 3 else { return }
                MainActor.assumeIsolated {
                    Task {
                        do { try MenuBarAgentPrefs.setAllowed([parts[1]: parts[2] == "1"]) } catch { MenuBarLog.write("mb-allow: \(error)"); return }
                        MenuBarLog.write("mb-allow: wrote \(parts[1]) = \(parts[2]) via \(MenuBarAgentPrefs.lastSource)")
                        switch parts.count > 3 ? parts[3] : "agent" {
                        case "agent": await MenuBarAgentPrefs.restartAgent()
                        case "cc": for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter") { kill(app.processIdentifier, SIGTERM) }
                        default: break
                        }
                    }
                }
                return
            }
            // "mb-reveal:<item id>" opens one hidden item the way picking it under ✦ does.
            if let cmd = note.object as? String, cmd.hasPrefix("mb-reveal:") {
                let id = String(cmd.dropFirst(10))
                MainActor.assumeIsolated {
                    guard let item = MenuBarItems.shared.items.first(where: { $0.id == id }) else {
                        MenuBarLog.write("mb-reveal: no item \(id) among \(MenuBarItems.shared.items.map(\.id))")
                        return
                    }
                    Task { await MenuBarItems.shared.open(item) }
                }
                return
            }
            // "mb-sys:<switch key>:<1 hide|0 back>", e.g. mb-sys:flag:showVPN:1.
            if let cmd = note.object as? String, cmd.hasPrefix("mb-sys:") {
                let rest = String(cmd.dropFirst(7))
                guard let colon = rest.lastIndex(of: ":"), let sw = MenuBarSystemSwitches.Switch(key: String(rest[..<colon])) else { return }
                MainActor.assumeIsolated { MenuBarSystemSwitches.set(sw, hidden: rest[rest.index(after: colon)...] == "1") }
                return
            }
            if note.object as? String == "mb-plist" {
                MainActor.assumeIsolated { MenuBarLog.write("agent plist:\n  " + MenuBarAgentPrefs.describe()) }
                return
            }
            if note.object as? String == "mb-refresh" {
                MainActor.assumeIsolated { Task { await MenuBarItems.shared.refresh(reveal: true) } }
                return
            }
            if note.object as? String == "mb-state" {
                MainActor.assumeIsolated {
                    let h = MenuBarHider.shared, m = MenuBarItems.shared
                    MenuBarLog.write("state: collapsed \(h.collapsed) revealing \(h.revealing) bar \(HiddenBar.shared.isVisible) busy \(m.busy) holding \(m.holdingOverflow) showingHidden \(h.showingHidden)")
                }
                return
            }
            if note.object as? String == "hidden-bar-off" {
                MainActor.assumeIsolated { HiddenBar.shared.hide() }
                return
            }
            if note.object as? String == "hidden-bar" {
                MainActor.assumeIsolated {
                    let screen = NSScreen.screens[0].frame
                    HiddenBar.shared.show(below: NSRect(x: screen.maxX - 200, y: screen.maxY - 30, width: 24, height: 24))
                }
                return
            }
            guard note.object as? String == "menubar-editor" else { return }
            MainActor.assumeIsolated {
                let w = window ?? NSWindow(contentRect: NSRect(x: 200, y: 200, width: 760, height: 460),
                                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: MenuBarLayoutEditor().padding(24).frame(width: 760).background(Palette.page).orbitTint())
                host.sizingOptions = []
                w.contentView = FloatingPanel.container(for: host) // a hosting view as the content view can loop "Update Constraints" and abort
                window = w
                w.bringToFront()
            }
        }
    }
}
#endif
