import SwiftUI
import AppKit

// Orbit app icon — "Signal": white Saturn on black, one orange satellite.
// Writes an Icon Composer bundle (macOS 26 Default / Dark / Clear / Tinted), a fallback appiconset,
// the in-app logo image, the AccentColor, and previews.
//
// Usage: swift tools/RenderIcons.swift <repo-root>

let full: CGFloat = 1024          // Icon Composer layers are full-bleed
let tileSide: CGFloat = 824       // fallback icon grid
let tileCorner: CGFloat = 185

let white = Color(red: 1, green: 1, blue: 1)
let orange = Color(red: 1.0, green: 0.40, blue: 0.16)

/// Geometry shared by every rendering of the mark, in full-bleed 1024 space.
enum Mark {
    static let tilt = -0.38
    static let a: CGFloat = 376, b: CGFloat = 116
    static let ring: CGFloat = 46
    static let gap: CGFloat = 26
    nonisolated(unsafe) static var planet: CGFloat = 490
    static let dot: CGFloat = 92
    static let dotGap: CGFloat = 30
    nonisolated(unsafe) static var dotT = ProcessInfo.processInfo.environment["DOT_T"].flatMap(Double.init) ?? 2.45

    static var dotCenter: CGPoint {
        let x = a * cos(dotT), y = b * sin(dotT)
        return CGPoint(x: x * cos(tilt) - y * sin(tilt), y: x * sin(tilt) + y * cos(tilt))
    }
}

/// Ring + planet with true transparent knock-outs. One color; Icon Composer recolors it per appearance.
struct RingPlanet: View {
    var color: Color = white

    var body: some View {
        ZStack {
            ellipse(0, 1, color, Mark.ring)
            Circle().fill(.black).frame(width: Mark.planet + Mark.gap * 2).blendMode(.destinationOut)
            Circle().fill(color).frame(width: Mark.planet)
            // Cut only where the ring crosses the planet, so the ring halves join without a seam.
            ellipse(0.06, 0.44, .black, Mark.ring + Mark.gap * 2).blendMode(.destinationOut)
            ellipse(0, 0.5, color, Mark.ring)
            Circle().fill(.black).frame(width: Mark.dot + Mark.dotGap * 2)
                .offset(x: Mark.dotCenter.x, y: Mark.dotCenter.y)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: full, height: full)
    }

    private func ellipse(_ from: CGFloat, _ to: CGFloat, _ color: Color, _ width: CGFloat) -> some View {
        Ellipse()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .butt))
            .frame(width: Mark.a * 2, height: Mark.b * 2)
            .rotationEffect(.radians(Mark.tilt))
    }
}

struct Satellite: View {
    var color: Color = orange
    var body: some View {
        Circle().fill(color).frame(width: Mark.dot)
            .offset(x: Mark.dotCenter.x, y: Mark.dotCenter.y)
            .frame(width: full, height: full)
    }
}

/// Composite icon for the fallback appiconset, in-app logo and previews.
struct Composite: View {
    enum Look { case standard, dark, tinted, light }
    var look: Look = .standard

