import CoreGraphics

public extension CGRect {
    /// The standardized rect between two corner points.
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Top-left, top-right, bottom-right, bottom-left (y points down).
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }

    /// Corners and edge midpoints, clockwise from top-left.
    var frameHandles: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: midX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: midY),
         CGPoint(x: maxX, y: maxY), CGPoint(x: midX, y: maxY), CGPoint(x: minX, y: maxY), CGPoint(x: minX, y: midY)]
    }

    /// Moves the edges that belong to frame handle `i` to `p`. The rect never inverts.
    func draggingFrameHandle(_ i: Int, to p: CGPoint) -> CGRect {
        var x0 = minX, x1 = maxX, y0 = minY, y1 = maxY
        if [0, 6, 7].contains(i) { x0 = min(p.x, x1 - 1) }
        if [2, 3, 4].contains(i) { x1 = max(p.x, x0 + 1) }
        if [0, 1, 2].contains(i) { y0 = min(p.y, y1 - 1) }
        if [4, 5, 6].contains(i) { y1 = max(p.y, y0 + 1) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
    }
}

/// Quick-access cards sit in a centered row at the top of the screen, under the menu bar.
/// This is away from the macOS screenshot thumbnail, which is at the bottom right.
public enum ThumbnailLayout {
    /// How many cards fit side by side in `area`.
    public static func capacity(size: CGSize, in area: CGRect, gap: CGFloat) -> Int {
        max(1, Int((area.width + gap) / (size.width + gap)))
    }

    /// Frames in AppKit screen coordinates (y points up), oldest on the left.
    public static func frames(count: Int, size: CGSize, in area: CGRect, gap: CGFloat = 0) -> [CGRect] {
        let total = CGFloat(count) * size.width + CGFloat(max(0, count - 1)) * gap
        let x0 = (area.midX - total / 2).rounded()
        return (0..<count).map {
            CGRect(x: x0 + CGFloat($0) * (size.width + gap), y: area.maxY - size.height, width: size.width, height: size.height)
        }
    }
}

public func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Snaps `p` so the segment from `o` is at a multiple of 15 degrees.
public func snapAngle(_ p: CGPoint, from o: CGPoint) -> CGPoint {
    let step = CGFloat.pi / 12
    let angle = (atan2(p.y - o.y, p.x - o.x) / step).rounded() * step
    let len = hypot(p.x - o.x, p.y - o.y)
    return CGPoint(x: o.x + cos(angle) * len, y: o.y + sin(angle) * len)
}

/// Moves `p` so the rect from `o` to `p` is a square.
public func squareCorner(_ p: CGPoint, from o: CGPoint) -> CGPoint {
    let s = max(abs(p.x - o.x), abs(p.y - o.y))
    return CGPoint(x: o.x + (p.x >= o.x ? s : -s), y: o.y + (p.y >= o.y ? s : -s))
}

public extension Annotation.Kind {
    var rect: CGRect? {
        switch self {
        case .rect(let r), .ellipse(let r), .blur(let r), .spotlight(let r): return r
        default: return nil
        }
    }

    func with(rect r: CGRect) -> Self {
        switch self {
        case .rect: return .rect(r)
        case .ellipse: return .ellipse(r)
        case .blur: return .blur(r)
        case .spotlight: return .spotlight(r)
        default: return self
        }
    }

    var endpoints: (CGPoint, CGPoint)? {
        switch self {
        case .line(let a, let b), .arrow(let a, let b): return (a, b)
        default: return nil
        }
    }

    func with(endpoints a: CGPoint, _ b: CGPoint) -> Self {
        switch self {
        case .line: return .line(a, b)
        case .arrow: return .arrow(a, b)
        default: return self
        }
    }
}

public extension Annotation {
    func bounds(scale: CGFloat) -> CGRect {
        switch kind {
        case .rect(let r), .ellipse(let r), .blur(let r), .spotlight(let r): return r
        case .line(let a, let b), .arrow(let a, let b): return CGRect(corner: a, b)
        case .pen(let pts), .highlighter(let pts):
            guard let f = pts.first else { return .null }
            return pts.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        case .text(let p, let s): return CGRect(origin: p, size: Renderer.textSize(s, style: style, scale: scale))
        case .step(let c, _):
            let r = Renderer.stepRadius(style, scale: scale)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
    }

    /// `tolerance` is in image pixels.
    func hitTest(_ p: CGPoint, tolerance t: CGFloat, scale: CGFloat) -> Bool {
        let w = Renderer.lineWidth(self, scale: scale) / 2 + t
        switch kind {
        case .rect(let r):
            let outer = r.insetBy(dx: -w, dy: -w)
            if style.fill != .none { return outer.contains(p) }
            return outer.contains(p) && !r.insetBy(dx: w, dy: w).contains(p)
        case .ellipse(let r):
            let rx = r.width / 2, ry = r.height / 2
            guard rx > 0, ry > 0 else { return r.insetBy(dx: -w, dy: -w).contains(p) }
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let d = sqrt(nx * nx + ny * ny)
            if style.fill != .none, d <= 1 { return true }
            return abs(d - 1) * min(rx, ry) <= w
        case .blur(let r), .spotlight(let r):
            return r.contains(p)
        case .line(let a, let b), .arrow(let a, let b):
            return distance(p, toSegment: a, b) <= w
        case .pen(let pts), .highlighter(let pts):
            if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) <= w }
            return zip(pts, pts.dropFirst()).contains { distance(p, toSegment: $0, $1) <= w }
        case .text, .step:
            return bounds(scale: scale).insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    func moved(dx: CGFloat, dy: CGFloat) -> Annotation {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        var a = self
        switch kind {
        case .rect(let r), .ellipse(let r), .blur(let r), .spotlight(let r): a.kind = kind.with(rect: r.offsetBy(dx: dx, dy: dy))
        case .line(let p, let q), .arrow(let p, let q): a.kind = kind.with(endpoints: m(p), m(q))
        case .pen(let pts): a.kind = .pen(pts.map(m))
        case .highlighter(let pts): a.kind = .highlighter(pts.map(m))
        case .text(let p, let s): a.kind = .text(m(p), s)
        case .step(let c, let n): a.kind = .step(m(c), n)
        }
        return a
    }

    /// Drag points: rect corners, or line endpoints. Other kinds only move.
    var handles: [CGPoint] {
        if let r = kind.rect { return r.corners }
        if let (a, b) = kind.endpoints { return [a, b] }
        return []
    }

    /// Moves handle `i` to `p`. The opposite corner or endpoint stays fixed.
    func movingHandle(_ i: Int, to p: CGPoint, constrain: Bool) -> Annotation {
        var a = self
        if let r = kind.rect {
            let fixed = r.corners[(i + 2) % 4]
            let q = constrain ? squareCorner(p, from: fixed) : p
            a.kind = kind.with(rect: CGRect(corner: fixed, q))
        } else if let (s, e) = kind.endpoints {
            let fixed = i == 0 ? e : s
            let q = constrain ? snapAngle(p, from: fixed) : p
            a.kind = i == 0 ? kind.with(endpoints: q, e) : kind.with(endpoints: s, q)
        }
        return a
    }
}
