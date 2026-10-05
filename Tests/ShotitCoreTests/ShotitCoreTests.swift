import CoreGraphics
import Foundation
import ImageIO
import Testing
import ShotitCore

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// An opaque image with a different color in each pixel.
private func makeImage(width: Int = 40, height: Int = 30) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            p[i] = UInt8(x * 6 % 256); p[i + 1] = UInt8(y * 8 % 256); p[i + 2] = UInt8((x + y) * 3 % 256); p[i + 3] = 255
        }
    }
    return ctx.makeImage()!
}

/// RGBA bytes, top row first.
private func bytes(_ img: CGImage) -> [UInt8] {
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
}

private func pngProperties(_ png: Data) -> [CFString: Any]? {
    CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
}

private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let b = bytes(img), i = (y * img.width + x) * 4
    return Array(b[i..<(i + 4)])
}

@Suite struct Export {
    // Copying a screenshot back with no edits must not blur, shift, or recolor it.
    @Test func unEditedExportIsPixelIdentical() throws {
        let src = makeImage()
        let out = try #require(Exporter.render(Document(image: src, scale: 2), pixelated: nil))
        #expect(out.width == src.width && out.height == src.height)
        #expect(bytes(out) == bytes(src))
    }

    // Crop output is exactly the frame, and the top-left pixel is the frame origin, not the image origin.
    @Test func cropExportsOnlyTheFrame() throws {
        let src = makeImage()
        var doc = Document(image: src, scale: 1)
        doc.frame = CGRect(x: 10, y: 5, width: 20, height: 10)
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(out.width == 20 && out.height == 10)
        #expect(pixel(out, 0, 0) == pixel(src, 10, 5))
        #expect(pixel(out, 19, 9) == pixel(src, 29, 14))
    }

    // Extend adds background padding and keeps the image unchanged inside it.
    @Test func extendPadsWithBackground() throws {
        let src = makeImage()
        var doc = Document(image: src, scale: 1)
        doc.frame = doc.imageRect.insetBy(dx: -5, dy: -5)
        doc.background = Palette.white
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(out.width == 50 && out.height == 40)
        #expect(pixel(out, 0, 0) == [255, 255, 255, 255])
        #expect(pixel(out, 5, 5) == pixel(src, 0, 0))
    }

    // A transparent background must stay transparent, so the PNG composites on any page color.
    @Test func transparentBackgroundHasZeroAlpha() throws {
        var doc = Document(image: makeImage(), scale: 1)
        doc.frame = doc.imageRect.insetBy(dx: -5, dy: -5)
        doc.background = nil
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(pixel(out, 0, 0)[3] == 0)
    }

    // A Retina capture must paste at its point size, not at double size.
    @Test func pngKeepsRetinaScale() throws {
        let png = try #require(Exporter.png(makeImage(), scale: 2))
        let loaded = try #require(ImageLoader.load(data: png))
        #expect(loaded.scale == 2)
        #expect(loaded.image.width == 40)
    }

