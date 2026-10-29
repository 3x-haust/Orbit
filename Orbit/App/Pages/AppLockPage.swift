import AVFoundation
import AppKit
import SwiftUI

struct AppLockPage: View {
    private var enrollment: FaceEnrollment { .shared }
    @AppStorage(Pref.appLockStrictness) private var strictness = FaceStore.Strictness.normal.rawValue
    @AppStorage(Pref.appLockLiveness) private var liveness = false
    @AppStorage(Pref.appLockPreview) private var preview = false
    @AppStorage(Pref.appLockCamera) private var camera = ""
    @AppStorage(Pref.appLockAutoRetry) private var autoRetry = true
    @State private var confirmingDelete = false
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Face Unlock", subtitle: "Your face instead of your password — at the lock screen, and whenever macOS asks for Touch ID or your password.")

            FaceCard(enrollment: enrollment, confirmingDelete: $confirmingDelete)

            // The lock screen, then macOS's own password and Touch ID prompts.
            MacUnlockSection()

            SettingsGroup(title: "Face check") {
                SettingsRow(title: "Match", subtitle: "Stricter turns away look-alikes; relaxed copes better with glasses and low light.", symbol: "person.crop.square") {
                    ChipPicker(selection: $strictness, options: FaceStore.Strictness.allCases.map { ($0.rawValue, $0.title) })
                }
                RowDivider()
                SettingsRow(title: "Require a blink", subtitle: "Stops a photo from unlocking. Takes a moment longer.", symbol: "eye") {
                    Toggle("", isOn: $liveness).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Try again once", subtitle: "If your face isn’t recognized, look once more before giving up.", symbol: "arrow.clockwise") {
                    Toggle("", isOn: $autoRetry).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Show camera preview", subtitle: "See yourself under the notch while it looks.", symbol: "video") {
                    Toggle("", isOn: $preview).toggleStyle(.switch).labelsHidden()
                }
                RowDivider()
                SettingsRow(title: "Camera", symbol: "web.camera") {
                    cameraMenu
                }
                RowDivider()
                SettingsRow(title: "Camera access", subtitle: cameraSubtitle, symbol: cameraStatus == .authorized ? "checkmark.shield" : "exclamationmark.shield") {
                    cameraAccess
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
                Text("Face unlock in Orbit is a convenience, not as secure as Touch ID. Your face never leaves this Mac — Orbit keeps only an encrypted description of it, never photos — and Touch ID or your password always works instead.")
                    .font(.orbitCaption).foregroundStyle(Palette.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.tight)
        }
        // Back from System Settings: pick up the new camera permission.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
        .onAppear { cameraStatus = AVCaptureDevice.authorizationStatus(for: .video) }
    }

    private var cameraSubtitle: String {
        switch cameraStatus {
        case .authorized: "Orbit can use the camera to recognize you."
        case .notDetermined: "macOS will ask the first time Orbit looks for your face."
        default: "Turned off in System Settings. Face unlock can’t work until it’s on."
        }
    }

