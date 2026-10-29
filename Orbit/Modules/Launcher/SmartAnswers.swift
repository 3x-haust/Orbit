import AppKit
import CoreServices
import SwiftUI

/// Spotlight-style instant answers for the launcher: conversions, currency, world clocks, weather,
/// dictionary, System Settings panes and file search. Network/file lookups run in the background and
/// post `SmartAnswers.changed` so the launcher re-renders when they land.
@MainActor
enum SmartAnswers {
    static let changed = Notification.Name("OrbitSmartAnswersChanged")

    static func answers(for raw: String) -> [LauncherItem] {
        let q = raw.precomposedStringWithCanonicalMapping
        var out: [LauncherItem] = []
        out += currency(q)
        if out.isEmpty { out += units(q) }
        out += worldClock(q)
        out += Weather.answers(q)
        out += settingsPanes(q)
        return out
    }

    /// Lower-priority answers shown after apps and commands.
    static func trailing(for raw: String) -> [LauncherItem] {
        let q = raw.precomposedStringWithCanonicalMapping
        return dictionary(q) + FileSearch.shared.items(for: q)
    }

    static func notify() { NotificationCenter.default.post(name: changed, object: nil) }

    static func answer(id: String, title: String, subtitle: String, symbol: String, tint: Color = Tint.launcher,
                       accessory: String, copy: String, extra: [LauncherAction] = []) -> LauncherItem {
        LauncherItem(id: id, title: title, subtitle: subtitle, icon: .symbol(symbol, tint), accessory: accessory, section: accessory,
                     actions: [LauncherAction(title: "Copy Answer", symbol: "doc.on.doc") { LauncherModel.copy(copy) }] + extra)
    }

    // MARK: Numbers

