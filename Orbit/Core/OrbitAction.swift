import AppKit
import SwiftUI
import KeyboardShortcuts

/// Every Orbit capability as one shared action model — used by the Ring, the launcher and the menu bar.
enum OrbitAction: String, CaseIterable, Codable, Identifiable {
    case captureArea, captureWindow, captureScreen, captureText, captureRepeat, captureScrolling
    case recordArea, recordWindow, recordScreen, stopRecording, recentCaptures
    case clipboard, launcher, apps, snippets, passwords
    case displays
    case winLeft, winRight, winTop, winBottom, winMaximize, winCenter, winRestore, winNextDisplay, winPreviousDisplay
    case winTopLeft, winTopRight, winBottomLeft, winBottomRight, winFirstThird, winCenterThird, winLastThird
    case pinLastCapture, keepAwake, settings
    case mediaPlayPause, mediaNext, mediaPrevious, mediaLike
    case colorPicker, captureTimed, shelf, translate, spellCheck, hideMenuBarIcons
    case lockScreen, sleepDisplay, darkMode, desktopIcons, hiddenFiles, emptyTrash, ejectAll, fanBoost, cleanKeyboard
    case batteryTopUp, chargeLimit
    case checkUpdates
    case notchToggle, notchShelf, notchTimer

    var id: String { rawValue }

    @MainActor var title: String { englishTitle.loc }
    @MainActor var shortTitle: String { englishShortTitle.loc }
    /// Display name of `group` (which itself stays an identifier).
    var groupTitle: String { group.loc }

