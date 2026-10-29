import SwiftUI

/// The bottom of each feature page: shortcuts for what that page does, set right there.
struct PageShortcuts: View {
    let page: Page

    var body: some View {
        let actions = Self.actions(for: page).filter { $0.shortcutName != nil }
        if !actions.isEmpty {
            SettingsGroup(title: "Shortcuts", footer: "Click a shortcut, then press the keys. esc cancels, ⌫ clears.") {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    if i > 0 { RowDivider() }
                    SettingsRow(title: action.title, symbol: action.symbol) {
                        if let name = action.shortcutName { ShortcutRecorder(name: name) }
                    }
                }
            }
            .padding(.top, 28)
        }
    }

    static func actions(for page: Page) -> [OrbitAction] {
        switch page {
        case .capture:
            [.captureArea, .captureWindow, .captureScreen, .captureText, .captureRepeat, .captureScrolling, .captureTimed, .pinLastCapture,
             .recentCaptures, .colorPicker, .recordArea, .recordWindow, .recordScreen, .stopRecording]
        case .clipboard: [.clipboard, .shelf]
        case .windows: OrbitAction.allCases.filter { $0.windowLayout != nil }
        case .translate: [.translate]
        case .snippets: [.snippets]
        case .passwords: [.passwords]
        case .apps: [.apps]
        case .displays: [.displays]
        case .menubar: [.hideMenuBarIcons]
        case .awake: [.keepAwake]
        case .system: OrbitAction.allCases.filter { $0.group == "System" && $0 != .keepAwake && $0 != .batteryTopUp && $0 != .chargeLimit }
        case .battery: [.chargeLimit, .batteryTopUp]
        case .nowPlaying: [.mediaPlayPause, .mediaNext, .mediaPrevious, .mediaLike]
        default: []
        }
    }
}
