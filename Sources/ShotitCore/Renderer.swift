import AppKit
import CoreImage

/// Draws a document into a context with a top-left origin (y points down).
/// The editor view and the PNG export both use this, so the export matches the screen.
public enum Renderer {
    public static func lineWidth(_ a: Annotation, scale: CGFloat) -> CGFloat {
        if case .highlighter = a.kind { return a.style.width.rawValue * 5 * scale }
        return a.style.width.rawValue * scale
    }

    public static func stepRadius(_ s: Style, scale: CGFloat) -> CGFloat { s.fontSize.rawValue * 0.75 * scale }

    /// Sketchy styles use a hand-drawn system font. Clean uses SF Rounded.
    public static func font(_ s: Style, scale: CGFloat) -> NSFont {
        let size = s.fontSize.rawValue * scale
        if s.roughness != .clean, let f = NSFont(name: "ChalkboardSE-Regular", size: size) { return f }
        return rounded(size, .semibold)
    }

    public static func textAttributes(_ s: Style, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(s, scale: scale), .foregroundColor: NSColor(cgColor: s.color.cgColor) ?? .red]
    }

    public static func textSize(_ text: String, style: Style, scale: CGFloat) -> CGSize {
        var str = text.isEmpty ? " " : text
        if str.hasSuffix("\n") { str += " " }
        let r = (str as NSString).boundingRect(with: CGSize(width: 1e6, height: 1e6), options: [.usesLineFragmentOrigin],
                                               attributes: textAttributes(style, scale: scale))
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    /// Pixelated copy of the image, same size. Blur regions draw from it.
    public static func pixelate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let out = ci.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 10 * scale, kCIInputCenterKey: CIVector(x: 0, y: 0)])
            .cropped(to: ci.extent)
        return CIContext().createCGImage(out, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace)
    }

    public static func draw(_ doc: Document, in ctx: CGContext, pixelated: CGImage?, clip: Bool, hiding hidden: UUID? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if clip {
            ctx.clip(to: doc.frame)
            if let bg = doc.background {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(doc.frame)
            }
        }
        drawImage(doc.image, in: doc.imageRect, ctx)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        var spots: [CGRect] = []
        for a in doc.annotations where a.id != hidden {
            if case .spotlight(let r) = a.kind { spots.append(r); continue }
            draw(a, doc: doc, pixelated: pixelated, ctx: ctx)
        }
        // All spotlights share one dim layer, so each one is a clear hole.
        if !spots.isEmpty {
            let path = CGMutablePath()
            path.addRect(doc.frame.union(doc.imageRect))
            for r in spots where r.width > 0 && r.height > 0 {
                let c = min(8 * doc.scale, r.width / 2, r.height / 2)
                path.addRoundedRect(in: r, cornerWidth: c, cornerHeight: c)
            }
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillPath(using: .evenOdd)
        }
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func draw(_ a: Annotation, doc: Document, pixelated: CGImage?, ctx: CGContext) {
        let s = a.style, scale = doc.scale, w = lineWidth(a, scale: scale)
        let rough = s.roughness.rawValue
        var rng = SeededRandom(seed: a.seed)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(s.color.cgColor)
        ctx.setFillColor(s.color.cgColor)
        if s.dashed { ctx.setLineDash(phase: 0, lengths: [w * 1.5, w * 2.5]) }

        switch a.kind {
        case .rect(let r):
            let c = min(6 * scale, r.width / 2, r.height / 2)
            let clean = CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
            fill(clean, a, w: w, scale: scale, rng: &rng, ctx)
            stroke(rough > 0 ? Rough.rectangle(r, roughness: rough, unit: scale, rng: &rng) : clean, ctx)

        case .ellipse(let r):
            let clean = CGPath(ellipseIn: r, transform: nil)
            fill(clean, a, w: w, scale: scale, rng: &rng, ctx)
            stroke(rough > 0 ? Rough.ellipse(r, roughness: rough, unit: scale, rng: &rng) : clean, ctx)

        case .line(let p, let q):
            let path = CGMutablePath()
            if rough > 0 { Rough.line(p, q, roughness: rough, unit: scale, rng: &rng, into: path) } else {
                path.move(to: p); path.addLine(to: q)
            }
            stroke(path, ctx)

        case .arrow(let p, let q):
            drawArrow(p, q, style: s, w: w, scale: scale, rng: &rng, ctx)

        case .pen(let pts):
            stroke(smooth(pts), ctx)

        case .highlighter(let pts):
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.square)
            stroke(smooth(pts), ctx)

        case .text(let p, let str):
            let size = textSize(str, style: s, scale: scale)
            (str as NSString).draw(with: CGRect(origin: p, size: size), options: [.usesLineFragmentOrigin],
                                   attributes: textAttributes(s, scale: scale))

        case .step(let c, let n):
            let r = stepRadius(s, scale: scale)
            let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.setShadow(offset: CGSize(width: 0, height: 1 * scale), blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.3))
            ctx.fillEllipse(in: disc)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1.5 * scale)
            ctx.strokeEllipse(in: disc.insetBy(dx: 0.75 * scale, dy: 0.75 * scale))
            let label = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: rounded(r * 1.1, .bold), .foregroundColor: NSColor.white]
            let ls = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: c.x - ls.width / 2, y: c.y - ls.height / 2), withAttributes: attrs)

        case .blur(let r):
            let c = min(4 * scale, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil))
            ctx.clip()
            if let px = pixelated { drawImage(px, in: doc.imageRect, ctx) } else {
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
                ctx.fill(r)
            }

        case .spotlight:
            break
        }
    }

    private static func stroke(_ path: CGPath, _ ctx: CGContext) {
        ctx.addPath(path)
        ctx.strokePath()
    }

    private static func fill(_ shape: CGPath, _ a: Annotation, w: CGFloat, scale: CGFloat,
                             rng: inout SeededRandom, _ ctx: CGContext) {
        switch a.style.fill {
        case .none:
            return
        case .solid, .translucent:
            ctx.saveGState()
            ctx.setFillColor(a.style.color.alpha(a.style.fill == .solid ? 1 : 0.25).cgColor)
            ctx.addPath(shape)
            ctx.fillPath()
            ctx.restoreGState()
        case .hachure:
            // Parallel lines at -41 degrees, as in Excalidraw, clipped to the shape.
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.setLineDash(phase: 0, lengths: [])
            let lw = max(1 * scale, w / 2)
            let gap = max(4 * scale, lw * 4)
            let b = shape.boundingBox
            let angle = -41 * CGFloat.pi / 180
            let d = CGPoint(x: cos(angle), y: sin(angle)), n = CGPoint(x: -d.y, y: d.x)
            let half = hypot(b.width, b.height) / 2
            let path = CGMutablePath()
            var o = -half
            while o <= half {
                let m = CGPoint(x: b.midX + n.x * o, y: b.midY + n.y * o)
                let p = CGPoint(x: m.x - d.x * half, y: m.y - d.y * half)
                let q = CGPoint(x: m.x + d.x * half, y: m.y + d.y * half)
                if a.style.roughness != .clean {
                    Rough.line(p, q, roughness: a.style.roughness.rawValue, unit: scale, rng: &rng, into: path, double: false)
                } else {
                    path.move(to: p); path.addLine(to: q)
                }
                o += gap
            }
            ctx.setLineWidth(lw)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private static func drawArrow(_ p: CGPoint, _ q: CGPoint, style s: Style, w: CGFloat, scale: CGFloat,
                                  rng: inout SeededRandom, _ ctx: CGContext) {
        let len = hypot(q.x - p.x, q.y - p.y)
        guard len > 0.5 else { return }
        let dir = CGPoint(x: (q.x - p.x) / len, y: (q.y - p.y) / len)
        let angle = atan2(dir.y, dir.x)
        if s.roughness != .clean {
            // Excalidraw style: shaft plus an open V head.
            let head = min((12 + s.width.rawValue * 2.5) * scale, len * 0.5)
            let path = CGMutablePath()
            Rough.line(p, q, roughness: s.roughness.rawValue, unit: scale, rng: &rng, into: path)
            for side: CGFloat in [-1, 1] {
                let a = angle + .pi + side * 0.45
                let tip = CGPoint(x: q.x + cos(a) * head, y: q.y + sin(a) * head)
                Rough.line(q, tip, roughness: s.roughness.rawValue, unit: scale, rng: &rng, into: path)
            }
            stroke(path, ctx)
        } else {
            // Skitch style: shaft plus a filled head.
            let head = min((8 + s.width.rawValue * 3) * scale, len * 0.6)
            let half = head * 0.6
            let base = CGPoint(x: q.x - dir.x * head, y: q.y - dir.y * head)
            let shaftEnd = CGPoint(x: q.x - dir.x * head * 0.7, y: q.y - dir.y * head * 0.7)
            let shaft = CGMutablePath()
            shaft.move(to: p)
            shaft.addLine(to: shaftEnd)
            stroke(shaft, ctx)
            let tri = CGMutablePath()
            tri.move(to: q)
            tri.addLine(to: CGPoint(x: base.x - dir.y * half, y: base.y + dir.x * half))
            tri.addLine(to: CGPoint(x: base.x + dir.y * half, y: base.y - dir.x * half))
            tri.closeSubpath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(w * 0.5)
            ctx.addPath(tri)
            ctx.drawPath(using: .fillStroke)
        }
    }

    /// Quadratic curves through the midpoints of the samples.
    static func smooth(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            if pts.count == 1 { path.addLine(to: first) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }
}
