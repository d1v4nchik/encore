// Renders Encore's app icon into an .iconset folder: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with continuous corners.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.white.setFill()
    shape.fill()
    ctx.restoreGState()

    // Frosted white glass gradient
    ctx.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(red: 0.98, green: 0.99, blue: 1.00, alpha: 1),
        NSColor(red: 0.90, green: 0.93, blue: 0.98, alpha: 1),
        NSColor(red: 0.80, green: 0.85, blue: 0.95, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    gradient.draw(in: body, angle: -60)

    // Glassy blobs
    for (cx, cy, r, a) in [(0.30, 0.78, 0.50, 0.55), (0.80, 0.22, 0.40, 0.35)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
        let rect = CGRect(x: body.minX + body.width * cx - body.width * r / 2,
                          y: body.minY + body.height * cy - body.width * r / 2,
                          width: body.width * r, height: body.width * r)
        let g = NSGradient(colors: [NSColor.white.withAlphaComponent(a), NSColor.white.withAlphaComponent(0)])!
        g.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)
    }

    // Top specular sheen
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.38), NSColor.white.withAlphaComponent(0)])!
    sheen.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    // Rim light
    NSColor.white.withAlphaComponent(0.45).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: radius, yRadius: radius)
    rim.lineWidth = max(s * 0.006, 0.5)
    rim.stroke()

    // Earbuds glyph
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .regular)
        .applying(.init(paletteColors: [NSColor(red: 0.04, green: 0.48, blue: 1.0, alpha: 1),
                                        NSColor(red: 0.45, green: 0.38, blue: 0.98, alpha: 1)]))
    if let glyph = NSImage(systemSymbolName: "earbuds", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let g = glyph.size
        let rect = CGRect(x: (s - g.width) / 2, y: (s - g.height) / 2 - s * 0.01, width: g.width, height: g.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                      color: NSColor(red: 0.05, green: 0.2, blue: 0.6, alpha: 0.30).cgColor)
        glyph.draw(in: rect)
        ctx.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("Icon written to \(out.path)")
