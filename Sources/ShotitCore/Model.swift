import CoreGraphics
import Foundation

public struct RGBA: Equatable, Hashable {
    public var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

    public init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, a: CGFloat = 1) {
        self.init(r: CGFloat((hex >> 16) & 0xFF) / 255,
                  g: CGFloat((hex >> 8) & 0xFF) / 255,
                  b: CGFloat(hex & 0xFF) / 255, a: a)
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public func alpha(_ a: CGFloat) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }
}

/// Excalidraw stroke palette, plus white for dark screenshots.
public enum Palette {
    public static let black = RGBA(hex: 0x1E1E1E)
    public static let red = RGBA(hex: 0xE03131)
    public static let orange = RGBA(hex: 0xF08C00)
    public static let yellow = RGBA(hex: 0xFFD43B)
    public static let green = RGBA(hex: 0x2F9E44)
    public static let blue = RGBA(hex: 0x1971C2)
    public static let white = RGBA(hex: 0xFFFFFF)
    public static let strokes = [black, red, orange, yellow, green, blue, white]
    /// `nil` is a transparent background.
    public static let backgrounds: [RGBA?] = [nil, white, RGBA(hex: 0xF1F3F5), RGBA(hex: 0xFFEC99),
                                              RGBA(hex: 0xA5D8FF), RGBA(hex: 0x343A40)]
}

public enum StrokeWidth: CGFloat, CaseIterable { case thin = 2, bold = 4, extraBold = 8 }
public enum FillStyle: CaseIterable { case none, hachure, translucent, solid }
public enum Roughness: CGFloat, CaseIterable { case clean = 0, sketchy = 1, wild = 2 }
public enum FontSize: CGFloat, CaseIterable { case s = 16, m = 24, l = 36, xl = 56 }

/// Sizes are in points. The renderer multiplies them by the document scale.
public struct Style: Equatable {
    public var color = Palette.red
    public var width = StrokeWidth.bold
    public var dashed = false
    public var fill = FillStyle.none
    public var roughness = Roughness.sketchy
    public var fontSize = FontSize.m
    public init() {}
}

public struct Annotation: Identifiable, Equatable {
    public enum Kind: Equatable {
        case rect(CGRect), ellipse(CGRect), blur(CGRect), spotlight(CGRect)
        case line(CGPoint, CGPoint), arrow(CGPoint, CGPoint)
        case pen([CGPoint]), highlighter([CGPoint])
        /// Top-left corner and text.
        case text(CGPoint, String)
        /// Center and number.
        case step(CGPoint, Int)
    }

    public let id: UUID
    public var kind: Kind
    public var style: Style
    /// Seed for the sketchy wobble, so a shape looks the same on every redraw.
    public var seed: UInt64

    public init(kind: Kind, style: Style, seed: UInt64 = .random(in: 1...UInt64.max)) {
        id = UUID()
        self.kind = kind
        self.style = style
        self.seed = seed
    }
}

/// The part of a document that undo restores.
public struct EditState: Equatable {
    public var annotations: [Annotation]
    public var frame: CGRect
    public var background: RGBA?
}

/// Grid spacing is in points and lines align with the image origin, so the grid measures image content.
/// The export draws the grid only when it is also visible, so the export matches the screen.
public struct Grid: Equatable {
    public static let spacings: [CGFloat] = [8, 16, 32, 64]
    public var visible = false
    public var spacing: CGFloat = 16
    public var inExport = false
    public init() {}
    public var exported: Bool { visible && inExport }
}

public struct Document {
    public let image: CGImage
    /// Image pixels per point (2 for a Retina screenshot).
    public let scale: CGFloat
    public var annotations: [Annotation] = []
    /// Output area in image pixels. Smaller than the image is a crop. Larger is an extend.
    public var frame: CGRect
    /// Fill for the area outside the image. `nil` is transparent.
    public var background: RGBA? = Palette.white
    /// View setting, not part of undo.
    public var grid = Grid()

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        frame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }

    public var imageRect: CGRect { CGRect(x: 0, y: 0, width: image.width, height: image.height) }

    public var nextStep: Int {
        let used = annotations.compactMap { a -> Int? in
            if case .step(_, let n) = a.kind { return n }
            return nil
        }
        return (used.max() ?? 0) + 1
    }

    public var state: EditState {
        get { EditState(annotations: annotations, frame: frame, background: background) }
        set { annotations = newValue.annotations; frame = newValue.frame; background = newValue.background }
    }
}

/// Snapshot undo. Call `checkpoint` before a change and `commit` after it.
/// `commit` drops the checkpoint when nothing changed, so a plain click adds no undo step.
public struct History<State: Equatable> {
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func checkpoint(_ state: State) {
        undoStack.append(state)
        if undoStack.count > limit { undoStack.removeFirst() }
    }

    public mutating func commit(_ current: State) {
        guard let last = undoStack.last else { return }
        if last == current { undoStack.removeLast() } else { redoStack.removeAll() }
    }

    public mutating func undo(_ current: State) -> State? {
        guard let s = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return s
    }

    public mutating func redo(_ current: State) -> State? {
        guard let s = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return s
    }
}

/// SplitMix64. Deterministic, so sketchy shapes do not change between redraws.
public struct SeededRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }
}