    // An opaque screenshot is pasted into Slack as-is, so its PNG must drop the unused alpha
    // channel (smaller upload) and keep every pixel.
    @Test func opaquePNGHasNoAlphaAndSamePixels() throws {
        let src = makeImage()
        let png = try #require(Exporter.png(src, scale: 2))
        let loaded = try #require(ImageLoader.load(data: png))
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(loaded.image.alphaInfo))
        #expect(bytes(loaded.image) == bytes(src))
    }

    // A transparent padding or window shadow must keep its alpha in the PNG.
    @Test func transparentPNGKeepsAlpha() throws {
        var doc = Document(image: makeImage(), scale: 1)
        doc.frame = doc.imageRect.insetBy(dx: -5, dy: -5)
        doc.background = nil
        let out = try #require(Exporter.render(doc, pixelated: nil))
        let png = try #require(Exporter.png(out, scale: 1))
        #expect(pngProperties(png)?[kCGImagePropertyHasAlpha] as? Bool == true)
        let loaded = try #require(ImageLoader.load(data: png))
        #expect(pixel(loaded.image, 0, 0)[3] == 0)
    }

    // "Copy at 1x Size" halves a Retina capture for a smaller Slack upload; off, the clipboard keeps full resolution.
    @Test func clipboardPointSizeHalvesRetina() throws {
        func copied(scale: CGFloat, pointSize: Bool) -> LoadedImage? {
            Exporter.clipboardPNG(makeImage(), scale: scale, pointSize: pointSize).flatMap(ImageLoader.load(data:))
        }
        let small = try #require(copied(scale: 2, pointSize: true))
        #expect(small.image.width == 20 && small.image.height == 15 && small.scale == 1)
        let full = try #require(copied(scale: 2, pointSize: false))
        #expect(full.image.width == 40 && full.scale == 2)
        let oneX = try #require(copied(scale: 1, pointSize: true))
        #expect(oneX.image.width == 40)
    }

    // Annotations must reach the export: a solid rect changes the pixels under it.
    @Test func annotationsAreFlattened() throws {
        var doc = Document(image: makeImage(), scale: 1)
        var style = Style()
        style.fill = .solid
        style.roughness = .clean
        style.color = Palette.blue
        doc.annotations = [Annotation(kind: .rect(CGRect(x: 5, y: 5, width: 20, height: 15)), style: style)]
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(pixel(out, 15, 12) == [0x19, 0x71, 0xC2, 255])
        #expect(pixel(out, 35, 25) == pixel(makeImage(), 35, 25))
    }

    // Blur must hide the original pixels, or it is not a safe redaction.
    @Test func blurHidesOriginalPixels() throws {
        let src = makeImage(width: 80, height: 60)
        var doc = Document(image: src, scale: 1)
        doc.annotations = [Annotation(kind: .blur(CGRect(x: 10, y: 10, width: 40, height: 30)), style: Style())]
        let out = try #require(Exporter.render(doc, pixelated: Renderer.pixelate(src, scale: 1)))
        let before = (12..<48).map { pixel(src, $0, 20) }
        let after = (12..<48).map { pixel(out, $0, 20) }
        #expect(Set(after.map { $0.description }).count < Set(before.map { $0.description }).count / 3)
    }
}

@Suite struct GridExport {
    private func whiteDoc() -> Document {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        var doc = Document(image: ctx.makeImage()!, scale: 1)
        doc.grid.spacing = 16
        return doc
    }

    // The grid is a view aid by default: showing it must not change the copied image.
    @Test func visibleGridIsNotExportedByDefault() throws {
        var doc = whiteDoc()
        doc.grid.visible = true
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(pixel(out, 16, 5) == [255, 255, 255, 255])
    }

    // "Add grid to image" puts the lines into the export.
    @Test func includedGridIsExported() throws {
        var doc = whiteDoc()
        doc.grid.visible = true
        doc.grid.inExport = true
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(pixel(out, 16, 5) != [255, 255, 255, 255])
        #expect(pixel(out, 8, 5) == [255, 255, 255, 255])
    }

    // The export matches the screen: a hidden grid is never exported, even when "include" is on.
    @Test func hiddenGridIsNeverExported() throws {
        var doc = whiteDoc()
        doc.grid.inExport = true
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(pixel(out, 16, 5) == [255, 255, 255, 255])
    }

    // Lines stay on image pixels after extend, so the grid still measures the image content.
    @Test func gridAlignsToImageAfterExtend() throws {
        var doc = whiteDoc()
        doc.grid.visible = true
        doc.grid.inExport = true
        doc.frame = doc.imageRect.insetBy(dx: -5, dy: -5)
        let out = try #require(Exporter.render(doc, pixelated: nil))
        #expect(pixel(out, 5 + 16, 20) != pixel(out, 5 + 15, 20))
        #expect(pixel(out, 5 + 15, 20) == [255, 255, 255, 255])
    }
}

