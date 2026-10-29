// README art: hero banner + feature tiles, composed from Orbit settings screenshots.
//   swift tools/readme/art.swift <repo> [en|ko]
// en reads docs/assets/screens/*.png and writes docs/assets/{hero,tile-*}.png;
// ko reads docs/assets/ko/screens/*.png and writes docs/assets/ko/{hero,tile-*}.png.
// The screens come from tools/promo/capture.py (assets/<lang>/screens), which already
// blurs recent captures, menu bar icons and sound devices/apps.
import AppKit

let root = CommandLine.arguments[1]
let lang = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "en"
let assets = root + "/docs/assets"
let out = lang == "en" ? assets : assets + "/" + lang
func img(_ p: String) -> NSImage {
    guard let i = NSImage(contentsOfFile: p) else { fatalError("missing \(p)") }
    return i
}

struct Copy {
    let tagline: String
    let chips: [String]
    let tiles: [(String, String, String)]
}
let copies: [String: Copy] = [
    "en": Copy(tagline: "Every Mac utility, in one orbit.",
               chips: ["Capture", "Clipboard", "Windows", "Translate", "+20 more"],
               tiles: [("capture", "Capture", "Area, window, scrolling, timed — and an editor."),
                       ("windows", "Windows", "Snap layouts that respect Stage Manager."),
                       ("menubar", "Menu Bar", "Hide icons for real. Bring one back on demand."),
                       ("translate", "Translate", "Press ⌘C twice, anywhere."),
                       ("sound", "Sound", "Per-app volume and EQ."),
                       ("system", "System", "Every process, every watt, every fan."),
                       ("awake", "Keep Awake", "Even with the lid closed."),
                       ("displays", "Displays", "Brightness for every screen.")]),
    "ko": Copy(tagline: "맥의 모든 유틸리티 앱을 한 번에",
               chips: ["캡처", "클립보드", "창 정리", "번역", "+20개 더"],
               tiles: [("capture", "캡처", "영역·창·스크롤·타이머 — 편집기까지."),
                       ("windows", "창 정리", "스테이지 매니저와 독을 피하는 배치."),
                       ("menubar", "메뉴 막대", "아이콘을 진짜로 숨기고, 하나만 꺼내요."),
                       ("translate", "번역", "어디서나 ⌘C 두 번."),
                       ("sound", "사운드", "앱별 음량과 EQ."),
                       ("system", "시스템", "모든 프로세스, 모든 와트, 모든 팬."),
                       ("awake", "잠자기 방지", "덮개를 닫아도."),
                       ("displays", "디스플레이", "모든 화면의 밝기.")]),
]
guard let copy = copies[lang] else { fatalError("lang must be en or ko") }

// Korean copy sets in Pretendard (Apple SD Gothic Neo if it isn't installed).
func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    guard lang == "ko" else { return .systemFont(ofSize: size, weight: weight) }
    let names: [NSFont.Weight: String] = [.regular: "Regular", .medium: "Medium", .semibold: "SemiBold", .bold: "Bold"]
    let w = names[weight] ?? "Regular"
    return NSFont(name: "Pretendard-\(w)", size: size) ?? NSFont(name: "AppleSDGothicNeo-\(w)", size: size)
        ?? .systemFont(ofSize: size, weight: weight)
}
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func canvas(_ w: Int, _ h: Int, _ draw: (CGRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let orange = NSColor(red: 1, green: 0.42, blue: 0.21, alpha: 1)

func background(_ r: CGRect) {
    NSGradient(colors: [NSColor(white: 0.09, alpha: 1), NSColor(white: 0.02, alpha: 1)])!.draw(in: r, angle: -90)
    // faint orbit rings
    let c = CGPoint(x: r.width * 0.80, y: r.height * 0.45)
    for (i, rad) in [r.height * 0.55, r.height * 0.85, r.height * 1.2].enumerated() {
        let p = NSBezierPath(ovalIn: CGRect(x: c.x - rad, y: c.y - rad * 0.42, width: rad * 2, height: rad * 0.84))
        var t = AffineTransform(translationByX: c.x, byY: c.y); t.rotate(byDegrees: -18); t.translate(x: -c.x, y: -c.y)
        p.transform(using: t)
        NSColor(white: 1, alpha: 0.05 - Double(i) * 0.012).setStroke()
        p.lineWidth = 3
        let dash: [CGFloat] = [2, 14]
        p.setLineDash(dash, count: 2, phase: 0)
        p.lineCapStyle = .round
        p.stroke()
    }
    // glow
    let g = NSGradient(colors: [orange.withAlphaComponent(0.20), orange.withAlphaComponent(0)])!
    g.draw(fromCenter: CGPoint(x: r.width * 0.78, y: r.height * 0.5), radius: 0,
           toCenter: CGPoint(x: r.width * 0.78, y: r.height * 0.5), radius: r.height * 0.75, options: [])
}

func shot(_ image: NSImage, in rect: CGRect, radius: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.7); shadow.shadowBlurRadius = 60; shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    NSColor.black.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.12).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius); border.lineWidth = 2; border.stroke()
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint, kern: CGFloat = 0, latin: Bool = false) {
    let f = latin ? NSFont.systemFont(ofSize: size, weight: weight) : font(size, weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .kern: kern]
    NSAttributedString(string: s, attributes: attrs).draw(at: p)
}

