// Writes macOS's own cursors as PNGs at 10x (the promo draws them enlarged, Screen Studio style).
//   swiftc -O cursors.swift -o build/cursors && build/cursors assets/cursors
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cursors: [(String, NSCursor)] = [("arrow", .arrow), ("crosshair", .crosshair), ("ibeam", .iBeam), ("pointinghand", .pointingHand)]
let scale: CGFloat = 10
for (name, cursor) in cursors {
    let image = cursor.image
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print(name, image.size, cursor.hotSpot)
}
