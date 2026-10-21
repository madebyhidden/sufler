// Рисует значок приложения: `swift make_icon.swift` → AppIcon.icns рядом.
import AppKit

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Подложка в форме значков macOS: скруглённый квадрат с полями
    let plate = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor(red: 0.30, green: 0.27, blue: 0.86, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 0.47, green: 0.40, blue: 0.98, alpha: 1),
        NSColor(red: 0.27, green: 0.24, blue: 0.80, alpha: 1),
    ])!.draw(in: plate, angle: -90)
    // Мягкий блик сверху
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)

    // Реплика-«пузырь» с хвостиком
    let bubble = NSBezierPath(roundedRect: NSRect(x: 232 * s, y: 372 * s, width: 560 * s, height: 400 * s), xRadius: 120 * s, yRadius: 120 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330 * s, y: 400 * s))
    tail.curve(to: NSPoint(x: 296 * s, y: 262 * s), controlPoint1: NSPoint(x: 340 * s, y: 330 * s), controlPoint2: NSPoint(x: 320 * s, y: 286 * s))
    tail.curve(to: NSPoint(x: 470 * s, y: 380 * s), controlPoint1: NSPoint(x: 380 * s, y: 280 * s), controlPoint2: NSPoint(x: 440 * s, y: 330 * s))
    tail.close()
    NSColor.white.setFill()
    bubble.fill()
    tail.fill()

    // Внутри — звуковая волна: пять столбиков
    let heights: [CGFloat] = [110, 210, 290, 180, 90]
    let barW: CGFloat = 54, gap: CGFloat = 38
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (1024 - total) / 2
    for (i, h) in heights.enumerated() {
        let r = NSRect(x: x * s, y: (572 - h / 2) * s, width: barW * s, height: h * s)
        NSColor(red: 0.36, green: 0.32, blue: 0.92, alpha: i == 2 ? 1 : 0.82).setFill()
        NSBezierPath(roundedRect: r, xRadius: barW / 2 * s, yRadius: barW / 2 * s).fill()
        x += barW + gap
    }
    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(draw(CGFloat(px)), px).write(to: set.appendingPathComponent(name))
    }
}
try! png(draw(1024), 1024).write(to: URL(fileURLWithPath: "icon_preview.png"))
