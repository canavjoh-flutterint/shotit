import AppKit
import ShotitCore
import SwiftUI

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    let canvas: CanvasView
    var onClose: ((EditorWindowController) -> Void)?

    init(_ loaded: LoadedImage) {
        model = EditorModel(Document(image: loaded.image, scale: loaded.scale))
        canvas = CanvasView(model: model)

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let points = CGSize(width: CGFloat(loaded.image.width) / loaded.scale, height: CGFloat(loaded.image.height) / loaded.scale)
        let size = CGSize(width: min(max(points.width + 160, 900), screen.width * 0.85),
                          height: min(max(points.height + 220, 560), screen.height * 0.85))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Hidden in the title bar, but the Window menu and the Dock menu list editors by this title.
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        window.title = "Screenshot \(f.string(from: Date()))"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self

        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 32
        scroll.automaticallyAdjustsContentInsets = false
        scroll.backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll,
                                               queue: .main) { [weak canvas] _ in canvas?.needsDisplay = true }

        let root = NSView()
        window.contentView = root
        let toolbar = hosting(ToolbarView(model: model) { [weak canvas] in NSApp.sendAction($0, to: canvas, from: nil) })
        let panel = hosting(PropertyPanel(model: model))
        let toast = hosting(ToastView(model: model))
        for v in [scroll, toolbar, panel, toast] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolbar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            panel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            panel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 14),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func hosting<V: View>(_ view: V) -> NSHostingView<V> {
        let h = NSHostingView(rootView: view)
        h.sizingOptions = .intrinsicContentSize
        return h
    }

    func show() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.layoutIfNeeded()
        canvas.fitInitial()
        window?.makeFirstResponder(canvas)
    }

    func windowWillClose(_ notification: Notification) { onClose?(self) }
}
