import AppKit
import SwiftUI

/// The little progress card for archive jobs started outside the app window (double-click, Finder
/// menu). Bottom-centre, above where toasts appear; it goes away a moment after everything is done.
@MainActor
final class ArchiveHUD {
    static let shared = ArchiveHUD()
    private var panel: FloatingPanel?
    private var hideWork: DispatchWorkItem?

    func update() {
        let jobs = Archives.shared.jobs
        hideWork?.cancel()
        guard !jobs.isEmpty else { hide(); return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 340, height: CGFloat(min(jobs.count, 4)) * 58 + 16)
        let screen = NSScreen.active.visibleFrame
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.minY + 120, width: size.width, height: size.height)
        if panel.isVisible { panel.setFrame(frame, display: true, animate: false) } else { panel.present(at: frame) }
        if !Archives.shared.running {
            let work = DispatchWorkItem { [weak self] in
                self?.hide()
                Archives.shared.clearFinished()
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
    }

    private func hide() { panel?.dismiss() }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: .zero, focusable: false)
        p.level = .floating
        p.hasShadow = false
        p.setContent(ArchiveHUDView())
        return p
    }
}

private struct ArchiveHUDView: View {
    private var archives = Archives.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(archives.jobs.prefix(4)) { job in
                ArchiveJobRow(job: job)
                    .padding(.horizontal, 14)
                    .frame(height: 58)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// One job: what, how far, and Cancel / Show in Finder. Used by the HUD and the Archives page.
struct ArchiveJobRow: View {
    let job: Archives.Job

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: job.kind == .compress ? "archivebox.fill" : "shippingbox.and.arrow.backward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            .background(Circle().fill(Palette.raised))
            VStack(alignment: .leading, spacing: 5) {
                Text(job.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .running:
                    ProgressView(value: max(0.02, job.progress))
                        .progressViewStyle(.linear)
                        .tint(Palette.accent)
                        .animation(.easeOut(duration: 0.2), value: job.progress)
                case .done:
                    Text(job.kind == .compress ? "Compressed".loc : "Extracted".loc).font(.orbitCaption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message.loc).font(.orbitCaption).foregroundStyle(.secondary).lineLimit(2)
                case .cancelled:
                    Text("Cancelled".loc).font(.orbitCaption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            switch job.state {
            case .running:
                IconButton(symbol: "xmark", help: "Cancel") { job.cancel.cancel() }
            case .done(let url):
                IconButton(symbol: "magnifyingglass", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            default:
                EmptyView()
            }
        }
    }

    private var tint: Color {
        switch job.state {
        case .failed: .red
        case .done: Palette.accent
        default: Palette.ink
        }
    }
}
