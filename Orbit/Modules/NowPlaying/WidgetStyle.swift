import SwiftUI

enum NowPlayingPrefs {
    /// The desktop widget.
    static let widget = "nowplaying.widget"
    static let style = "nowplaying.style"
    static let themes = "nowplaying.themes"
    /// A banner when the song changes.
    static let popup = "nowplaying.popup"
    static let popupPlace = "nowplaying.popupPlace"
    static let popupOnlyHidden = "nowplaying.popupOnlyWhenHidden"
    /// A live activity next to the notch.
    static let notch = "nowplaying.notch"
    /// Talk to Music and Spotify directly (AppleScript).
    static let directControl = "nowplaying.directControl"
    /// "music" (default) or "all".
    static let sources = "nowplaying.sources"
    /// Bundle IDs never shown.
    static let excluded = "nowplaying.excluded"
    /// Pause the music while a video (or any other sound) plays, and pick it back up after. On by default.
    static let autoPause = "nowplaying.autoPause"
    /// Also for FaceTime, Zoom and other call apps.
    static let autoPauseCalls = "nowplaying.autoPause.calls"
    /// Bundle IDs whose sound never pauses the music.
    static let autoPauseExcluded = "nowplaying.autoPause.excluded"

    static var autoPauseOn: Bool { Pref.defaults.object(forKey: autoPause) as? Bool ?? true }
}

/// Everything about how the widget looks and behaves. Stored as JSON; keys added later fall back
/// to their defaults, so old settings keep loading.
struct WidgetStyle: Codable, Equatable {
    enum Layout: String, Codable, CaseIterable { case horizontal, vertical, artwork, pill }
    enum Background: String, Codable, CaseIterable { case tinted, glass, solid, none }
    enum Colors: String, Codable, CaseIterable { case artwork, light, dark }
    enum Align: String, Codable, CaseIterable { case leading, center, trailing }
    enum Design: String, Codable, CaseIterable { case standard, rounded, serif, mono }
    enum Weight: String, Codable, CaseIterable { case regular, medium, semibold, bold, heavy }
    enum Level: String, Codable, CaseIterable { case desktop, floating }
    enum Anchor: String, Codable, CaseIterable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    }

    var layout: Layout = .horizontal
    var artworkSize: Double = 92
    var cornerRadius: Double = 24
    var artworkRadius: Double = 14
    var shadow: Double = 0.5
    var background: Background = .tinted
    var backgroundOpacity: Double = 0.9
    var colors: Colors = .artwork
    var align: Align = .leading
    var design: Design = .standard
    var weight: Weight = .semibold
    var titleSize: Double = 15
    var textWidth: Double = 210

    var showTitle = true
    var showArtist = true
    var showAlbum = false
    var showControls = true
    var showProgress = true
    var showLike = true
    var showSource = false

    var controlsOnHover = true
    var hideWhenPaused = false
    var hideDelay: Double = 8
    var hideWhenIdle = true
    var level: Level = .desktop
    var anchor: Anchor = .bottomLeft
    /// Distance from the anchor, toward the middle of the screen.
    var dx: Double = 28
    var dy: Double = 28
    /// `NSScreen.localizedName` of the chosen display; empty follows the main display.
    var display = ""
    var locked = false
    var animate = true

    static let standard = WidgetStyle()

    // MARK: Fonts

    func font(_ size: Double, _ weight: Font.Weight) -> Font {
        let d: Font.Design = switch design {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .monospaced
        }
        return .system(size: size, weight: weight, design: d)
    }

    var titleWeight: Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }

    var horizontalAlignment: HorizontalAlignment {
        switch align { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }

    var textAlignment: TextAlignment {
        switch align { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }

    // MARK: Storage

    static func load() -> WidgetStyle {
        decode(Pref.defaults.data(forKey: NowPlayingPrefs.style)) ?? WidgetStyle()
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { Pref.defaults.set(d, forKey: NowPlayingPrefs.style) }
    }

    /// Stored values laid over the defaults, so a missing or renamed key never loses the rest.
    static func decode(_ data: Data?) -> WidgetStyle? {
        guard let data, let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(WidgetStyle())) as? [String: Any] else { return nil }
        var merged = base
        for (k, v) in stored where base[k] != nil { merged[k] = v }
        guard let json = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        if let style = try? JSONDecoder().decode(WidgetStyle.self, from: json) { return style }
        // A value that no longer decodes (an old enum case): keep only what still does, key by key.
        var safe = base
        for (k, v) in stored where base[k] != nil {
            var trial = safe
            trial[k] = v
            if let j = try? JSONSerialization.data(withJSONObject: trial), (try? JSONDecoder().decode(WidgetStyle.self, from: j)) != nil { safe = trial }
        }
        return (try? JSONSerialization.data(withJSONObject: safe)).flatMap { try? JSONDecoder().decode(WidgetStyle.self, from: $0) }
    }

    /// The look of a theme without its place on screen or its behavior.
    func applyingLook(of theme: WidgetStyle) -> WidgetStyle {
        var s = theme
        s.anchor = anchor; s.dx = dx; s.dy = dy; s.display = display; s.locked = locked
        s.level = level; s.hideWhenPaused = hideWhenPaused; s.hideDelay = hideDelay; s.hideWhenIdle = hideWhenIdle
        return s
    }

    func sameLook(as other: WidgetStyle) -> Bool { applyingLook(of: other) == self }
}

