import CoreGraphics

/// Port of the rough.js line and ellipse algorithms (MIT, https://github.com/rough-stuff/rough).
/// `unit` is image pixels per point, so the wobble has the same size on screen at any scale.
public enum Rough {
    private static let maxOffset: CGFloat = 2
    private static let bowing: CGFloat = 1

    private static func offset(_ lo: CGFloat, _ hi: CGFloat, _ r: CGFloat, _ rng: inout SeededRandom,
                               _ gain: CGFloat = 1) -> CGFloat {
        r * gain * (rng.next() * (hi - lo) + lo)
    }

    private static func offset(_ x: CGFloat, _ r: CGFloat, _ rng: inout SeededRandom, _ gain: CGFloat = 1) -> CGFloat {
        offset(-x, x, r, &rng, gain)
    }

    /// A line as two wobbly strokes (or one when `double` is false).
    public static func line(_ p1: CGPoint, _ p2: CGPoint, roughness r: CGFloat, unit: CGFloat,
                     rng: inout SeededRandom, into path: CGMutablePath, double: Bool = true) {
        segment(p1, p2, r, unit, &rng, path, overlay: false)
        if double { segment(p1, p2, r, unit, &rng, path, overlay: true) }
    }

    private static func segment(_ p1: CGPoint, _ p2: CGPoint, _ r: CGFloat, _ unit: CGFloat,
                                _ rng: inout SeededRandom, _ path: CGMutablePath, overlay: Bool) {
        let lenSq = (p1.x - p2.x) * (p1.x - p2.x) + (p1.y - p2.y) * (p1.y - p2.y)
        let len = sqrt(lenSq)
        let l1 = len / unit
        let gain: CGFloat = l1 < 200 ? 1 : (l1 > 500 ? 0.4 : -0.0016668 * l1 + 1.233334)
        var off = maxOffset * unit
        if off * off * 100 > lenSq { off = len / 10 }
        let o = overlay ? off / 2 : off
        let diverge = 0.2 + rng.next() * 0.2
        let midX = offset(bowing * maxOffset * unit * (p2.y - p1.y) / 200, r, &rng, gain)
        let midY = offset(bowing * maxOffset * unit * (p1.x - p2.x) / 200, r, &rng, gain)
        var g = rng
        func rnd() -> CGFloat { offset(o, r, &g, gain) }
        path.move(to: CGPoint(x: p1.x + rnd(), y: p1.y + rnd()))
        let c1 = CGPoint(x: midX + p1.x + (p2.x - p1.x) * diverge + rnd(),
                         y: midY + p1.y + (p2.y - p1.y) * diverge + rnd())
        let c2 = CGPoint(x: midX + p1.x + 2 * (p2.x - p1.x) * diverge + rnd(),
                         y: midY + p1.y + 2 * (p2.y - p1.y) * diverge + rnd())
        let end = CGPoint(x: p2.x + rnd(), y: p2.y + rnd())
        path.addCurve(to: end, control1: c1, control2: c2)
        rng = g
    }

    public static func rectangle(_ rect: CGRect, roughness r: CGFloat, unit: CGFloat, rng: inout SeededRandom) -> CGPath {
        let path = CGMutablePath()
        let c = rect.corners
        for i in 0..<4 { line(c[i], c[(i + 1) % 4], roughness: r, unit: unit, rng: &rng, into: path) }
        return path
    }

    public static func ellipse(_ rect: CGRect, roughness r: CGFloat, unit: CGFloat, rng: inout SeededRandom) -> CGPath {
        let path = CGMutablePath()
        let cx = rect.midX, cy = rect.midY
        var rx = rect.width / 2, ry = rect.height / 2
        let psq = sqrt(.pi * 2 * sqrt(((rx / unit) * (rx / unit) + (ry / unit) * (ry / unit)) / 2))
        let steps = ceil(max(9, (9 / sqrt(200)) * psq))
        let inc = 2 * .pi / steps
        let fitRandomness: CGFloat = 1 - 0.95
        rx += offset(rx * fitRandomness, r, &rng)
        ry += offset(ry * fitRandomness, r, &rng)
        let overlap = inc * offset(0.1, offset(0.4, 1, r, &rng), r, &rng)
        curve(points(inc, cx, cy, rx, ry, 1 * unit, overlap, r, &rng), path)
        curve(points(inc, cx, cy, rx, ry, 1.5 * unit, 0, r, &rng), path)
        return path
    }

    private static func points(_ inc: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                               _ off: CGFloat, _ overlap: CGFloat, _ r: CGFloat,
                               _ rng: inout SeededRandom) -> [CGPoint] {
        let start = offset(0.5, r, &rng) - .pi / 2
        var pts: [CGPoint] = []
        func add(_ k: CGFloat, _ angle: CGFloat) {
            pts.append(CGPoint(x: offset(off, r, &rng) + cx + k * rx * cos(angle),
                               y: offset(off, r, &rng) + cy + k * ry * sin(angle)))
        }
        add(0.9, start - inc)
        var angle = start
        while angle < 2 * .pi + start - 0.01 {
            add(1, angle)
            angle += inc
        }
        add(1, start + 2 * .pi + overlap * 0.5)
        add(0.98, start + overlap)
        add(0.9, start + overlap * 0.5)
        return pts
    }

    /// Catmull-Rom spline through the points, as cubic Bezier segments.
    private static func curve(_ p: [CGPoint], _ path: CGMutablePath) {
        guard p.count >= 4 else { return }
        path.move(to: p[1])
        for i in 1..<(p.count - 2) {
            let c1 = CGPoint(x: p[i].x + (p[i + 1].x - p[i - 1].x) / 6, y: p[i].y + (p[i + 1].y - p[i - 1].y) / 6)
            let c2 = CGPoint(x: p[i + 1].x + (p[i].x - p[i + 2].x) / 6, y: p[i + 1].y + (p[i].y - p[i + 2].y) / 6)
            path.addCurve(to: p[i + 1], control1: c1, control2: c2)
        }
    }
}