    @ViewBuilder private var cameraAccess: some View {
        switch cameraStatus {
        case .authorized:
            Text("Allowed").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
        case .notDetermined:
            Button("Allow") {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    DispatchQueue.main.async { cameraStatus = AVCaptureDevice.authorizationStatus(for: .video) }
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
        default:
            Button("Open Settings") { FaceUnlock.openCameraSettings() }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
    }

    private var cameraMenu: some View {
        let cameras = FaceScanner.cameras
        let current = cameras.first { $0.uniqueID == camera }?.localizedName ?? "Built-in Camera".loc
        return Menu {
            Button { camera = "" } label: {
                if camera.isEmpty { Label("Built-in Camera", systemImage: "checkmark") } else { Text("Built-in Camera") }
            }
            if !cameras.isEmpty { Divider() }
            ForEach(cameras, id: \.uniqueID) { device in
                Button { camera = device.uniqueID } label: {
                    if camera == device.uniqueID { Label(device.localizedName, systemImage: "checkmark") } else { Text(device.localizedName) }
                }
            }
        } label: {
            Text(current).font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Palette.inkSecondary)
    }

}

// MARK: - Face setup card

private struct FaceCard: View {
    let enrollment: FaceEnrollment
    @Binding var confirmingDelete: Bool

    var body: some View {
        HStack(spacing: 24) {
            EnrollRing(enrollment: enrollment)
                .frame(width: 132, height: 132)

            VStack(alignment: .leading, spacing: 8) {
                Text(title.loc).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink)
                Text(detail).font(.orbitCaption).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                HStack(spacing: 8) { buttons }.padding(.top, 6)
            }
            .animation(Motion.reflow, value: enrollment.state)
            Spacer(minLength: 0)
        }
        .padding(22)
        .card(active: enrollment.state == .running)
    }

    private var title: String {
        switch enrollment.state {
        case .running: "Setting up face unlock"
        case .failed: "Face setup didn’t finish"
        case .idle, .saved: enrollment.enrolled ? "Face unlock is ready" : "Set up face unlock"
        }
    }

    private var detail: String {
        switch enrollment.state {
        case .running: enrollment.hint.loc
        case .failed(let message): message.loc
        case .idle, .saved:
            enrollment.enrolled
                ? (enrollment.sampleCount > 0 ? "%d views of your face, stored encrypted on this Mac.".loc(enrollment.sampleCount)
                                              : "Your face is stored encrypted on this Mac.".loc)
                : "Orbit learns your face from a few angles. Confirm with Touch ID or your password, then slowly move your head in a circle.".loc
        }
    }

    @ViewBuilder private var buttons: some View {
        if enrollment.state == .running {
            Button("Cancel") { enrollment.cancel() }.buttonStyle(PillButtonStyle(prominent: false))
        } else if confirmingDelete {
            Button("Delete Face") { confirmingDelete = false; enrollment.delete() }.buttonStyle(PillButtonStyle(prominent: true))
            Button("Keep") { confirmingDelete = false }.buttonStyle(PillButtonStyle(prominent: false))
        } else if enrollment.enrolled {
            Button("Set Up Again") { enrollment.begin() }.buttonStyle(PillButtonStyle(prominent: false))
            Button("Delete") { confirmingDelete = true }.buttonStyle(PillButtonStyle(prominent: false))
        } else {
            Button(enrollment.state == .idle ? "Set Up" : "Try Again") { enrollment.begin() }.buttonStyle(PillButtonStyle(prominent: true))
        }
    }
}

/// Face-ID-style ring: ticks around the camera picture light up as each direction is captured.
private struct EnrollRing: View {
    let enrollment: FaceEnrollment

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if enrollment.state == .running, let session = enrollment.previewSession {
                    CameraPreview(session: session)
                        .frame(width: side - 30, height: side - 30)
                        .clipShape(Circle())
                        .transition(.opacity)
                } else {
                    Circle().fill(Palette.raised).frame(width: side - 30, height: side - 30)
                    Image(systemName: enrollment.enrolled ? "faceid" : "face.dashed")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(enrollment.enrolled ? Palette.ink : Palette.inkSecondary)
                }
                // Same thin ticks as the notch HUD; each captured direction lights four of them.
                let perSegment = 4, count = FaceEnrollment.segmentCount * perSegment
                ForEach(0..<count, id: \.self) { i in
                    let on = enrollment.segments[i / perSegment] || (enrollment.state != .running && enrollment.enrolled)
                    Capsule()
                        .fill(on ? Palette.accent : Palette.ink.opacity(0.14))
                        .frame(width: 2.4, height: on ? 11 : 8)
                        .offset(y: -side / 2 + 6)
                        .rotationEffect(.degrees((Double(i) - Double(perSegment - 1) / 2) / Double(count) * 360))
                        .animation(.spring(duration: 0.35, bounce: 0.4).delay(Double(i % perSegment) * 0.03), value: on)
                }
            }
            .frame(width: side, height: side)
        }
    }
}