    var body: some View {
        ZStack {
            background
            RingPlanet(color: markColor).scaleEffect(tileSide / full)
            Satellite(color: dotColor).scaleEffect(tileSide / full)
        }
        .frame(width: tileSide, height: tileSide)
        .clipShape(RoundedRectangle(cornerRadius: tileCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tileCorner, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(look == .light ? 0.9 : 0.18), .clear], startPoint: .top, endPoint: .center), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 10)
        .frame(width: full, height: full)
    }

    @ViewBuilder private var background: some View {
        switch look {
        case .standard: LinearGradient(colors: [Color(white: 0.13), Color(white: 0.0)], startPoint: .top, endPoint: .bottom)
        case .dark: LinearGradient(colors: [Color(white: 0.08), Color(white: 0.0)], startPoint: .top, endPoint: .bottom)
        case .tinted: LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.30), Color(red: 0.05, green: 0.06, blue: 0.10)], startPoint: .top, endPoint: .bottom)
        case .light: LinearGradient(colors: [.white, Color(white: 0.92)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var markColor: Color {
        switch look {
        case .light: Color(white: 0.04)
        case .tinted: Color(red: 0.72, green: 0.80, blue: 1.0)
        default: white
        }
    }

    private var dotColor: Color { look == .tinted ? Color(red: 0.72, green: 0.80, blue: 1.0).opacity(0.75) : orange }
}

// MARK: - Output

@MainActor func cg<V: View>(_ v: V, scale: CGFloat = 1) -> CGImage {
    let r = ImageRenderer(content: v)
    r.scale = scale
    return r.cgImage!
}

func writePNG(_ image: CGImage, _ url: URL, size: Int? = nil) {
    let px = size ?? image.width
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeJSON(_ object: Any, _ url: URL) {
    try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

func mkdir(_ url: URL) { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let resources = root.appendingPathComponent("Orbit/Resources")
let assets = resources.appendingPathComponent("Assets.xcassets")
let fm = FileManager.default

if CommandLine.arguments.contains("--planets") {
    // Planet size study at the chosen satellite position.
    MainActor.assumeIsolated {
        let sizes: [CGFloat] = [404, 450, 490, 530]
        let views = sizes.map { d -> CGImage in Mark.planet = d; return cg(Composite()) }
        let row = HStack(spacing: 0) { ForEach(0..<views.count, id: \.self) { Image(decorative: views[$0], scale: 1) } }
            .background(Color(white: 0.5))
        let url = root.appendingPathComponent("docs/icons-v3/planet-options.png")
        try! NSBitmapImageRep(cgImage: cg(row)).representation(using: .png, properties: [:])!.write(to: url)
        print("options at \(url.path)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--options") {
    // Satellite placement study: same mark, different positions along the ring.
    MainActor.assumeIsolated {
        let positions: [(String, Double)] = [("1", -0.62), ("2", 0.12), ("3", 0.62), ("4", 2.45), ("5", 3.55)]
        let views = positions.map { _, t -> CGImage in Mark.dotT = t; return cg(Composite()) }
        let row = HStack(spacing: 0) { ForEach(0..<views.count, id: \.self) { Image(decorative: views[$0], scale: 1) } }
            .background(Color(white: 0.5))
        let url = root.appendingPathComponent("docs/icons-v3/satellite-options.png")
        try! NSBitmapImageRep(cgImage: cg(row)).representation(using: .png, properties: [:])!.write(to: url)
        print("options at \(url.path)")
    }
    exit(0)
}

MainActor.assumeIsolated {
    // 1. Icon Composer bundle
    let icon = resources.appendingPathComponent("Orbit.icon")
    try? fm.removeItem(at: icon)
    mkdir(icon.appendingPathComponent("Assets"))
    writePNG(cg(RingPlanet()), icon.appendingPathComponent("Assets/mark.png"))
    writePNG(cg(Satellite()), icon.appendingPathComponent("Assets/satellite.png"))
    let shadow: [String: Any] = ["kind": "neutral", "opacity": 0.45]
    writeJSON([
        "fill-specializations": [
            ["value": ["linear-gradient": ["srgb:0.13000,0.13000,0.13000,1.00000", "srgb:0.00000,0.00000,0.00000,1.00000"]]],
            ["appearance": "dark", "value": ["linear-gradient": ["srgb:0.08000,0.08000,0.08000,1.00000", "srgb:0.00000,0.00000,0.00000,1.00000"]]],
        ],
        "groups": [
            [
                "layers": [["image-name": "satellite.png", "name": "satellite", "glass": true]],
                "shadow": shadow, "specular": true,
                "translucency": ["enabled": false, "value": 0.5],
            ],
            [
                "layers": [[
                    "image-name": "mark.png", "name": "mark", "glass": false,
                    "fill-specializations": [
                        ["value": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"]],
                        ["appearance": "tinted", "value": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"]],
                    ],
                ]],
                "shadow": shadow, "specular": true,
                "translucency": ["enabled": false, "value": 0.5],
            ],
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ], icon.appendingPathComponent("icon.json"))

    // 2. Fallback appiconset (Finder previews on older tooling, About box)
    let composite = cg(Composite())
    let appicon = assets.appendingPathComponent("AppIcon.appiconset")
    try? fm.removeItem(at: appicon)
    mkdir(appicon)
    var images: [[String: String]] = []
    for pt in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
            writePNG(composite, appicon.appendingPathComponent(name), size: pt * scale)
            images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
        }
    }
    writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], appicon.appendingPathComponent("Contents.json"))

    // 3. In-app logo
    for old in ["IconPlanet", "IconGlass", "IconSystem"] { try? fm.removeItem(at: assets.appendingPathComponent("\(old).imageset")) }
    let logo = assets.appendingPathComponent("OrbitLogo.imageset")
    mkdir(logo)
    writePNG(composite, logo.appendingPathComponent("logo.png"))
    writeJSON(["images": [["idiom": "universal", "filename": "logo.png"]], "info": ["author": "xcode", "version": 1]],
              logo.appendingPathComponent("Contents.json"))

    // 4. Accent color — Orbit orange, slightly brighter in dark mode
    let accent = assets.appendingPathComponent("AccentColor.colorset")
    mkdir(accent)
    func comps(_ r: Double, _ g: Double, _ b: Double) -> [String: Any] {
        ["color": ["color-space": "srgb", "components": ["red": String(format: "%.3f", r), "green": String(format: "%.3f", g), "blue": String(format: "%.3f", b), "alpha": "1.000"]], "idiom": "universal"]
    }
    var dark = comps(1.0, 0.45, 0.22)
    dark["appearances"] = [["appearance": "luminosity", "value": "dark"]]
    writeJSON(["colors": [comps(0.96, 0.36, 0.10), dark], "info": ["author": "xcode", "version": 1]], accent.appendingPathComponent("Contents.json"))

    // 5. Previews
    let previews = root.appendingPathComponent("docs/icons-v3")
    mkdir(previews)
    let row = HStack(spacing: 0) {
        Composite(look: .standard); Composite(look: .dark); Composite(look: .tinted)
    }
    try! NSBitmapImageRep(cgImage: cg(row.background(Color(white: 0.5)))).representation(using: .png, properties: [:])!
        .write(to: previews.appendingPathComponent("appearances.png"))
    let dock = HStack(spacing: 20) {
        ForEach(0..<3, id: \.self) { _ in Composite().scaleEffect(64 / full).frame(width: 64, height: 64) }
    }.padding(20).background(Color(white: 0.18))
    try! NSBitmapImageRep(cgImage: cg(dock, scale: 2)).representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent("dock.png"))
    print("ok")
}
