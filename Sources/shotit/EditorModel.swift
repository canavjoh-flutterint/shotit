import AppKit
import Combine
import ShotitCore

enum Tool: String, CaseIterable, Identifiable {
    case select, rect, ellipse, arrow, line, pen, text, highlighter, blur, step, spotlight, crop

    var id: String { rawValue }

    /// Single-key shortcut, Excalidraw style.
    var key: Character {
        switch self {
        case .select: "v"
        case .rect: "r"
        case .ellipse: "o"
        case .arrow: "a"
        case .line: "l"
        case .pen: "p"
        case .text: "t"
        case .highlighter: "h"
        case .blur: "b"
        case .step: "n"
        case .spotlight: "s"
        case .crop: "c"
        }
    }

    var number: Character? {
        switch self {
        case .select: "1"
        case .rect: "2"
        case .ellipse: "3"
        case .arrow: "4"
        case .line: "5"
        case .pen: "6"
        case .text: "7"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .text: "textformat"
        case .highlighter: "highlighter"
        case .blur: "eye.slash"
        case .step: "1.circle"
        case .spotlight: "flashlight.on.fill"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .line: "Line"
        case .pen: "Pen"
        case .text: "Text"
        case .highlighter: "Highlighter"
        case .blur: "Blur"
        case .step: "Number step"
        case .spotlight: "Spotlight"
        case .crop: "Crop and extend"
        }
    }

    static func of(_ kind: Annotation.Kind) -> Tool {
        switch kind {
        case .rect: .rect
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .pen: .pen
        case .text: .text
        case .highlighter: .highlighter
        case .blur: .blur
        case .step: .step
        case .spotlight: .spotlight
        }
    }

    enum Section { case color, width, dash, fill, roughness, fontSize }

    /// Property panel sections for this tool.
    var sections: [Section] {
        switch self {
        case .rect, .ellipse: [.color, .width, .dash, .fill, .roughness]
        case .arrow, .line: [.color, .width, .dash, .roughness]
        case .pen, .highlighter: [.color, .width]
        case .text: [.color, .fontSize, .roughness]
        case .step: [.color, .fontSize]
        case .select, .blur, .spotlight, .crop: []
        }
    }

    var defaultStyle: Style {
        var s = Style()
        if self == .highlighter { s.color = Palette.yellow }
        return s
    }
}

final class EditorModel: ObservableObject {
    @Published var doc: Document
    @Published var tool: Tool = .arrow {
        didSet { if tool != oldValue { selection = nil } }
    }
    @Published var selection: UUID?
    @Published var toast: String?
    @Published private var toolStyles: [Tool: Style] = [:]
    private var history = History<EditState>()
    private var pixelatedCache: CGImage??

    init(_ doc: Document) { self.doc = doc }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    var selected: Annotation? { selection.flatMap(annotation) }

    /// The tool whose properties the panel shows: the selection's kind, else the active tool.
    var styleTool: Tool { selected.map { Tool.of($0.kind) } ?? tool }

    /// Style for new annotations of the active tool.
    var toolStyle: Style { toolStyles[tool] ?? tool.defaultStyle }

    /// Style the panel shows and edits.
    var style: Style { selected?.style ?? toolStyle }

    /// Changes the selection's style, or the active tool's style when nothing is selected.
    /// Both are remembered for the next annotation of that kind, as in Excalidraw.
    func setStyle(_ change: (inout Style) -> Void) {
        if let id = selection, let i = index(id) {
            checkpoint()
            change(&doc.annotations[i].style)
            toolStyles[Tool.of(doc.annotations[i].kind)] = doc.annotations[i].style
            commit()
        } else {
            var s = toolStyle
            change(&s)
            toolStyles[tool] = s
        }
    }

    /// Pixelated image for blur regions. Built on first use.
    var pixelated: CGImage? {
        if pixelatedCache == nil { pixelatedCache = .some(Renderer.pixelate(doc.image, scale: doc.scale)) }
        return pixelatedCache ?? nil
    }

    var hasBlur: Bool {
        doc.annotations.contains { if case .blur = $0.kind { true } else { false } }
    }

    // MARK: Undo

    func checkpoint() { history.checkpoint(doc.state) }
    func commit() { history.commit(doc.state) }

    func undo() {
        guard let s = history.undo(doc.state) else { return }
        restore(s)
    }

    func redo() {
        guard let s = history.redo(doc.state) else { return }
        restore(s)
    }

    private func restore(_ s: EditState) {
        doc.state = s
        if let id = selection, index(id) == nil { selection = nil }
    }

    // MARK: Edits (callers wrap these in checkpoint/commit)

    func index(_ id: UUID) -> Int? { doc.annotations.firstIndex { $0.id == id } }
    func annotation(_ id: UUID) -> Annotation? { index(id).map { doc.annotations[$0] } }

    func add(_ a: Annotation) {
        doc.annotations.append(a)
        selection = a.id
    }

    func update(_ a: Annotation) {
        if let i = index(a.id) { doc.annotations[i] = a }
    }

    func remove(_ id: UUID) {
        doc.annotations.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func setFrame(_ r: CGRect) { doc.frame = r.integral }

    // MARK: Commands (these checkpoint themselves)

    func deleteSelection() {
        guard let id = selection else { return }
        checkpoint(); remove(id); commit()
    }

    func duplicateSelection() {
        guard let a = selected else { return }
        let d = 16 * doc.scale
        checkpoint()
        add(Annotation(kind: a.moved(dx: d, dy: d).kind, style: a.style, seed: a.seed))
        commit()
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let a = selected else { return }
        checkpoint(); update(a.moved(dx: dx, dy: dy)); commit()
    }

    /// Extend: adds even padding around the frame.
    func pad() {
        let amount = (min(doc.frame.width, doc.frame.height) * 0.08).rounded()
        checkpoint(); setFrame(doc.frame.insetBy(dx: -amount, dy: -amount)); commit()
    }

    func resetFrame() {
        checkpoint(); setFrame(doc.imageRect); commit()
    }

    func setBackground(_ c: RGBA?) {
        checkpoint(); doc.background = c; commit()
    }

    func exportPNG() -> Data? {
        guard let img = Exporter.render(doc, pixelated: hasBlur ? pixelated : nil) else { return nil }
        return Exporter.png(img, scale: doc.scale)
    }

    func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}