@Suite struct Thumbnails {
    private let area = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 280, height: 250)

    // Cards must sit at the top center, away from the macOS thumbnail at the bottom right.
    @Test func singleCardIsTopCenter() {
        let f = ThumbnailLayout.frames(count: 1, size: size, in: area)[0]
        #expect(f.maxY == area.maxY)
        #expect(abs(f.midX - area.midX) <= 1)
    }

    // Several cards must never cover each other or leave the screen.
    @Test func cardsDoNotOverlapAndStayOnScreen() {
        let n = ThumbnailLayout.capacity(size: size, in: area, gap: 4)
        let frames = ThumbnailLayout.frames(count: n, size: size, in: area, gap: 4)
        for (a, b) in zip(frames, frames.dropFirst()) { #expect(!a.intersects(b)) }
        for f in frames { #expect(area.contains(f)) }
        let tooMany = ThumbnailLayout.frames(count: n + 1, size: size, in: area, gap: 4)
        #expect(!tooMany.allSatisfy { area.contains($0) })
    }
}

@Suite struct Undo {
    // A plain click (checkpoint with no change) must not add an undo step.
    @Test func noOpEditAddsNoUndoStep() {
        var h = History<Int>()
        h.checkpoint(1)
        h.commit(1)
        #expect(!h.canUndo)
    }

    @Test func undoAndRedoRestoreStates() {
        var h = History<Int>()
        h.checkpoint(1); h.commit(2)
        #expect(h.undo(2) == 1)
        #expect(h.redo(1) == 2)
    }

    // A new edit after undo ends the redo branch. A no-op click must not end it.
    @Test func redoSurvivesNoOpButNotEdit() {
        var h = History<Int>()
        h.checkpoint(1); h.commit(2)
        _ = h.undo(2)
        h.checkpoint(1); h.commit(1)
        #expect(h.canRedo)
        h.checkpoint(1); h.commit(3)
        #expect(!h.canRedo)
    }
}

@Suite struct Shapes {
    private func style(fill: FillStyle = .none) -> Style {
        var s = Style()
        s.fill = fill
        return s
    }

    // Sketchy shapes must look the same on every redraw, so the path depends only on the seed.
    @Test func roughIsDeterministicPerSeed() {
        var a = SeededRandom(seed: 7), b = SeededRandom(seed: 7), c = SeededRandom(seed: 8)
        let r = CGRect(x: 0, y: 0, width: 100, height: 60)
        let p1 = Rough.rectangle(r, roughness: 1, unit: 2, rng: &a)
        let p2 = Rough.rectangle(r, roughness: 1, unit: 2, rng: &b)
        let p3 = Rough.rectangle(r, roughness: 1, unit: 2, rng: &c)
        #expect(p1 == p2)
        #expect(p1 != p3)
    }

    // The user must be able to click inside an outlined box to draw or select what is under it.
    @Test func outlinedRectHitsOnlyNearEdge() {
        let a = Annotation(kind: .rect(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style())
        #expect(a.hitTest(CGPoint(x: 1, y: 50), tolerance: 2, scale: 1))
        #expect(!a.hitTest(CGPoint(x: 50, y: 50), tolerance: 2, scale: 1))
        let filled = Annotation(kind: .rect(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style(fill: .solid))
        #expect(filled.hitTest(CGPoint(x: 50, y: 50), tolerance: 2, scale: 1))
    }

    @Test func ellipseHitsOutline() {
        let a = Annotation(kind: .ellipse(CGRect(x: 0, y: 0, width: 100, height: 50)), style: style())
        #expect(a.hitTest(CGPoint(x: 50, y: 0), tolerance: 2, scale: 1))
        #expect(!a.hitTest(CGPoint(x: 50, y: 25), tolerance: 2, scale: 1))
    }

    // Resize from a corner keeps the opposite corner in place.
    @Test func cornerDragKeepsOppositeCorner() {
        let a = Annotation(kind: .rect(CGRect(x: 10, y: 10, width: 50, height: 50)), style: style())
        let b = a.movingHandle(0, to: CGPoint(x: 0, y: 5), constrain: false)
        #expect(b.kind.rect == CGRect(x: 0, y: 5, width: 60, height: 55))
    }

    @Test func shiftSnapsArrowTo15Degrees() {
        let a = Annotation(kind: .arrow(.zero, CGPoint(x: 100, y: 0)), style: style())
        let b = a.movingHandle(1, to: CGPoint(x: 100, y: 4), constrain: true)
        #expect(abs(b.kind.endpoints!.1.y) < 0.001)
    }

    // A crop handle dragged past the opposite edge must not invert the frame (which would export nothing).
    @Test func frameHandleNeverInverts() {
        let f = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = f.draggingFrameHandle(0, to: CGPoint(x: 200, y: 200))
        #expect(r.width >= 1 && r.height >= 1)
        #expect(r.maxX == 100 && r.maxY == 100)
    }

    // Number steps continue from the highest number, also after one is deleted.
    @Test func nextStepFollowsHighest() {
        var doc = Document(image: makeImage(), scale: 1)
        #expect(doc.nextStep == 1)
        doc.annotations = [Annotation(kind: .step(.zero, 1), style: Style()), Annotation(kind: .step(.zero, 3), style: Style())]
        #expect(doc.nextStep == 4)
    }
}