// Hero banner
let hero = canvas(2560, 1280) { r in
    background(r)
    let icon = img(assets + "/icon.png")
    icon.draw(in: CGRect(x: 150, y: 760, width: 300, height: 300))
    text("Orbit", 200, .bold, .white, at: CGPoint(x: 160, y: 500), kern: -6, latin: true)
    text(copy.tagline, 62, .medium, NSColor(white: 1, alpha: 0.82), at: CGPoint(x: 166, y: 400), kern: lang == "ko" ? -1.5 : 0)
    // chips
    var x: CGFloat = 168
    for chip in copy.chips {
        let attrs: [NSAttributedString.Key: Any] = [.font: font(30, .semibold), .foregroundColor: chip.hasPrefix("+") ? orange : NSColor(white: 1, alpha: 0.85)]
        let s = NSAttributedString(string: chip, attributes: attrs)
        let w = s.size().width + 56
        let rr = CGRect(x: x, y: 230, width: w, height: 72)
        (chip.hasPrefix("+") ? orange.withAlphaComponent(0.14) : NSColor(white: 1, alpha: 0.08)).setFill()
        NSBezierPath(roundedRect: rr, xRadius: 36, yRadius: 36).fill()
        s.draw(at: CGPoint(x: x + 28, y: 230 + (72 - s.size().height) / 2))
        x += w + 18
    }
    let back = img(out + "/screens/ring.png"), front = img(out + "/screens/home.png")
    shot(back, in: CGRect(x: 1700, y: 330, width: 780, height: 683), radius: 28)
    shot(front, in: CGRect(x: 1400, y: 120, width: 960, height: 840), radius: 30)
}
save(hero, out + "/hero.png")

// Gallery tiles (2 per row)
func tile(_ name: String, _ title: String, _ sub: String) {
    let rep = canvas(1400, 1000) { r in
        background(r)
        text(title, 60, .bold, .white, at: CGPoint(x: 90, y: 880), kern: lang == "ko" ? -1.5 : -1)
        text(sub, 34, .regular, NSColor(white: 1, alpha: 0.6), at: CGPoint(x: 92, y: 828))
        let s = img(out + "/screens/\(name).png")
        let w: CGFloat = 1220, h: CGFloat = 690
        let srcH = h * s.size.width / w
        let src = CGRect(x: 0, y: s.size.height - srcH, width: s.size.width, height: srcH)
        let rect = CGRect(x: 90, y: 0, width: w, height: h + 30)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.7); sh.shadowBlurRadius = 50; sh.shadowOffset = NSSize(width: 0, height: -10); sh.set()
        NSColor.black.setFill(); NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 60), xRadius: 26, yRadius: 26).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 60), xRadius: 26, yRadius: 26).addClip()
        s.draw(in: CGRect(x: 90, y: 60 + 30, width: w, height: h), from: src, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // fade the cut-off bottom into the background
        NSGradient(colors: [NSColor(white: 0.03, alpha: 1), NSColor(white: 0.03, alpha: 0)])!.draw(in: CGRect(x: 0, y: 0, width: r.width, height: 260), angle: 90)
    }
    save(rep, out + "/tile-\(name).png")
}
for (name, title, sub) in copy.tiles { tile(name, title, sub) }