    /// "1,200", "3.5", "5만", "2천", "1.2억", "10k".
    static func amount(_ s: String) -> Double? {
        var t = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces).lowercased()
        var factor = 1.0
        let suffixes: [(String, Double)] = [("억", 1e8), ("만", 1e4), ("천", 1e3), ("백", 1e2), ("k", 1e3), ("m", 1e6)]
        for (suffix, f) in suffixes where t.hasSuffix(suffix) && t.count > suffix.count {
            t.removeLast(suffix.count)
            factor = f
            break
        }
        return Double(t).map { $0 * factor }
    }

    static func format(_ v: Double, digits: Int = 4) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(v) >= 100 ? 2 : digits
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Splits "10 km to mi" / "10km in miles" / "5만원을 달러로" into amount, from, to.
    private static func split(_ q: String) -> (Double, String, String?)? {
        let text = q.trimmingCharacters(in: .whitespaces)
        var i = text.startIndex
        while i < text.endIndex, text[i].isNumber || text[i] == "," || text[i] == "." { i = text.index(after: i) }
        guard i > text.startIndex else { return nil }
        var number = String(text[..<i])
        var rest = text[i...].trimmingCharacters(in: .whitespaces)
        // Korean magnitudes, but only when a unit follows ("5만원", not "5만").
        for m in ["억", "만", "천", "백"] where rest.hasPrefix(m) && rest.count > 1 {
            number += m
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let value = amount(number), !rest.isEmpty else { return nil }
        var words = rest.split(separator: " ").map(String.init)
        if let c = words.firstIndex(where: { ["to", "in", "into", "->", "→", "=", "에서", "으로", "로"].contains($0.lowercased()) }) {
            let from = words[..<c].joined(separator: " "), to = words[(c + 1)...].joined(separator: " ")
            guard !from.isEmpty else { return nil }
            return (value, from, to.isEmpty ? nil : to)
        }
        guard words.count <= 2 else { return nil }
        let from = words.removeFirst()
        return (value, from, words.first)
    }

    /// The word itself, then the word without a trailing Korean particle ("원을" → "원", "달러로" → "달러").
    nonisolated static func candidates(_ word: String) -> [String] {
        var out = [word]
        for particle in ["으로", "에서", "로", "을", "를", "은", "는", "이", "가"] where word.hasSuffix(particle) && word.count > particle.count {
            out.append(String(word.dropLast(particle.count)))
        }
        return out
    }

    // MARK: Currency

    private static func currency(_ q: String) -> [LauncherItem] {
        var text = q
        // Leading symbols: "$100", "€20", "¥500", "₩5000".
        for (symbol, code) in [("$", "usd"), ("€", "eur"), ("£", "gbp"), ("¥", "jpy"), ("₩", "krw")] where text.hasPrefix(symbol) {
            let rest = text.dropFirst().trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            text = parts[0] + code + (parts.count > 1 ? " " + parts[1] : "")
        }
        guard let (value, fromWord, toWord) = split(text), let from = Currency.code(fromWord) else { return [] }
        let local = Locale.current.currency?.identifier ?? "KRW"
        let to = toWord.flatMap(Currency.code) ?? (from == local ? (local == "USD" ? "EUR" : "USD") : local)
        guard toWord == nil || Currency.code(toWord!) != nil, from != to else { return [] }
        guard let rate = Currency.shared.rate(from: from, to: to) else {
            Currency.shared.refreshIfNeeded()
            return [LauncherItem(id: "fx", title: "Getting exchange rates…".loc, subtitle: "\(from) → \(to)", icon: .symbol("dollarsign.arrow.circlepath", .green),
                                 accessory: "Currency", section: "Currency", actions: [])]
        }
        let result = value * rate
        let formatted = Currency.format(result, code: to)
        let updated = Currency.shared.updated.map { "Rates from %@".loc($0.formatted(date: .abbreviated, time: .shortened)) } ?? ""
        return [answer(id: "fx", title: formatted, subtitle: "\(Currency.format(value, code: from)) · 1 \(from) = \(format(rate, digits: 6)) \(to) · \(updated)",
                       symbol: "dollarsign.arrow.circlepath", tint: .green, accessory: "Currency", copy: format(result, digits: 2))]
    }

    // MARK: Units

    private static func units(_ q: String) -> [LauncherItem] {
        guard let (value, fromWord, toWord) = split(q), let from = UnitTable.unit(fromWord) else { return [] }
        let to: Dimension
        if let toWord {
            guard let u = UnitTable.unit(toWord), type(of: u) == type(of: from) else { return [] }
            to = u
        } else {
            guard let u = UnitTable.counterpart(of: from) else { return [] }
            to = u
        }
        guard to != from else { return [] }
        let converted = Measurement(value: value, unit: from).converted(to: to).value
        let f = MeasurementFormatter()
        f.unitOptions = .providedUnit
        f.numberFormatter.maximumFractionDigits = abs(converted) >= 100 ? 2 : 4
        let title = f.string(from: Measurement(value: converted, unit: to))
        let source = f.string(from: Measurement(value: value, unit: from))
        return [answer(id: "unit", title: title, subtitle: "= \(source)", symbol: "ruler", accessory: "Conversion", copy: format(converted))]
    }

    // MARK: World clock

    private static func worldClock(_ q: String) -> [LauncherItem] {
        let lower = q.lowercased()
        let cues = ["time in ", "time ", " time", " 시간", "시간", "지금 ", " 몇시", "몇시"]
        guard cues.contains(where: lower.contains) else { return [] }
        var name = lower
        for cue in cues { name = name.replacingOccurrences(of: cue, with: " ") }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let (city, zone) = Cities.find(name) else { return [] }
        let now = Date()
        let f = DateFormatter()
        f.timeZone = zone
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm")
        let time = f.string(from: now)
        f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        let diff = (zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        let offset = diff == 0 ? "Same time as here".loc : (diff > 0 ? "%ld hours ahead".loc(diff) : "%ld hours behind".loc(-diff))
        return [answer(id: "clock.\(zone.identifier)", title: time, subtitle: "\(city) · \(f.string(from: now)) · \(offset)",
                       symbol: "clock", tint: .orange, accessory: "World Clock", copy: time)]
    }

    // MARK: Dictionary

    private static func dictionary(_ q: String) -> [LauncherItem] {
        var word = q.trimmingCharacters(in: .whitespaces)
        for prefix in ["define ", "뜻 ", "meaning "] where word.lowercased().hasPrefix(prefix) { word = String(word.dropFirst(prefix.count)) }
        for suffix in [" 뜻", " meaning", " 의미"] where word.hasSuffix(suffix) { word = String(word.dropLast(suffix.count)) }
        guard word.count >= 2, word.count <= 40, !word.contains(where: \.isNumber), word.split(separator: " ").count <= 2,
              let definition = DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: (word as NSString).length))?
                .takeRetainedValue() as String?
        else { return [] }
        let summary = definition.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        return [LauncherItem(id: "dict.\(word)", title: word, subtitle: String(summary.prefix(140)), icon: .symbol("character.book.closed", .brown),
                             accessory: "Dictionary", section: "Dictionary", actions: [
            LauncherAction(title: "Open in Dictionary", symbol: "book") { if let url = URL(string: "dict://\(encoded)") { NSWorkspace.shared.open(url) } },
            LauncherAction(title: "Copy Definition", symbol: "doc.on.doc") { LauncherModel.copy(summary) },
        ])]
    }

    // MARK: System Settings

    private static let panes: [(String, String, String, String)] = [
        ("Wi‑Fi", "wifi wi-fi 와이파이 무선", "wifi", "com.apple.wifi-settings-extension"),
        ("Bluetooth", "bluetooth 블루투스", "dot.radiowaves.left.and.right", "com.apple.BluetoothSettings"),
        ("Network", "network ethernet vpn 네트워크", "network", "com.apple.Network-Settings.extension"),
        ("Displays", "display monitor resolution night shift 디스플레이 모니터 해상도", "display", "com.apple.Displays-Settings.extension"),
        ("Sound", "sound audio volume output input 사운드 소리", "speaker.wave.2", "com.apple.Sound-Settings.extension"),
        ("Keyboard", "keyboard input sources 키보드 입력", "keyboard", "com.apple.Keyboard-Settings.extension"),
        ("Trackpad", "trackpad gestures 트랙패드", "rectangle.and.hand.point.up.left", "com.apple.Trackpad-Settings.extension"),
        ("Mouse", "mouse 마우스", "computermouse", "com.apple.Mouse-Settings.extension"),
        ("Battery", "battery power energy 배터리 전원", "battery.75percent", "com.apple.Battery-Settings.extension"),
        ("Appearance", "appearance dark light 화면 모드 다크", "circle.lefthalf.filled", "com.apple.Appearance-Settings.extension"),
        ("Desktop & Dock", "dock desktop stage manager hot corners 독 데스크탑 스테이지", "dock.rectangle", "com.apple.Desktop-Settings.extension"),
        ("Wallpaper", "wallpaper background 배경화면", "photo", "com.apple.Wallpaper-Settings.extension"),
        ("Notifications", "notifications alerts 알림", "bell.badge", "com.apple.Notifications-Settings.extension"),
        ("Focus", "focus do not disturb 집중 방해금지", "moon", "com.apple.Focus-Settings.extension"),
        ("Privacy & Security", "privacy security permissions 개인정보 보안 권한", "hand.raised", "com.apple.settings.PrivacySecurity.extension"),
        ("Login Items", "login items startup 로그인 항목", "power", "com.apple.LoginItems-Settings.extension"),
        ("Storage", "storage disk space 저장 공간", "internaldrive", "com.apple.settings.Storage"),
        ("Software Update", "software update macos 업데이트", "arrow.triangle.2.circlepath", "com.apple.Software-Update-Settings.extension"),
        ("Date & Time", "date time clock 날짜 시간", "calendar.badge.clock", "com.apple.Date-Time-Settings.extension"),
        ("Language & Region", "language region 언어 지역", "globe", "com.apple.Localization-Settings.extension"),
        ("Accessibility", "accessibility 손쉬운 사용", "accessibility", "com.apple.Accessibility-Settings.extension"),
        ("Users & Groups", "users accounts 사용자 계정", "person.2", "com.apple.Users-Groups-Settings.extension"),
        ("Lock Screen", "lock screen screen saver 잠금 화면", "lock.display", "com.apple.Lock-Screen-Settings.extension"),
        ("Touch ID & Password", "touch id password 지문 암호", "touchid", "com.apple.Touch-ID-Settings.extension"),
        ("Control Center", "control center menu bar 제어 센터 메뉴 막대", "switch.2", "com.apple.ControlCenter-Settings.extension"),
        ("Sharing", "sharing airdrop file sharing 공유", "shareplay", "com.apple.Sharing-Settings.extension"),
        ("Printers & Scanners", "printer scanner 프린터", "printer", "com.apple.Printers-Settings.extension"),
        ("Screen Time", "screen time 스크린 타임", "hourglass", "com.apple.Screen-Time-Settings.extension"),
    ]

    private static func settingsPanes(_ q: String) -> [LauncherItem] {
        guard q.count >= 2 else { return [] }
        return panes.compactMap { title, keywords, symbol, id -> (LauncherItem, Int)? in
            guard let score = Fuzzy.score(q, title.loc, keywords: keywords), score >= 400 else { return nil }
            let item = LauncherItem(id: "pane.\(id)", title: title.loc, subtitle: "System Settings".loc, icon: .symbol(symbol, .gray),
                                    accessory: "Settings", section: "System Settings", actions: [
                LauncherAction(title: "Open", symbol: "gearshape") {
                    if let url = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(url) }
                },
            ])
            return (item, score)
        }
        .sorted { $0.1 > $1.1 }.prefix(3).map(\.0)
    }
}

