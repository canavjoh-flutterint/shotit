import AppKit
import ImageIO
import UniformTypeIdentifiers

public struct LoadedImage {
    public let image: CGImage
    public let scale: CGFloat
    public init(image: CGImage, scale: CGFloat) { self.image = image; self.scale = scale }
}

public enum ImageLoader {
    /// Reads the scale from the DPI metadata (144 DPI is a 2x Retina capture).
    public static func load(data: Data) -> LoadedImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return LoadedImage(image: img, scale: max(1, (dpi / 72).rounded()))
    }

    public static func load(url: URL) -> LoadedImage? {
        (try? Data(contentsOf: url)).flatMap(load(data:))
    }

    /// Accepts a copied image file (Finder), PNG or TIFF data, or anything NSImage can read.
    public static func fromPasteboard(_ pb: NSPasteboard = .general) -> LoadedImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let img = load(url: url) { return img }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let img = load(data: data) { return img }
        }
        if let ns = NSImage(pasteboard: pb), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil),
           ns.size.width > 0 {
            return LoadedImage(image: cg, scale: max(1, (CGFloat(cg.width) / ns.size.width).rounded()))
        }
        return nil
    }
}

public enum Exporter {
    /// Flattens the document to the size of its frame, in the color space of the source image.
    public static func render(_ doc: Document, pixelated: CGImage?) -> CGImage? {
        let f = doc.frame.integral
        let space = doc.image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard f.width >= 1, f.height >= 1,
              let ctx = CGContext(data: nil, width: Int(f.width), height: Int(f.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: f.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -f.minX, y: -f.minY)
        Renderer.draw(doc, in: ctx, pixelated: pixelated, clip: true)
        return ctx.makeImage()
    }

    /// PNG with DPI metadata, so a 2x image pastes at its point size.
    public static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public static func copy(_ png: Data, to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setData(png, forType: .png)
    }
}
