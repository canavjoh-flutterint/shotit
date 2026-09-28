import AppKit
import ShotitCore
import SwiftUI

/// Quick-access card after a capture. It is made to look different from the macOS screenshot thumbnail:
/// top center (not bottom right), drops down (not slides in), tilted paper card with a sketchy border
/// and a "copied" tag. Click to annotate, drag out, or use the hover buttons. It closes by itself.
final class ThumbnailController {
    static let size = CGSize(width: 280, height: 250)
    private static let lifetime: TimeInterval = 10

    let image: LoadedImage
    private let png: Data
    private let fileURL: URL
    private let panel: NSPanel
    private var timer: Timer?
    private let onOpen: (ThumbnailController) -> Void
    private let onClose: (ThumbnailController) -> Void

    init(_ image: LoadedImage, png: Data, onOpen: @escaping (ThumbnailController) -> Void,
         onClose: @escaping (ThumbnailController) -> Void) {
        self.image = image
        self.png = png
        self.onOpen = onOpen
        self.onClose = onClose

        // A named file, so a drag into Finder or Slack gets a good file name.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("Screenshot \(f.string(from: Date())).png")
        try? png.write(to: fileURL)

        panel = ThumbnailPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let ns = NSImage(cgImage: image.image, size: CGSize(width: CGFloat(image.image.width) / image.scale,
                                                            height: CGFloat(image.image.height) / image.scale))
        panel.contentView = NSHostingView(rootView: ThumbnailView(
            image: ns, fileURL: fileURL,
            open: { [weak self] in self.map { $0.onOpen($0) } },
            copy: { [weak self] in self?.copy() },
            save: { [weak self] in self?.save() },
            close: { [weak self] in self?.close() },
            hover: { [weak self] in self?.hover($0) }))
    }

    func place(_ frame: CGRect, animated: Bool) {
        if animated, panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    func show() {
        panel.orderFrontRegardless()
        scheduleClose()
    }

    private func hover(_ inside: Bool) {
        timer?.invalidate()
        if !inside { scheduleClose() }
    }

    private func scheduleClose() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in self?.close() }
    }

    private func copy() {
        Exporter.copy(png)
        close()
    }

    private func save() {
        timer?.invalidate()
        NSApp.activate()
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.nameFieldStringValue = fileURL.lastPathComponent
        if sp.runModal() == .OK, let url = sp.url {
            do { try png.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        close()
    }

    private var closing = false

    func close() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in
            panel.orderOut(nil)
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
            onClose(self)
        })
    }
}

/// Never takes focus from the app the user is working in.
private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private let accent = Color(red: 0.41, green: 0.40, blue: 0.86)

private struct ThumbnailView: View {
    let image: NSImage
    let fileURL: URL
    let open: () -> Void
    let copy: () -> Void
    let save: () -> Void
    let close: () -> Void
    let hover: (Bool) -> Void

    @State private var hovering = false
    @State private var appeared = false

    /// The image fitted into the card.
    private var fitted: CGSize {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return CGSize(width: 200, height: 130) }
        let k = min(210 / s.width, 140 / s.height, 1)
        return CGSize(width: max(40, s.width * k), height: max(30, s.height * k))
    }

    var body: some View {
        VStack(spacing: 12) {
            card
            HStack(spacing: 6) {
                pill("pencil.tip.crop.circle", "Annotate", open)
                pill("doc.on.doc", "Copy", copy)
                pill("square.and.arrow.down", "Save", save)
                pill("xmark", nil, close)
            }
            .opacity(hovering ? 1 : 0)
            .offset(y: hovering ? 0 : -6)
        }
        .padding(.top, 14)
        .frame(width: ThumbnailController.size.width, height: ThumbnailController.size.height, alignment: .top)
        .offset(y: appeared ? 0 : -70)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
        .onHover { h in hovering = h; hover(h) }
        .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { appeared = true } }
    }

    private var card: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: fitted.width, height: fitted.height)
            .padding(7)
            .background(Color.white)
            .overlay(SketchBorder(seed: 7).stroke(accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)))
            .overlay(alignment: .topLeading) { tag }
            .shadow(color: .black.opacity(0.28), radius: hovering ? 14 : 9, y: hovering ? 8 : 5)
            .rotationEffect(.degrees(hovering ? 0 : -2.5))
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onDrag { NSItemProvider(contentsOf: fileURL) ?? NSItemProvider() }
            .help("Click to annotate. Drag to drop the file into another app.")
    }

    /// Hand-drawn sticky tag that says the capture is on the clipboard.
    private var tag: some View {
        Text("copied ✓")
            .font(.custom("ChalkboardSE-Regular", size: 12))
            .foregroundStyle(Color(red: 0.2, green: 0.2, blue: 0.2))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color(red: 1, green: 0.93, blue: 0.6))
            .rotationEffect(.degrees(-6))
            .offset(x: -10, y: -10)
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
    }

    private func pill(_ symbol: String, _ title: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if let title { Text(title) }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, title == nil ? 8 : 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Rough.js rectangle as a SwiftUI shape. The fixed seed keeps the wobble still during animation.
private struct SketchBorder: SwiftUI.Shape {
    let seed: UInt64
    func path(in rect: CGRect) -> Path {
        var rng = SeededRandom(seed: seed)
        return Path(Rough.rectangle(rect.insetBy(dx: -1.5, dy: -1.5), roughness: 1, unit: 1, rng: &rng))
    }
}
