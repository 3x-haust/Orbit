import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision

/// The Emergency Kit: a one-page PDF with the Secret Key and a blank line for the Master Password,
/// to print or keep somewhere safe. It's the only way back into the vault on a new Mac.
@MainActor
enum EmergencyKit {
    static func save(secretKey: String, accountID: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Orbit Passwords Emergency Kit.pdf"
        panel.allowedContentTypes = [.pdf]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let page = KitPage(secretKey: secretKey, accountID: accountID, date: Date())
            .frame(width: 595, height: 842)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        Toast.show("Emergency Kit saved", symbol: "checkmark.shield.fill", detail: "Print it, then keep it somewhere safe")
    }

    private struct KitPage: View {
        let secretKey: String
        let accountID: String
        let date: Date

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "key.horizontal.fill").font(.system(size: 22, weight: .bold))
                    Text("Orbit Passwords").font(.system(size: 22, weight: .bold))
                    Spacer()
                    Text(date.formatted(date: .long, time: .omitted)).font(.system(size: 11)).foregroundStyle(.gray)
                }
                Text("Emergency Kit").font(.system(size: 34, weight: .heavy))
                Text("You need both of these to open your vault on a new Mac. Orbit can’t recover them for you — nobody can.")
                    .font(.system(size: 13)).foregroundStyle(.gray)
                box(title: "Secret Key") {
                    Text(secretKey).font(.system(size: 19, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                }
                box(title: "Master Password") {
                    VStack(alignment: .leading, spacing: 6) {
                        Rectangle().fill(.black.opacity(0.25)).frame(height: 1).padding(.top, 26)
                        Text("Write it here by hand, or leave it blank and remember it.").font(.system(size: 10)).foregroundStyle(.gray)
                    }
                }
                box(title: "Vault ID") { Text(accountID).font(.system(size: 11, design: .monospaced)) }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep this kit offline: printed, in a drawer or a safe.").font(.system(size: 12, weight: .semibold))
                    Text("To restore: copy the vault file (Orbit › Passwords › Back Up Vault), install Orbit on the new Mac, choose “Restore from Emergency Kit”, then enter the Secret Key and your Master Password.")
                        .font(.system(size: 11)).foregroundStyle(.gray)
                }
                Spacer()
            }
            .padding(48)
            .foregroundStyle(.black)
            .background(Color.white)
        }

        private func box<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.gray)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.2), lineWidth: 1))
        }
    }
}

/// Finds an `otpauth://` QR code on screen (a site's "set up two-factor" page), so setting up a
/// one-time code is one click.
enum TOTPScanner {
    static func scanScreens() async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width * 2
            config.height = display.height * 2
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
            if let found = codes(in: image).first(where: { $0.lowercased().hasPrefix("otpauth://") }) { return found }
        }
        return nil
    }

    static func codes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}