// MARK: - Currency rates

@MainActor
final class Currency {
    static let shared = Currency()

    private(set) var rates: [String: Double] = [:] // per 1 USD
    private(set) var updated: Date?
    private var loading = false
    private let cacheKey = "launcher.fxRates"

    private init() {
        if let cached = Pref.defaults.dictionary(forKey: cacheKey),
           let r = cached["rates"] as? [String: Double], let t = cached["time"] as? Double {
            rates = r
            updated = Date(timeIntervalSince1970: t)
        }
    }

    private static let aliases: [String: String] = [
        "$": "USD", "usd": "USD", "dollar": "USD", "dollars": "USD", "달러": "USD", "불": "USD", "us$": "USD",
        "krw": "KRW", "won": "KRW", "원": "KRW", "₩": "KRW", "원화": "KRW",
        "jpy": "JPY", "yen": "JPY", "엔": "JPY", "엔화": "JPY", "円": "JPY",
        "eur": "EUR", "euro": "EUR", "euros": "EUR", "유로": "EUR", "€": "EUR",
        "gbp": "GBP", "pound": "GBP", "pounds": "GBP", "파운드": "GBP", "£": "GBP",
        "cny": "CNY", "rmb": "CNY", "yuan": "CNY", "위안": "CNY", "元": "CNY",
        "hkd": "HKD", "홍콩달러": "HKD", "twd": "TWD", "대만달러": "TWD", "sgd": "SGD", "싱가포르달러": "SGD",
        "aud": "AUD", "호주달러": "AUD", "cad": "CAD", "캐나다달러": "CAD", "chf": "CHF", "프랑": "CHF",
        "thb": "THB", "바트": "THB", "vnd": "VND", "동": "VND", "php": "PHP", "페소": "PHP", "inr": "INR", "루피": "INR",
        "idr": "IDR", "루피아": "IDR", "myr": "MYR", "링깃": "MYR", "nzd": "NZD", "mxn": "MXN", "brl": "BRL", "rub": "RUB", "루블": "RUB",
        "btc": "BTC",
    ]