/// A named look, built in or saved by the user.
struct WidgetTheme: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var style: WidgetStyle
    var builtIn = false

    static let builtIns: [WidgetTheme] = {
        var orbit = WidgetStyle()
        orbit.layout = .horizontal

        var classic = WidgetStyle()
        classic.background = .none
        classic.colors = .light
        classic.artworkSize = 120
        classic.artworkRadius = 6
        classic.shadow = 0.8
        classic.weight = .bold
        classic.titleSize = 17

        var card = WidgetStyle()
        card.layout = .vertical
        card.artworkSize = 190
        card.align = .center
        card.cornerRadius = 30
        card.artworkRadius = 18
        card.textWidth = 190

        var cover = WidgetStyle()
        cover.layout = .artwork
        cover.artworkSize = 150
        cover.artworkRadius = 22
        cover.shadow = 0.7

        var pill = WidgetStyle()
        pill.layout = .pill
        pill.background = .glass
        pill.artworkSize = 36
        pill.titleSize = 13
        pill.showProgress = false
        pill.textWidth = 170

        var mono = WidgetStyle()
        mono.background = .solid
        mono.colors = .dark
        mono.design = .mono
        mono.weight = .medium
        mono.titleSize = 13
        mono.cornerRadius = 10
        mono.artworkRadius = 4

        var serif = WidgetStyle()
        serif.layout = .vertical
        serif.background = .glass
        serif.design = .serif
        serif.weight = .regular
        serif.titleSize = 18
        serif.artworkSize = 160
        serif.align = .leading
        serif.textWidth = 160

        return [
            WidgetTheme(id: "orbit", name: "Orbit", style: orbit, builtIn: true),
            WidgetTheme(id: "classic", name: "Classic", style: classic, builtIn: true),
            WidgetTheme(id: "card", name: "Card", style: card, builtIn: true),
            WidgetTheme(id: "cover", name: "Cover Only", style: cover, builtIn: true),
            WidgetTheme(id: "pill", name: "Pill", style: pill, builtIn: true),
            WidgetTheme(id: "mono", name: "Mono", style: mono, builtIn: true),
            WidgetTheme(id: "serif", name: "Editorial", style: serif, builtIn: true),
        ]
    }()

    static func saved() -> [WidgetTheme] {
        guard let d = Pref.defaults.data(forKey: NowPlayingPrefs.themes),
              let raw = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return raw.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String,
                  let styleObj = item["style"], let sd = try? JSONSerialization.data(withJSONObject: styleObj),
                  let style = WidgetStyle.decode(sd) else { return nil }
            return WidgetTheme(id: id, name: name, style: style)
        }
    }

    static func save(_ themes: [WidgetTheme]) {
        if let d = try? JSONEncoder().encode(themes.filter { !$0.builtIn }) { Pref.defaults.set(d, forKey: NowPlayingPrefs.themes) }
    }
}
