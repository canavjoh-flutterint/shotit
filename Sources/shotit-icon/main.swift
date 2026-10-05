import AppKit
import ShotitCore

// Writes the app icon as a macOS .iconset folder. scripts/bundle.py turns it into AppIcon.icns.
// The icon is a tilted screenshot card with a sketchy box and arrow, drawn by the app's own renderer.
// Usage: shotit-icon <output.iconset>

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// A plain app window: title bar, traffic lights, and gray lines of text.
func fakeScreenshot() -> CGImage {
    let w = 560, h = 400
    let ctx = context(w, h)
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(RGBA(hex: 0xF1F3F5).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: 56))
    for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(RGBA(hex: UInt32(hex)).cgColor)
        ctx.fillEllipse(in: CGRect(x: 26 + i * 34, y: 18, width: 20, height: 20))
    }
    ctx.setFillColor(RGBA(hex: 0xCED4DA).cgColor)
    for (y, width) in [(96, 300), (146, 420), (196, 360), (290, 400), (340, 250)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 40, y: y, width: width, height: 22), cornerWidth: 11, cornerHeight: 11,
                           transform: nil))
    }
    ctx.fillPath()
    return ctx.makeImage()!
}

func annotatedCard() -> CGImage {
    // Scale 1.7 makes the strokes heavier, so the box and arrow stay visible at 32 px in the ⌘Tab switcher.
    var doc = Document(image: fakeScreenshot(), scale: 1.7)
    var style = Style()
    style.color = Palette.red
    style.width = .extraBold
    style.roughness = .sketchy
    doc.annotations = [
        Annotation(kind: .rect(CGRect(x: 24, y: 128, width: 460, height: 112)), style: style, seed: 11),
        Annotation(kind: .arrow(CGPoint(x: 500, y: 370), CGPoint(x: 380, y: 256)), style: style, seed: 5),
    ]
    return Exporter.render(doc, pixelated: nil)!
}

/// 1024 px master in the macOS icon grid: an 824 px rounded square with a drop shadow.
func master() -> CGImage {
    let n: CGFloat = 1024
    let ctx = context(Int(n), Int(n))
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(RGBA(hex: 0x5650C8).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: [RGBA(hex: 0x8B87F0).cgColor, RGBA(hex: 0x5650C8).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // The card: white paper with a margin, tilted like the quick-access card.
    let card = annotatedCard()
    let size = CGSize(width: 640, height: CGFloat(card.height) * 640 / CGFloat(card.width))
    ctx.translateBy(x: n / 2, y: n / 2 + 10)
    ctx.rotate(by: 6 * .pi / 180)
    let paper = CGRect(x: -size.width / 2 - 18, y: -size.height / 2 - 18, width: size.width + 36, height: size.height + 36)
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(CGPath(roundedRect: paper, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.interpolationQuality = .high
    ctx.draw(card, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    ctx.restoreGState()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, size: Int, to url: URL) {
    let ctx = context(size, size)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else { fatalError("usage: shotit-icon <output.iconset>") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let icon = master()
for points in [16, 32, 128, 256, 512] {
    writePNG(icon, size: points, to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(icon, size: points * 2, to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
