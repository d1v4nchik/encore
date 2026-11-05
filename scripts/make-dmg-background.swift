// Renders the DMG window background: swift make-dmg-background.swift <out-dir>
// Writes background.png (640×400) and background@2x.png; make-dmg.sh merges them into a TIFF.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let W: CGFloat = 640, H: CGFloat = 400
// Icon centers in Finder coordinates (top-left origin) – must match make-dmg.sh.
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 200

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    func y(_ top: CGFloat) -> CGFloat { H - top }   // Finder top-left → AppKit bottom-left

    // Soft frosted backdrop
    NSGradient(colors: [NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1),
                        NSColor(red: 0.91, green: 0.93, blue: 0.97, alpha: 1)])!
        .draw(in: CGRect(x: 0, y: 0, width: W, height: H), angle: -90)
    for (cx, cy, r, color) in [
        (90.0, 70.0, 220.0, NSColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 0.16)),
        (560.0, 330.0, 260.0, NSColor(red: 0.62, green: 0.42, blue: 1.0, alpha: 0.13)),
    ] as [(CGFloat, CGFloat, CGFloat, NSColor)] {
        NSGradient(colors: [color, color.withAlphaComponent(0)])!
            .draw(in: NSBezierPath(ovalIn: CGRect(x: cx - r, y: y(cy) - r, width: r * 2, height: r * 2)),
                  relativeCenterPosition: .zero)
    }

    // Title
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let h = str.size().height
        str.draw(in: CGRect(x: 0, y: y(top) - h, width: W, height: h))
    }
    text("Encore", size: 26, weight: .bold, color: NSColor(white: 0.12, alpha: 1), top: 34)
    text("for OPPO Enco earbuds", size: 13, weight: .medium, color: NSColor(white: 0.45, alpha: 1), top: 68)

    // Arrow between the two icons
    let arrowY = y(iconY - 6)
    let start = appX + 78, end = appsX - 78
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: start, y: arrowY))
    shaft.line(to: CGPoint(x: end - 10, y: arrowY))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    let arrowColor = NSColor(red: 0.04, green: 0.48, blue: 1.0, alpha: 0.75)
    arrowColor.setStroke()
    ctx.saveGState()
    ctx.setLineDash(phase: 0, lengths: [0.1, 12])
    shaft.stroke()
    ctx.restoreGState()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: end - 16, y: arrowY + 12))
    head.line(to: CGPoint(x: end, y: arrowY))
    head.line(to: CGPoint(x: end - 16, y: arrowY - 12))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Footer help
    text("Drag Encore into Applications, then open it from Launchpad.", size: 13, weight: .medium,
         color: NSColor(white: 0.25, alpha: 1), top: 318)
    text("First launch: if macOS blocks it, open System Settings → Privacy & Security → Open Anyway.",
         size: 11, weight: .regular, color: NSColor(white: 0.45, alpha: 1), top: 344)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("DMG background written to \(outDir.path)")
