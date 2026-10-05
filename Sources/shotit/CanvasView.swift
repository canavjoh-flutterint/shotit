import AppKit
import Combine
import ShotitCore
import UniformTypeIdentifiers

/// The document view of the editor scroll view. Its bounds use image pixel coordinates,
/// so the scroll view magnification gives zoom and all mouse points are already in image space.
final class CanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let model: EditorModel
    private var subscription: AnyCancellable?

    private enum Drag {
        case none
        case create(UUID, start: CGPoint)
        case move(start: CGPoint, original: Annotation)
        case handle(Int, original: Annotation)
        case frameHandle(Int, original: CGRect)
        case frameNew(start: CGPoint)
        case pan(start: NSPoint, origin: NSPoint)
    }

    private var drag = Drag.none
    private var spaceDown = false
    private var lastTool: Tool
    private var textView: NSTextView?
    private var editingID: UUID?

    init(model: EditorModel) {
        self.model = model
        lastTool = model.tool
        super.init(frame: .zero)
        updateArea()
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.modelChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var scale: CGFloat { model.doc.scale }
    /// One screen point in image pixels.
    private var px: CGFloat { 1 / (enclosingScrollView?.magnification ?? 1) }

    // MARK: Model and layout

    private func modelChanged() {
        if model.tool != lastTool {
            lastTool = model.tool
            commitText()
        }
        if let tv = textView, let id = editingID, let a = model.annotation(id) {
            styleTextView(tv, a.style)
        }
        if case .none = drag { updateArea() }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if textView == nil, window?.firstResponder !== self { window?.makeFirstResponder(self) }
    }

    /// Keeps a margin around the frame so crop handles can drag outward to extend.
    private func updateArea() {
        let d = model.doc
        let m = max(d.frame.width, d.frame.height) * 0.5
        let needed = d.imageRect.union(d.frame).insetBy(dx: -m * 0.5, dy: -m * 0.5)
        if bounds.width > 0, bounds.contains(needed) { return }
        let area = d.imageRect.union(d.frame).insetBy(dx: -m, dy: -m).integral
        let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let hadSize = bounds.width > 0
        setFrameSize(area.size)
        setBoundsOrigin(area.origin)
        if hadSize { scroll(CGPoint(x: center.x - visibleRect.width / 2, y: center.y - visibleRect.height / 2)) }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        if spaceDown { cursor = .openHand } else if model.tool == .select { cursor = .arrow } else if model.tool == .text {
            cursor = .iBeam
        } else { cursor = .crosshair }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: Zoom

    func fitInitial() { fit(maxMagnification: 1 / scale) }

    private func fit(maxMagnification: CGFloat = 32) {
        guard let sv = enclosingScrollView else { return }
        let f = model.doc.frame
        let avail = sv.contentView.frame.size
        let mag = min((avail.width - 80) / f.width, (avail.height - 140) / f.height, maxMagnification)
        sv.magnification = max(sv.minMagnification, mag)
        scroll(CGPoint(x: f.midX - visibleRect.width / 2, y: f.midY - visibleRect.height / 2 - 20 * px))
        needsDisplay = true
    }

    private func zoom(by factor: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        sv.setMagnification(sv.magnification * factor, centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        needsDisplay = true
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }
    @objc func zoomToFit(_ sender: Any?) { fit() }

    @objc func zoomActual(_ sender: Any?) {
        guard let sv = enclosingScrollView else { return }
        sv.setMagnification(1 / scale, centeredAt: CGPoint(x: visibleRect.midX, y: visibleRect.midY))
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let d = model.doc
        let cropping = model.tool == .crop
        let shown = cropping ? d.frame.union(d.imageRect) : d.frame

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6 * px), blur: 28 * px, color: CGColor(gray: 0, alpha: 0.35))
        ctx.setFillColor(d.background?.cgColor ?? CGColor(gray: 0.5, alpha: 0.25))
        ctx.fill(shown)
        ctx.restoreGState()

        Renderer.draw(d, in: ctx, pixelated: model.hasBlur ? model.pixelated : nil, clip: !cropping,
                      grid: d.grid.visible, hiding: editingID)

        if cropping {
            let dim = CGMutablePath()
            dim.addRect(bounds)
            dim.addRect(d.frame)
            ctx.addPath(dim)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1 * px)
            ctx.stroke(d.frame)
            drawHandles(d.frame.frameHandles, ctx)
            drawSizeLabel(d.frame, ctx)
        } else if let a = model.selected, editingID == nil {
            let b = a.bounds(scale: scale).insetBy(dx: -6 * px, dy: -6 * px)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1 * px)
            ctx.setLineDash(phase: 0, lengths: [4 * px, 3 * px])
            ctx.stroke(b)
            ctx.setLineDash(phase: 0, lengths: [])
            drawHandles(a.handles, ctx)
        }
    }

    private let accent = CGColor(srgbRed: 0.41, green: 0.40, blue: 0.86, alpha: 1)

    private func drawHandles(_ pts: [CGPoint], _ ctx: CGContext) {
        let r = 4.5 * px
        for p in pts {
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 * px)
            ctx.strokeEllipse(in: rect)
        }
    }

    private func drawSizeLabel(_ f: CGRect, _ ctx: CGContext) {
        let label = "\(Int(f.width)) × \(Int(f.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11 * px, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let s = label.size(withAttributes: attrs)
        let box = CGRect(x: f.midX - s.width / 2 - 6 * px, y: f.maxY + 8 * px, width: s.width + 12 * px, height: s.height + 4 * px)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4 * px, cornerHeight: 4 * px, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: box.minX + 6 * px, y: box.minY + 2 * px), withAttributes: attrs)
    }

    // MARK: Mouse

    private func handleIndex(_ p: CGPoint, _ handles: [CGPoint]) -> Int? {
        handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 8 * px }
    }

    private func topHit(_ p: CGPoint) -> Annotation? {
        model.doc.annotations.last { $0.hitTest(p, tolerance: 4 * px, scale: scale) }
    }

    /// Snaps crop edges to the image edges.
    private func snap(_ p: CGPoint) -> CGPoint {
        let r = model.doc.imageRect, t = 8 * px
        var q = p
        for x in [r.minX, r.maxX] where abs(p.x - x) < t { q.x = x }
        for y in [r.minY, r.maxY] where abs(p.y - y) < t { q.y = y }
        return q
    }

    override func mouseDown(with e: NSEvent) {
        if textView != nil { commitText(); return }
        let p = convert(e.locationInWindow, from: nil)
        if spaceDown {
            drag = .pan(start: e.locationInWindow, origin: enclosingScrollView?.contentView.bounds.origin ?? .zero)
            NSCursor.closedHand.set()
            return
        }

        switch model.tool {
        case .crop:
            model.checkpoint()
            if let i = handleIndex(p, model.doc.frame.frameHandles) {
                drag = .frameHandle(i, original: model.doc.frame)
            } else {
                drag = .frameNew(start: snap(p))
            }
            return
        case .step:
            model.checkpoint()
            let a = Annotation(kind: .step(p, model.doc.nextStep), style: model.toolStyle)
            model.add(a)
            drag = .move(start: p, original: a)
            return
        default:
            break
        }

        // The selection wins: its handles, then its body.
        if let a = model.selected {
            if let i = handleIndex(p, a.handles) {
                model.checkpoint()
                drag = .handle(i, original: a)
                return
            }
            if a.hitTest(p, tolerance: 4 * px, scale: scale) {
                if e.clickCount == 2, case .text = a.kind { beginEditing(a); return }
                model.checkpoint()
                drag = .move(start: p, original: a)
                return
            }
        }

        switch model.tool {
        case .select:
            if let a = topHit(p) {
                model.selection = a.id
                if e.clickCount == 2, case .text = a.kind { beginEditing(a); return }
                model.checkpoint()
                drag = .move(start: p, original: a)
            } else {
                model.selection = nil
            }
        case .text:
            if let a = topHit(p), case .text = a.kind { beginEditing(a); return }
            let lineHeight = Renderer.textSize("X", style: model.toolStyle, scale: scale).height
            model.checkpoint()
            let a = Annotation(kind: .text(CGPoint(x: p.x, y: p.y - lineHeight / 2), ""), style: model.toolStyle)
            model.add(a)
            beginEditing(a)
        default:
            guard let kind = newKind(at: p) else { return }
            model.checkpoint()
            let a = Annotation(kind: kind, style: model.toolStyle)
            model.add(a)
            drag = .create(a.id, start: p)
        }
    }

    private func newKind(at p: CGPoint) -> Annotation.Kind? {
        let r = CGRect(origin: p, size: .zero)
        switch model.tool {
        case .rect: return .rect(r)
        case .ellipse: return .ellipse(r)
        case .blur: return .blur(r)
        case .spotlight: return .spotlight(r)
        case .line: return .line(p, p)
        case .arrow: return .arrow(p, p)
        case .pen: return .pen([p])
        case .highlighter: return .highlighter([p])
        default: return nil
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let shift = e.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .create(let id, let start):
            guard var a = model.annotation(id) else { return }
            switch a.kind {
            case .pen(var pts):
                if let l = pts.last, hypot(l.x - p.x, l.y - p.y) < 1.5 * px { return }
                pts.append(p)
                a.kind = .pen(pts)
            case .highlighter(var pts):
                // Shift draws a straight horizontal marker line.
                if shift { pts = [start, CGPoint(x: p.x, y: start.y)] } else { pts.append(p) }
                a.kind = .highlighter(pts)
            default:
                if a.kind.rect != nil {
                    a.kind = a.kind.with(rect: CGRect(corner: start, shift ? squareCorner(p, from: start) : p))
                } else if a.kind.endpoints != nil {
                    a.kind = a.kind.with(endpoints: start, shift ? snapAngle(p, from: start) : p)
                }
            }
            model.update(a)
        case .move(let start, let original):
            model.update(original.moved(dx: p.x - start.x, dy: p.y - start.y))
        case .handle(let i, let original):
            model.update(original.movingHandle(i, to: p, constrain: shift))
        case .frameHandle(let i, let original):
            model.setFrame(original.draggingFrameHandle(i, to: snap(p)))
        case .frameNew(let start):
            let r = CGRect(corner: start, snap(p)).integral
            if r.width >= 4 * px, r.height >= 4 * px { model.setFrame(r) }
        case .pan(let start, let origin):
            guard let sv = enclosingScrollView else { return }
            let m = sv.magnification
            let dx = e.locationInWindow.x - start.x, dy = e.locationInWindow.y - start.y
            // Clip view bounds are in canvas units. Window y points up, the canvas y points down.
            sv.contentView.scroll(to: NSPoint(x: origin.x - dx / m, y: origin.y + dy / m))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if case .create(let id, _) = drag, let a = model.annotation(id), isTiny(a) { model.remove(id) }
        if case .pan = drag {} else if case .none = drag {} else { model.commit() }
        drag = .none
        updateArea()
        window?.invalidateCursorRects(for: self)
    }

    /// A click with no drag makes no shape. A pen click is a dot, so it stays.
    private func isTiny(_ a: Annotation) -> Bool {
        let t = 3 * px
        if let r = a.kind.rect { return r.width < t || r.height < t }
        if let (p, q) = a.kind.endpoints { return hypot(q.x - p.x, q.y - p.y) < t }
        return false
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { super.keyDown(with: e); return }
        let step: CGFloat = (flags.contains(.shift) ? 10 : 1) * scale
        switch e.keyCode {
        case 49: // space
            if !spaceDown { spaceDown = true; window?.invalidateCursorRects(for: self); NSCursor.openHand.set() }
            return
        case 51, 117: model.deleteSelection(); return
        case 53: // escape
            if model.selection != nil { model.selection = nil } else { model.tool = .select }
            return
        case 36, 76: copyAndClose(); return
        case 123: model.nudge(dx: -step, dy: 0); return
        case 124: model.nudge(dx: step, dy: 0); return
        case 125: model.nudge(dx: 0, dy: step); return
        case 126: model.nudge(dx: 0, dy: -step); return
        default: break
        }
        guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return }
        if let t = Tool.allCases.first(where: { $0.key == ch || $0.number == ch }) {
            model.tool = t
        } else if ch == "e" {
            model.pad()
        } else if ch == "g" {
            model.doc.grid.visible.toggle()
        } else {
            super.keyDown(with: e)
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 {
            spaceDown = false
            window?.invalidateCursorRects(for: self)
            NSCursor.arrow.set()
        }
    }

    // MARK: Commands (menu items and toolbar buttons reach these through the responder chain)

    @objc func copy(_ sender: Any?) {
        guard let png = model.clipboardPNG() else { NSSound.beep(); return }
        Exporter.copy(png)
        model.flash("Copied to clipboard")
    }

    func copyAndClose() {
        guard let png = model.clipboardPNG() else { NSSound.beep(); return }
        Exporter.copy(png)
        window?.close()
    }

    @objc func toggleGrid(_ sender: Any?) { model.doc.grid.visible.toggle() }
    @objc func undo(_ sender: Any?) { model.undo() }
    @objc func redo(_ sender: Any?) { model.redo() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }
    @objc func duplicate(_ sender: Any?) { model.duplicateSelection() }

    @objc func saveDocument(_ sender: Any?) {
        guard let window, let png = model.exportPNG() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Screenshot \(f.string(from: Date())).png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do { try png.write(to: url); self?.model.flash("Saved") } catch { NSAlert(error: error).runModal() }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return model.canUndo
        case #selector(redo(_:)): return model.canRedo
        case #selector(delete(_:)), #selector(duplicate(_:)): return model.selection != nil
        case #selector(toggleGrid(_:)):
            item.state = model.doc.grid.visible ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: Text editing

    /// Edits a text annotation in place with a temporary NSTextView.
    /// The caller has already made a checkpoint for a new annotation.
    private func beginEditing(_ a: Annotation) {
        guard case .text(let p, let str) = a.kind else { return }
        if !str.isEmpty { model.checkpoint() }
        model.selection = a.id
        editingID = a.id
        let tv = NSTextView(frame: CGRect(origin: p, size: CGSize(width: 10, height: 10)))
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 1e6, height: 1e6)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = CGSize(width: 1e6, height: 1e6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.string = str
        tv.delegate = self
        styleTextView(tv, a.style)
        addSubview(tv)
        textView = tv
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        needsDisplay = true
    }

    private func styleTextView(_ tv: NSTextView, _ s: Style) {
        let attrs = Renderer.textAttributes(s, scale: scale)
        tv.font = attrs[.font] as? NSFont
        tv.textColor = attrs[.foregroundColor] as? NSColor
        tv.insertionPointColor = tv.textColor ?? .labelColor
        tv.typingAttributes = attrs
        sizeTextView(tv, s)
    }

    private func sizeTextView(_ tv: NSTextView, _ s: Style) {
        let size = Renderer.textSize(tv.string, style: s, scale: scale)
        tv.setFrameSize(CGSize(width: size.width + 4 * scale, height: size.height))
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID, let a = model.annotation(id) else { return }
        sizeTextView(tv, a.style)
    }

    /// Return commits. Shift+Return adds a line. Escape commits.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                commitText()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitText()
            return true
        default:
            return false
        }
    }

    private func commitText() {
        guard let tv = textView, let id = editingID else { return }
        textView = nil
        editingID = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        if var a = model.annotation(id), case .text(let p, _) = a.kind {
            let str = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if str.isEmpty {
                model.remove(id)
            } else {
                a.kind = .text(p, str)
                model.update(a)
            }
        }
        model.commit()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

/// Centers the canvas when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = f.minX - (r.width - f.width) / 2 }
        if r.height > f.height { r.origin.y = f.minY - (r.height - f.height) / 2 }
        return r
    }
}
