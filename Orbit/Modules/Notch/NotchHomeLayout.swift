import Foundation

enum NotchHomeWidget: String, Codable, CaseIterable, Identifiable, Sendable {
    case music, calendar, aiUsage

    var id: Self { self }

    var title: String {
        switch self {
        case .music: "Music"
        case .calendar: "Calendar"
        case .aiUsage: "AI Usage"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .calendar: "calendar"
        case .aiUsage: "gauge.with.dots.needle.50percent"
        }
    }
}

enum NotchHomeRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case equal, leadingWide, trailingWide

    var id: Self { self }

    var title: String {
        switch self {
        case .equal: "1:1"
        case .leadingWide: "2:1"
        case .trailingWide: "1:2"
        }
    }
}

struct NotchHomeLayout: Codable, Equatable, Sendable {
    let widgets: [NotchHomeWidget]
    let ratio: NotchHomeRatio

    static let standard = Self()
    static let gap: CGFloat = 29

    init(widgets: [NotchHomeWidget] = [.music, .calendar], ratio: NotchHomeRatio = .leadingWide) {
        var seen: Set<NotchHomeWidget> = []
        let unique = widgets.filter { seen.insert($0).inserted }
        self.widgets = unique.isEmpty ? [.music, .calendar] : unique
        self.ratio = ratio
    }

    private enum CodingKeys: String, CodingKey { case widgets, ratio }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let widgets = try values.decodeIfPresent([String].self, forKey: .widgets) ?? []
        let ratio = try values.decodeIfPresent(String.self, forKey: .ratio)
        self.init(widgets: widgets.compactMap(NotchHomeWidget.init(rawValue:)),
                  ratio: ratio.flatMap(NotchHomeRatio.init(rawValue:)) ?? .leadingWide)
    }

    static func decode(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? .standard
    }

    func horizontalRange(for widget: NotchHomeWidget, total: CGFloat) -> Range<CGFloat>? {
        guard let index = widgets.firstIndex(of: widget) else { return nil }
        let widths = widths(total: total, gap: Self.gap)
        let start = widths.prefix(index).reduce(0, +) + Self.gap * CGFloat(index)
        return start..<(start + widths[index])
    }

    /// Width of each card after reserving space for the separators.
    func widths(total: CGFloat, gap: CGFloat) -> [CGFloat] {
        let available = max(0, total - gap * CGFloat(widgets.count - 1))
        if widgets.count == 2, ratio != .equal {
            let narrow = available / 3
            let wide = available - narrow
            return ratio == .leadingWide ? [wide, narrow] : [narrow, wide]
        }
        return Array(repeating: available / CGFloat(widgets.count), count: widgets.count)
    }
}