    @MainActor private var englishTitle: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureScreen: "Capture Screen"
        case .captureText: "Copy Text from Screen"
        case .captureRepeat: "Repeat Last Capture"
        case .captureScrolling: "Capture Scrolling Area"
        case .recordArea: "Record Area"
        case .recordWindow: "Record Window"
        case .recordScreen: "Record Screen"
        case .stopRecording: "Stop Recording"
        case .recentCaptures: "Recent Captures"
        case .clipboard: "Clipboard History"
        case .launcher: "Open Launcher"
        case .apps: "Apps"
        case .displays: "Display Brightness"
        case .winLeft: "Left Half"
        case .winRight: "Right Half"
        case .winTop: "Top Half"
        case .winBottom: "Bottom Half"
        case .winMaximize: "Maximize"
        case .winCenter: "Center"
        case .winRestore: "Restore"
        case .winNextDisplay: "Next Display"
        case .winPreviousDisplay: "Previous Display"
        case .winTopLeft: "Top Left"
        case .winTopRight: "Top Right"
        case .winBottomLeft: "Bottom Left"
        case .winBottomRight: "Bottom Right"
        case .winFirstThird: "First Third"
        case .winCenterThird: "Center Third"
        case .winLastThird: "Last Third"
        case .pinLastCapture: "Pin Last Capture"
        case .keepAwake: KeepAwake.shared.isOn ? "Stop Keeping Awake" : "Keep Awake"
        case .settings: "Orbit Settings"
        case .colorPicker: "Pick Color from Screen"
        case .captureTimed: "Capture Area with Timer"
        case .shelf: "Shelf"
        case .translate: "Translate Clipboard"
        case .spellCheck: "Check Spelling"
        case .snippets: "Search Snippets"
        case .passwords: "Passwords Quick Access"
        case .hideMenuBarIcons: "Show/Hide Menu Bar Icons"
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Turn Display Off"
        case .darkMode: "Toggle Dark Mode"
        case .desktopIcons: "Hide/Show Desktop Icons"
        case .hiddenFiles: "Show/Hide Hidden Files"
        case .emptyTrash: "Empty Trash"
        case .ejectAll: "Eject All Disks"
        case .fanBoost: FanControl.shared.mode == .max ? "Fans Back to Automatic" : "Fans at Full Speed"
        case .mediaPlayPause: "Play/Pause"
        case .mediaNext: "Next Song"
        case .mediaPrevious: "Previous Song"
        case .mediaLike: "Like Song"
        case .cleanKeyboard: "Clean Keyboard"
        case .batteryTopUp: BatteryManager.shared.toppingUp ? "Cancel Top Up" : "Top Up Battery"
        case .chargeLimit: BatteryManager.shared.limitOn ? "Turn Charge Limit Off" : "Turn Charge Limit On"
        case .checkUpdates: "Check for Updates"
        case .notchToggle: "Open or Close Notch"
        case .notchShelf: "Open Notch Shelf"
        case .notchTimer: "Start Notch Timer"
        }
    }

    /// Short label for the Ring hub.
    @MainActor private var englishShortTitle: String {
        switch self {
        case .captureArea: "Capture"
        case .captureWindow: "Window Shot"
        case .captureScreen: "Full Screen"
        case .captureText: "Grab Text"
        case .captureRepeat: "Repeat"
        case .captureScrolling: "Scrolling"
        case .recordArea: "Record"
        case .recordWindow: "Record Window"
        case .recordScreen: "Record Screen"
        case .stopRecording: "Stop"
        case .recentCaptures: "Captures"
        case .clipboard: "Clipboard"
        case .launcher: "Launcher"
        case .keepAwake: "Awake"
        case .pinLastCapture: "Pin"
        case .settings: "Settings"
        case .colorPicker: "Pick Color"
        case .captureTimed: "Timer Shot"
        case .lockScreen: "Lock"
        case .sleepDisplay: "Display Off"
        case .darkMode: "Dark Mode"
        case .desktopIcons: "Desktop Icons"
        case .hiddenFiles: "Hidden Files"
        case .ejectAll: "Eject All"
        case .fanBoost: "Fan Boost"
        case .cleanKeyboard: "Clean Keys"
        case .batteryTopUp: "Top Up"
        case .chargeLimit: "Charge Limit"
        case .hideMenuBarIcons: "Menu Bar Icons"
        case .translate: "Translate"
        case .spellCheck: "Spelling"
        case .snippets: "Snippets"
        case .passwords: "Passwords"
        case .displays: "Brightness"
        case .checkUpdates: "Updates"
        case .notchToggle: "Notch"
        case .notchShelf: "Notch Shelf"
        case .notchTimer: "Timer"
        default: englishTitle
        }
    }

    var symbol: String {
        switch self {
        case .captureArea: "viewfinder"
        case .captureWindow: "macwindow"
        case .captureScreen: "display"
        case .captureText: "text.viewfinder"
        case .captureRepeat: "arrow.counterclockwise"
        case .captureScrolling: "arrow.down.doc"
        case .recordArea: "rectangle.dashed.badge.record"
        case .recordWindow: "macwindow.badge.plus"
        case .recordScreen: "rectangle.inset.filled.badge.record"
        case .stopRecording: "stop.circle"
        case .recentCaptures: "photo.stack"
        case .clipboard: "doc.on.clipboard"
        case .launcher: "command"
        case .apps: "square.grid.3x3"
        case .displays: "sun.max"
        case .winLeft: "rectangle.lefthalf.filled"
        case .winRight: "rectangle.righthalf.filled"
        case .winTop: "rectangle.tophalf.filled"
        case .winBottom: "rectangle.bottomhalf.filled"
        case .winMaximize: "arrow.up.left.and.arrow.down.right"
        case .winCenter: "rectangle.center.inset.filled"
        case .winRestore: "arrow.uturn.backward"
        case .winNextDisplay: "rectangle.on.rectangle"
        case .winPreviousDisplay: "rectangle.on.rectangle"
        case .winTopLeft: "rectangle.inset.topleft.filled"
        case .winTopRight: "rectangle.inset.topright.filled"
        case .winBottomLeft: "rectangle.inset.bottomleft.filled"
        case .winBottomRight: "rectangle.inset.bottomright.filled"
        case .winFirstThird: "rectangle.leadingthird.inset.filled"
        case .winCenterThird: "rectangle.center.inset.filled"
        case .winLastThird: "rectangle.trailingthird.inset.filled"
        case .pinLastCapture: "pin"
        case .keepAwake: "cup.and.saucer"
        case .settings: "gearshape"
        case .colorPicker: "eyedropper"
        case .captureTimed: "timer"
        case .shelf: "tray.full"
        case .translate: "character.bubble"
        case .spellCheck: "textformat.abc.dottedunderline"
        case .snippets: "text.badge.plus"
        case .passwords: "key.horizontal"
        case .hideMenuBarIcons: "menubar.rectangle"
        case .lockScreen: "lock"
        case .sleepDisplay: "moon"
        case .darkMode: "circle.lefthalf.filled"
        case .desktopIcons: "menubar.dock.rectangle"
        case .hiddenFiles: "eye"
        case .emptyTrash: "trash"
        case .ejectAll: "eject"
        case .fanBoost: "fan"
        case .mediaPlayPause: "playpause.fill"
        case .mediaNext: "forward.fill"
        case .mediaPrevious: "backward.fill"
        case .mediaLike: "heart"
        case .cleanKeyboard: "keyboard.badge.ellipsis"
        case .batteryTopUp: "battery.100percent.bolt"
        case .chargeLimit: "battery.75percent"
        case .checkUpdates: "arrow.down.circle"
        case .notchToggle: "rectangle.topthird.inset.filled"
        case .notchShelf: "tray.full"
        case .notchTimer: "timer"
        }
    }

    var group: String {
        switch self {
        case .captureArea, .captureWindow, .captureScreen, .captureText, .captureRepeat, .captureScrolling, .pinLastCapture, .captureTimed, .colorPicker,
             .recordArea, .recordWindow, .recordScreen, .stopRecording, .recentCaptures: "Capture"
        case .clipboard, .snippets: "Clipboard"
        case .launcher, .apps, .passwords, .displays, .settings, .keepAwake, .shelf, .translate, .spellCheck, .hideMenuBarIcons, .checkUpdates, .notchToggle, .notchShelf, .notchTimer: "Orbit"
        case .lockScreen, .sleepDisplay, .darkMode, .desktopIcons, .hiddenFiles, .emptyTrash, .ejectAll, .fanBoost, .cleanKeyboard, .batteryTopUp, .chargeLimit: "System"
        case .mediaPlayPause, .mediaNext, .mediaPrevious, .mediaLike: "Media"
        default: "Window"
        }
    }

    var tint: Color {
        switch group {
        case "Capture": self == .captureText ? Tint.text : Tint.capture
        case "Clipboard", "System": Tint.clipboard
        case "Window": Tint.window
        default: Tint.launcher
        }
    }

    var keywords: String {
        let specific = switch self {
        case .colorPicker: "color picker eyedropper hex rgb 컬러 색상 스포이드"
        case .apps: "apps applications launchpad grid all programs 앱 응용 프로그램 런치패드 모든 앱"
        case .displays: "display monitor brightness contrast volume ddc external screen dim monitorcontrol lunar betterdisplay 모니터 디스플레이 밝기 대비 음량 화면 어둡게 외장 모니터"
        case .captureTimed: "timer delay countdown 타이머 지연"
        case .captureScrolling: "scrolling screenshot long page full page stitch 스크롤 캡처 긴 화면 전체 페이지"
        case .recentCaptures: "recent captures library gallery screenshots recordings attach history 최근 캡처 갤러리 스크린샷 모음 첨부"
        case .recordArea, .recordWindow, .recordScreen, .stopRecording: "record recording video screen recorder mp4 gif cleanshot 녹화 화면 녹화 동영상 영상"
        case .keepAwake: "awake caffeine amphetamine sleep lid 잠자기 방지 카페인"
        case .shelf: "shelf drop files stash dropover yoink 선반 파일"
        case .translate: "translate deepl papago google 번역 번역기"
        case .spellCheck: "spell spelling check grammar proofread typo spacing languagetool grammarly 맞춤법 검사 띄어쓰기 문법 교정 오타 맞춤법 검사기"
        case .passwords: "password passwords login autofill fill 1password bitwarden keychain vault otp totp 2fa 비밀번호 암호 패스워드 로그인 자동 입력 금고 인증 코드"
        case .snippets: "snippet snippets text expander expansion abbreviation keyword template 스니펫 상용구 자동 완성 텍스트 확장"
        case .hideMenuBarIcons: "menu bar hide icons bartender barbee 메뉴 막대 아이콘 숨기기"
        case .lockScreen: "lock 화면 잠금"
        case .darkMode: "dark light mode theme 다크모드 라이트모드"
        case .fanBoost: "fan cooling boost max rpm macs fan control 팬 쿨링 최대 속도"
        case .mediaPlayPause, .mediaNext, .mediaPrevious, .mediaLike: "music song play pause next previous skip like love spotify now playing sleeve 음악 노래 재생 일시정지 다음 이전 좋아요"
        case .cleanKeyboard: "clean keyboard wipe disable keys lock keyboard keyboardcleantool 키보드 청소 닦기 키 잠그기"
        case .batteryTopUp, .chargeLimit: "battery charge limit aldente top up full 배터리 충전 한도 제한 완충 알덴테"
        case .checkUpdates: "update updates upgrade new version release download 업데이트 새 버전 최신 버전 릴리즈"
        case .notchToggle, .notchShelf, .notchTimer: "notch dynamic island boring notch notchnook alcove shelf timer pomodoro 노치 다이내믹 아일랜드 선반 타이머 뽀모도로"
        default: ""
        }
        return groupKeywords + " " + specific
    }

    private var groupKeywords: String {
        switch group {
        case "Capture": "screenshot capture snap grab image ocr text 캡처 스크린샷"
        case "Clipboard": "clipboard history paste copy 클립보드"
        case "Window": "window snap move resize layout 창"
        case "System": "system mac lock sleep dark appearance finder desktop trash eject 시스템 잠금 다크모드 휴지통"
        default: "orbit"
        }
    }

    var shortcutName: KeyboardShortcuts.Name? {
        switch self {
        case .captureArea: .captureArea
        case .captureWindow: .captureWindow
        case .captureScreen: .captureScreen
        case .captureText: .captureText
        case .captureRepeat: .captureRepeat
        case .captureScrolling: .captureScrolling
        case .clipboard: .clipboard
        case .snippets: .snippets
        case .passwords: .passwords
        case .launcher: .launcher
        case .apps: .apps
        case .winLeft: .winLeft
        case .winRight: .winRight
        case .winTop: .winTop
        case .winBottom: .winBottom
        case .winMaximize: .winMaximize
        case .winCenter: .winCenter
        case .winRestore: .winRestore
        case .winNextDisplay: .winNextDisplay
        case .winPreviousDisplay: .winPreviousDisplay
        case .winTopLeft: .winTopLeft
        case .winTopRight: .winTopRight
        case .winBottomLeft: .winBottomLeft
        case .winBottomRight: .winBottomRight
        case .winFirstThird: .winFirstThird
        case .winCenterThird: .winCenterThird
        case .winLastThird: .winLastThird
        case .colorPicker: .colorPicker
        case .shelf: .shelf
        case .translate: .translate
        case .spellCheck: .spellCheck
        case .settings: nil
        default: KeyboardShortcuts.Name(rawValue)
        }
    }

    @MainActor var shortcutLabel: String? {
        shortcutName.flatMap { KeyboardShortcuts.getShortcut(for: $0)?.description }
    }

    var windowLayout: WindowManager.Layout? {
        switch self {
        case .winLeft: .left
        case .winRight: .right
        case .winTop: .top
        case .winBottom: .bottom
        case .winMaximize: .maximize
        case .winCenter: .center
        case .winRestore: .restore
        case .winNextDisplay: .nextDisplay
        case .winPreviousDisplay: .previousDisplay
        case .winTopLeft: .topLeft
        case .winTopRight: .topRight
        case .winBottomLeft: .bottomLeft
        case .winBottomRight: .bottomRight
        case .winFirstThird: .firstThird
        case .winCenterThird: .centerThird
        case .winLastThird: .lastThird
        default: nil
        }
    }

    /// - Parameter window: a specific window to act on (the Ring passes the window under the cursor).
    @MainActor
    func perform(window: AXUIElement? = nil) {
        if let layout = windowLayout {
            WindowManager.shared.apply(layout, to: window)
            return
        }
        switch self {
        case .captureArea: CaptureService.shared.start(.area)
        case .captureWindow: CaptureService.shared.start(.window)
        case .captureScreen: CaptureService.shared.start(.screen)
        case .captureText: CaptureService.shared.start(.text)
        case .captureRepeat: CaptureService.shared.repeatLast()
        case .captureScrolling: CaptureService.shared.start(.scrolling)
        case .recordArea: Recorder.shared.start(.area)
        case .recordWindow: Recorder.shared.start(.window)
        case .recordScreen: Recorder.shared.start(.screen)
        case .stopRecording:
            if Recorder.shared.isRecording { Recorder.shared.stop() }
            else { Toast.show("Not recording", symbol: "record.circle") }
        case .recentCaptures: CaptureLibrary.shared.toggle()
        case .clipboard: ClipboardPanel.shared.toggle()
        case .launcher: LauncherPanel.shared.toggle()
        case .apps: AppsPanel.shared.toggle()
        case .passwords: PasswordsPanel.shared.toggle()
        case .displays: DisplaysPanel.shared.toggle()
        case .pinLastCapture:
            if let last = CaptureService.shared.recent.first { PinWindow.pin(last.image) }
            else { Toast.show("No captures yet", symbol: "pin.slash") }
        case .keepAwake: KeepAwake.shared.toggle()
        case .settings: MainWindow.show()
        case .colorPicker: SystemActions.pickColor()
        case .captureTimed: SystemActions.timedCapture()
        case .shelf: Shelf.shared.toggle()
        case .translate: TranslateController.shared.translateClipboard()
        case .spellCheck: SpellController.shared.checkSelection()
        case .snippets: SnippetPanel.shared.toggle()
        case .hideMenuBarIcons: MenuBarHider.shared.toggleFromAction()
        case .lockScreen: SystemActions.lockScreen()
        case .sleepDisplay: SystemActions.sleepDisplay()
        case .darkMode: SystemActions.toggleDarkMode()
        case .desktopIcons: SystemActions.toggleDesktopIcons()
        case .hiddenFiles: SystemActions.toggleHiddenFiles()
        case .emptyTrash: SystemActions.emptyTrash()
        case .ejectAll: SystemActions.ejectAll()
        case .fanBoost: FanControl.shared.toggleFullSpeed()
        case .mediaPlayPause: NowPlaying.shared.togglePlayPause(heard: true)
        case .mediaNext: NowPlaying.shared.next(heard: true)
        case .mediaPrevious: NowPlaying.shared.previous(heard: true)
        case .mediaLike: NowPlaying.shared.toggleLike()
        case .cleanKeyboard: KeyboardCleaner.shared.start()
        case .batteryTopUp: BatteryManager.shared.toppingUp ? BatteryManager.shared.cancelTopUp() : BatteryManager.shared.topUp()
        case .chargeLimit: BatteryManager.shared.toggleLimit()
        case .checkUpdates: Updater.shared.checkFromAction()
        case .notchToggle: NotchCenter.shared.toggleFromAction()
        case .notchShelf: NotchCenter.shared.open(tab: .shelf)
        case .notchTimer: NotchCenter.shared.startTimerFromAction()
        default: break
        }
    }
}
