import SwiftUI

/// Design tokens. Values follow docs/research-design.md §6.
enum Space {
    static let micro: CGFloat = 2
    static let tight: CGFloat = 4
    static let compact: CGFloat = 8
    static let related: CGFloat = 12
    static let standard: CGFloat = 16
    static let group: CGFloat = 24
    static let section: CGFloat = 32
    static let major: CGFloat = 48
}

enum Radius {
    static let keycap: CGFloat = 4
    static let smallControl: CGFloat = 6
    static let row: CGFloat = 8
    static let card: CGFloat = 12
    static let panel: CGFloat = 20
}

enum Size {
    static let compactRow: CGFloat = 36
    static let twoLineRow: CGFloat = 52
    static let iconTarget: CGFloat = 28
    static let comfortableIconTarget: CGFloat = 32

    static let launcher = CGSize(width: 680, height: 480)
    static let launcherSearch: CGFloat = 56
    static let footer: CGFloat = 32

    static let shelfHeight: CGFloat = 300
    static let card = CGSize(width: 220, height: 220)
    static let thumbnailWidth: CGFloat = 240
    static let thumbnailMaxHeight: CGFloat = 180
    static let edgeOffset: CGFloat = 20
}

extension Font {
    static let orbitMicro = Font.system(size: 11)
    static let orbitCaption = Font.system(size: 12)
    static let orbitBody = Font.system(size: 13)
    static let orbitBodyEmphasized = Font.system(size: 13, weight: .medium)
    static let orbitSection = Font.system(size: 15, weight: .semibold)
    static let orbitSearch = Font.system(size: 17)
    static let orbitTitle = Font.system(size: 20, weight: .semibold)
    static let orbitHero = Font.system(size: 26, weight: .semibold)
}

enum Motion {
    static let hover = Animation.easeOut(duration: 0.08)
    static let panelEnter = Animation.spring(duration: 0.24, bounce: 0)
    static let panelExit = Animation.easeIn(duration: 0.12)
    static let shelfExpand = Animation.spring(duration: 0.30, bounce: 0.04)
    static let reflow = Animation.easeInOut(duration: 0.18)

    /// Respects Reduce Motion: falls back to a short opacity-only fade.
    static func adaptive(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeOut(duration: 0.08) : animation
    }
}

/// Orbit's monochrome palette. Every color adapts to light/dark automatically;
/// the only hue is the brand accent (AccentColor asset, orange), which also follows the user's system accent choice.
enum Palette {
    /// Window and panel background.
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x0B0B0C)
    /// App window: sidebar and page backgrounds.
    static let sidebar = dynamic(light: 0xF6F6F7, dark: 0x070708)
    static let page = dynamic(light: 0xFFFFFF, dark: 0x0F0F11)
    /// Cards, rows, grouped content.
    static let surface = dynamic(light: 0xF4F4F5, dark: 0x18181A)
    /// Controls resting on a surface.
    static let raised = dynamic(light: 0xE9E9EB, dark: 0x242427)
    /// Primary text and monochrome glyph tiles.
    static let ink = dynamic(light: 0x0B0B0C, dark: 0xFAFAFA)
    static let inkSecondary = dynamic(light: 0x6B6B70, dark: 0x9C9CA3)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, alpha: (0.09, 0.11))
    /// Orbit orange. macOS would otherwise swap the app accent for the user's system accent,
    /// so the brand color is explicit; "Use system accent color" in Settings opts into the system one.
    static let brand = dynamic(light: 0xF55C1A, dark: 0xFF7338)
    static var accent: Color {
        Pref.defaults.bool(forKey: Pref.systemAccent) ? Color(nsColor: .controlAccentColor) : brand
    }

    private static func dynamic(light: UInt32, dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? alpha.1 : alpha.0)
        })
    }
}

/// Module identity is carried by symbols, not color — every module tile is ink-on-canvas.
enum Tint {
    static let capture = Palette.ink
    static let clipboard = Palette.ink
    static let launcher = Palette.ink
    static let window = Palette.ink
    static let text = Palette.ink
}

/// Applies the accent to native controls (buttons, toggles, pickers, selection) and re-renders when the preference changes.
struct OrbitTint: ViewModifier {
    @AppStorage(Pref.systemAccent) private var useSystem = false
    func body(content: Content) -> some View {
        content.tint(useSystem ? Color(nsColor: .controlAccentColor) : Palette.brand).id(useSystem)
    }
}

extension View {
    func orbitTint() -> some View { modifier(OrbitTint()) }
}

enum Brand {
    static var logo: NSImage { NSImage(named: "OrbitLogo") ?? NSApp.applicationIconImage }
}
