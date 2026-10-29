import AppKit
import SwiftUI
import VisionKit

/// Live Text over the editor's canvas: drag across any words in the screenshot to select just those,
/// ⌘C (or right-click) to copy them. It lies exactly over the shown picture, so it scales with it.
/// It's mounted as soon as the editor opens and reads the picture right away, so turning the text
/// tool on is instant; while the tool is off it takes no clicks and shows nothing. VisionKit's own
/// Live Text button is hidden: the editor's toolbar is the one switch.
struct LiveTextOverlay: NSViewRepresentable {
    let image: NSImage
    let model: EditorModel
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ImageAnalysisOverlayView {
        let view = ImageAnalysisOverlayView(context.coordinator)
        view.isSupplementaryInterfaceHidden = true
        view.preferredInteractionTypes = []
        context.coordinator.analyze(image, into: view)
        return view
    }

    func updateNSView(_ view: ImageAnalysisOverlayView, context: Context) {
        let c = context.coordinator
        c.model = model
        // Cropping hands the editor a new picture; read that one instead.
        if c.image !== image { c.analyze(image, into: view) }
        c.setActive(active, on: view)
    }

    static func dismantleNSView(_ view: ImageAnalysisOverlayView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        coordinator.model.selectedText = ""
    }

    @MainActor
    final class Coordinator: NSObject, ImageAnalysisOverlayViewDelegate {
        var model: EditorModel
        var task: Task<Void, Never>?
        private(set) var image: NSImage?
        private var active = false
        private var analysis: ImageAnalysis?
        private var analyzed = false
        private static let analyzer = ImageAnalyzer()

        init(model: EditorModel) { self.model = model }

        func analyze(_ image: NSImage, into view: ImageAnalysisOverlayView) {
            task?.cancel()
            self.image = image
            analysis = nil
            analyzed = false
            view.analysis = nil
            model.analyzingText = true
            task = Task { [weak view, weak self] in
                let analysis = try? await Self.analyzer.analyze(image, orientation: .up, configuration: .init(.text))
                guard !Task.isCancelled, let view, let self else { return }
                self.model.analyzingText = false
                self.analysis = analysis
                self.analyzed = true
                view.analysis = analysis
                view.selectableItemsHighlighted = false
                // Turned on while it was still reading: now it can say what it found.
                if self.active { self.announce(on: view) }
            }
        }

        func setActive(_ on: Bool, on view: ImageAnalysisOverlayView) {
            guard on != active else { return }
            active = on
            view.preferredInteractionTypes = on ? .textSelection : []
            if on {
                if analyzed { announce(on: view) }
            } else {
                view.resetSelection()
                view.selectableItemsHighlighted = false
                model.selectedText = ""
            }
        }

        /// A brief glow on the words that can be picked, or a note that there are none.
        private func announce(on view: ImageAnalysisOverlayView) {
            guard analysis?.hasResults(for: .text) == true else {
                Toast.show("No text found", symbol: "text.viewfinder")
                return
            }
            view.selectableItemsHighlighted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak view] in
                guard let view, view.preferredInteractionTypes == .textSelection else { return }
                view.selectableItemsHighlighted = false
            }
        }

        // The overlay is the same size as the shown picture.
        func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }

        func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
            model.selectedText = overlayView.hasActiveTextSelection ? overlayView.selectedText : ""
        }
    }
}