    static func code(_ word: String) -> String? {
        for w in SmartAnswers.candidates(word) { if let c = exact(w) { return c } }
        return nil
    }

    private static func exact(_ word: String) -> String? {
        let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if let c = aliases[w] { return c }
        if w.count == 3, w.allSatisfy(\.isLetter), Locale.commonISOCurrencyCodes.contains(w.uppercased()) { return w.uppercased() }
        return nil
    }

    static func format(_ v: Double, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = ["KRW", "JPY", "VND", "IDR"].contains(code) ? 0 : 2
        return f.string(from: NSNumber(value: v)) ?? "\(v) \(code)"
    }

    func rate(from: String, to: String) -> Double? {
        refreshIfNeeded()
        guard let a = from == "USD" ? 1 : rates[from], let b = to == "USD" ? 1 : rates[to], a > 0 else { return nil }
        return b / a
    }

    /// open.er-api.com: free, no key, refreshed daily.
    func refreshIfNeeded() {
        guard !loading, updated.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        loading = true
        Task {
            defer { loading = false }
            guard let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = json["rates"] as? [String: Double] else { return }
            rates = r
            updated = (json["time_last_update_unix"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            Pref.defaults.set(["rates": r, "time": updated!.timeIntervalSince1970], forKey: cacheKey)
            SmartAnswers.notify()
        }
    }
}

// MARK: - Units

enum UnitTable {
    private static let table: [String: Dimension] = {
        var t: [String: Dimension] = [:]
        func add(_ unit: Dimension, _ names: String) { names.split(separator: " ").forEach { t[String($0)] = unit } }
        add(UnitLength.kilometers, "km kilometer kilometers kilometre 킬로미터 키로 킬로")
        add(UnitLength.meters, "m meter meters metre 미터")
        add(UnitLength.centimeters, "cm centimeter centimeters 센티 센티미터 센치")
        add(UnitLength.millimeters, "mm millimeter millimeters 밀리 밀리미터")
        add(UnitLength.miles, "mi mile miles 마일")
        add(UnitLength.yards, "yd yard yards 야드")
        add(UnitLength.feet, "ft foot feet ' 피트")
        add(UnitLength.inches, "in inch inches \" 인치")
        add(UnitMass.kilograms, "kg kilogram kilograms kilo kilos 킬로그램 키로그램")
        add(UnitMass.grams, "g gram grams 그램")
        add(UnitMass.pounds, "lb lbs pound pounds 파운드")
        add(UnitMass.ounces, "oz ounce ounces 온스")
        add(UnitMass.metricTons, "t ton tons tonne 톤")
        add(UnitTemperature.celsius, "c °c celsius 섭씨 도")
        add(UnitTemperature.fahrenheit, "f °f fahrenheit 화씨")
        add(UnitTemperature.kelvin, "k kelvin 켈빈")
        add(UnitVolume.liters, "l liter liters litre 리터")
        add(UnitVolume.milliliters, "ml milliliter milliliters 밀리리터")
        add(UnitVolume.gallons, "gal gallon gallons 갤런")
        add(UnitVolume.cups, "cup cups 컵")
        add(UnitVolume.fluidOunces, "floz")
        add(UnitSpeed.kilometersPerHour, "kmh km/h kph 시속")
        add(UnitSpeed.milesPerHour, "mph")
        add(UnitSpeed.metersPerSecond, "m/s mps")
        add(UnitArea.squareMeters, "m2 m² sqm 제곱미터")
        add(UnitArea.squareFeet, "ft2 ft² sqft")
        add(UnitArea.acres, "acre acres 에이커")
        add(UnitArea.hectares, "ha hectare hectares 헥타르")
        add(UnitInformationStorage.bytes, "b byte bytes 바이트")
        add(UnitInformationStorage.kilobytes, "kb kilobyte kilobytes")
        add(UnitInformationStorage.megabytes, "mb megabyte megabytes 메가")
        add(UnitInformationStorage.gigabytes, "gb gigabyte gigabytes 기가")
        add(UnitInformationStorage.terabytes, "tb terabyte terabytes 테라")
        add(UnitDuration.hours, "h hr hrs hour hours 시간")
        add(UnitDuration.minutes, "min mins minute minutes 분")
        add(UnitDuration.seconds, "s sec secs second seconds 초")
        add(UnitEnergy.kilocalories, "kcal cal calorie calories 칼로리")
        add(UnitEnergy.kilojoules, "kj kilojoule kilojoules")
        return t
    }()

    /// Korean "평" (3.3058 m²) is common for floor area.
    static let pyeong = UnitArea(symbol: "평", converter: UnitConverterLinear(coefficient: 3.305785))

    static func unit(_ word: String) -> Dimension? {
        for w in SmartAnswers.candidates(word) { if let u = exact(w) { return u } }
        return nil
    }

    private static func exact(_ word: String) -> Dimension? {
        let w = word.lowercased()
        if w == "평" || w == "pyeong" { return pyeong }
        return table[w]
    }

    static func counterpart(of unit: Dimension) -> Dimension? {
        switch unit {
        case UnitLength.kilometers: UnitLength.miles
        case UnitLength.miles: UnitLength.kilometers
        case UnitLength.meters: UnitLength.feet
        case UnitLength.feet: UnitLength.meters
        case UnitLength.centimeters: UnitLength.inches
        case UnitLength.inches: UnitLength.centimeters
        case UnitLength.millimeters: UnitLength.inches
        case UnitLength.yards: UnitLength.meters
        case UnitMass.kilograms: UnitMass.pounds
        case UnitMass.pounds: UnitMass.kilograms
        case UnitMass.grams: UnitMass.ounces
        case UnitMass.ounces: UnitMass.grams
        case UnitTemperature.celsius: UnitTemperature.fahrenheit
        case UnitTemperature.fahrenheit: UnitTemperature.celsius
        case UnitVolume.liters: UnitVolume.gallons
        case UnitVolume.gallons: UnitVolume.liters
        case UnitVolume.milliliters: UnitVolume.fluidOunces
        case UnitSpeed.kilometersPerHour: UnitSpeed.milesPerHour
        case UnitSpeed.milesPerHour: UnitSpeed.kilometersPerHour
        case UnitArea.squareMeters: pyeong
        case pyeong: UnitArea.squareMeters
        case UnitInformationStorage.gigabytes: UnitInformationStorage.megabytes
        case UnitInformationStorage.megabytes: UnitInformationStorage.gigabytes
        case UnitInformationStorage.terabytes: UnitInformationStorage.gigabytes
        case UnitDuration.hours: UnitDuration.minutes
        case UnitDuration.minutes: UnitDuration.seconds
        case UnitEnergy.kilocalories: UnitEnergy.kilojoules
        default: nil
        }
    }
}

// MARK: - Cities

enum Cities {
    private static let list: [(names: String, display: String, zone: String)] = [
        ("seoul 서울", "Seoul", "Asia/Seoul"), ("busan 부산", "Busan", "Asia/Seoul"),
        ("tokyo 도쿄 동경", "Tokyo", "Asia/Tokyo"), ("osaka 오사카", "Osaka", "Asia/Tokyo"),
        ("beijing 베이징 북경", "Beijing", "Asia/Shanghai"), ("shanghai 상하이", "Shanghai", "Asia/Shanghai"),
        ("hong kong hongkong 홍콩", "Hong Kong", "Asia/Hong_Kong"), ("taipei 타이베이 대만", "Taipei", "Asia/Taipei"),
        ("singapore 싱가포르", "Singapore", "Asia/Singapore"), ("bangkok 방콕 태국", "Bangkok", "Asia/Bangkok"),
        ("hanoi 하노이 vietnam 베트남", "Hanoi", "Asia/Ho_Chi_Minh"), ("ho chi minh 호치민", "Ho Chi Minh City", "Asia/Ho_Chi_Minh"),
        ("manila 마닐라 필리핀", "Manila", "Asia/Manila"), ("jakarta 자카르타 인도네시아", "Jakarta", "Asia/Jakarta"),
        ("delhi 델리 india 인도", "New Delhi", "Asia/Kolkata"), ("mumbai 뭄바이", "Mumbai", "Asia/Kolkata"),
        ("dubai 두바이", "Dubai", "Asia/Dubai"), ("moscow 모스크바 러시아", "Moscow", "Europe/Moscow"),
        ("istanbul 이스탄불 터키", "Istanbul", "Europe/Istanbul"), ("berlin 베를린 germany 독일", "Berlin", "Europe/Berlin"),
        ("paris 파리 france 프랑스", "Paris", "Europe/Paris"), ("london 런던 uk 영국", "London", "Europe/London"),
        ("madrid 마드리드 spain 스페인", "Madrid", "Europe/Madrid"), ("rome 로마 italy 이탈리아", "Rome", "Europe/Rome"),
        ("amsterdam 암스테르담", "Amsterdam", "Europe/Amsterdam"), ("zurich 취리히 스위스", "Zurich", "Europe/Zurich"),
        ("new york nyc 뉴욕", "New York", "America/New_York"), ("washington 워싱턴", "Washington, D.C.", "America/New_York"),
        ("boston 보스턴", "Boston", "America/New_York"), ("toronto 토론토", "Toronto", "America/Toronto"),
        ("chicago 시카고", "Chicago", "America/Chicago"), ("denver 덴버", "Denver", "America/Denver"),
        ("los angeles la 엘에이 로스앤젤레스", "Los Angeles", "America/Los_Angeles"),
        ("san francisco sf 샌프란시스코 실리콘밸리", "San Francisco", "America/Los_Angeles"),
        ("seattle 시애틀", "Seattle", "America/Los_Angeles"), ("vancouver 밴쿠버", "Vancouver", "America/Vancouver"),
        ("honolulu hawaii 하와이 호놀룰루", "Honolulu", "Pacific/Honolulu"), ("mexico city 멕시코", "Mexico City", "America/Mexico_City"),
        ("sao paulo 상파울루 브라질", "São Paulo", "America/Sao_Paulo"), ("sydney 시드니 호주", "Sydney", "Australia/Sydney"),
        ("melbourne 멜버른", "Melbourne", "Australia/Melbourne"), ("auckland 오클랜드 뉴질랜드", "Auckland", "Pacific/Auckland"),
        ("utc gmt", "UTC", "UTC"),
    ]

    static func find(_ name: String) -> (String, TimeZone)? {
        let n = name.lowercased()
        for city in list where city.names.split(separator: " ").contains(where: { $0 == n }) || city.names.contains(n) && n.count >= 3 {
            if let zone = TimeZone(identifier: city.zone) { return (city.display, zone) }
        }
        return nil
    }

    /// The city the user is in, guessed from the time zone (for weather without a place).
    static var local: String {
        let id = TimeZone.current.identifier
        return list.first { $0.zone == id }?.display ?? id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "Seoul"
    }
}

// MARK: - Weather (open-meteo.com, free, no key)

@MainActor
enum Weather {
    private struct Report { let city: String; let temp: Double; let code: Int; let high: Double; let low: Double; let at: Date }
    private static var cache: [String: Report] = [:]
    private static var loading: Set<String> = []

    static func answers(_ q: String) -> [LauncherItem] {
        let lower = q.lowercased()
        let cues = ["weather", "날씨", "기온"]
        guard cues.contains(where: lower.contains) else { return [] }
        var place = lower
        for cue in cues + [" in ", "오늘", "내일"] { place = place.replacingOccurrences(of: cue, with: " ") }
        place = place.trimmingCharacters(in: .whitespaces)
        let city = place.isEmpty ? Cities.local : (Cities.find(place)?.0 ?? place.capitalized)

        guard let r = cache[city], Date().timeIntervalSince(r.at) < 900 else {
            load(city)
            return [LauncherItem(id: "weather", title: "Checking the weather…".loc, subtitle: city, icon: .symbol("cloud.sun", .cyan),
                                 accessory: "Weather", section: "Weather", actions: [])]
        }
        let (label, symbol) = describe(r.code)
        let title = "\(Int(r.temp.rounded()))° · \(label.loc)"
        return [LauncherItem(id: "weather", title: title, subtitle: "\(r.city) · " + "High %ld° Low %ld°".loc(Int(r.high.rounded()), Int(r.low.rounded())),
                             icon: .symbol(symbol, .cyan), accessory: "Weather", section: "Weather", actions: [
            LauncherAction(title: "Open Weather", symbol: "cloud.sun") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app"))
            },
            LauncherAction(title: "Copy", symbol: "doc.on.doc") { LauncherModel.copy("\(r.city) \(title)") },
        ])]
    }

    private static func load(_ city: String) {
        guard !loading.contains(city) else { return }
        loading.insert(city)
        Task {
            defer { loading.remove(city) }
            let lang = Locale.current.language.languageCode?.identifier ?? "en"
            guard let name = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let geoURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(name)&count=1&language=\(lang)"),
                  let (gd, _) = try? await URLSession.shared.data(from: geoURL),
                  let g = (try? JSONSerialization.jsonObject(with: gd) as? [String: Any])?["results"] as? [[String: Any]],
                  let place = g.first, let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double,
                  let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"),
                  let (d, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let current = json["current"] as? [String: Any], let daily = json["daily"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double, let code = current["weather_code"] as? Int
            else { return }
            let high = (daily["temperature_2m_max"] as? [Double])?.first ?? temp
            let low = (daily["temperature_2m_min"] as? [Double])?.first ?? temp
            cache[city] = Report(city: place["name"] as? String ?? city, temp: temp, code: code, high: high, low: low, at: Date())
            SmartAnswers.notify()
        }
    }

    /// WMO weather codes.
    private static func describe(_ code: Int) -> (String, String) {
        switch code {
        case 0: ("Clear sky", "sun.max")
        case 1, 2: ("Partly cloudy", "cloud.sun")
        case 3: ("Cloudy", "cloud")
        case 45, 48: ("Fog", "cloud.fog")
        case 51...57: ("Drizzle", "cloud.drizzle")
        case 61...67, 80...82: ("Rain", "cloud.rain")
        case 71...77, 85, 86: ("Snow", "cloud.snow")
        case 95...99: ("Thunderstorm", "cloud.bolt.rain")
        default: ("Weather", "cloud.sun")
        }
    }
}

// MARK: - Files (Spotlight index)

@MainActor
final class FileSearch: NSObject {
    static let shared = FileSearch()

    private var query: NSMetadataQuery?
    private var term = ""
    private var results: [String] = []

    func items(for q: String) -> [LauncherItem] {
        let q = q.trimmingCharacters(in: .whitespaces)
        if q != term { start(q) }
        return results.prefix(8).map { path in
            let url = URL(fileURLWithPath: path)
            let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            return LauncherItem(id: "file.\(path)", title: url.lastPathComponent, subtitle: folder, icon: .file(path),
                                accessory: "File", section: "Files", actions: [
                LauncherAction(title: "Open", symbol: "arrow.up.forward.square") { NSWorkspace.shared.open(url) },
                LauncherAction(title: "Show in Finder", symbol: "folder", shortcut: ["⌘", "↩"]) { NSWorkspace.shared.activateFileViewerSelecting([url]) },
                LauncherAction(title: "Copy Path", symbol: "doc.on.doc") { LauncherModel.copy(path) },
            ])
        }
    }

    private func start(_ q: String) {
        term = q
        query?.stop()
        query = nil
        results = []
        guard q.count >= 2, !q.contains("*") else { return }
        let mq = NSMetadataQuery()
        mq.predicate = NSPredicate(format: "%K LIKE[cd] %@ AND %K != 'com.apple.application-bundle'",
                                   NSMetadataItemFSNameKey, "*\(q)*", NSMetadataItemContentTypeKey)
        mq.searchScopes = [NSMetadataQueryUserHomeScope]
        mq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidFinishGathering, object: mq)
        query = mq
        mq.start()
    }

    @objc private func gathered(_ note: Notification) {
        guard let mq = note.object as? NSMetadataQuery, mq === query else { return }
        mq.disableUpdates()
        results = (0..<min(mq.resultCount, 40)).compactMap { (mq.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String }
            .filter { !$0.contains("/Library/") && !$0.contains("/.") }
        mq.stop()
        SmartAnswers.notify()
    }
}
