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
        Renderer.draw(doc, in: ctx, pixelated: pixelated, clip: true, grid: doc.grid.exported)
        return ctx.makeImage()
    }

    /// PNG with DPI metadata, so a 2x image pastes at its point size.
    /// An opaque image is written without an alpha channel, which makes the file about 10% smaller.
    public static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let props = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary
        CGImageDestinationAddImage(dest, withoutAlphaIfOpaque(image), props)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The PNG for the clipboard. With `pointSize`, a Retina image goes down to 1 pixel per point:
    /// about half the bytes for Slack, but text is less sharp on a Retina screen.
    public static func clipboardPNG(_ image: CGImage, scale: CGFloat, pointSize: Bool) -> Data? {
        guard pointSize, scale > 1 else { return png(image, scale: scale) }
        let w = Int((CGFloat(image.width) / scale).rounded()), h = Int((CGFloat(image.height) / scale).rounded())
        guard w >= 1, h >= 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: rgbSpace(image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap { png($0, scale: 1) }
    }

    /// Window captures have a transparent shadow and padded frames can be transparent, so check every pixel.
    private static func withoutAlphaIfOpaque(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height, space = rgbSpace(image)
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: w * h * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) where bytes[i] != 255 { return image }
        // Premultiplied pixels with alpha 255 are the same as straight pixels, so the bytes can be reused.
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let opaque = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return image }
        return opaque
    }

    private static func rgbSpace(_ image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
    }

    public static func copy(_ png: Data, to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setData(png, forType: .png)
    }
}
