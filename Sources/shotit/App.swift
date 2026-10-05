import AppKit
import Carbon.HIToolbox
import ShotitCore

/// Global hotkeys through Carbon. They need no Accessibility permission.
enum HotKeys {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    static func register(id: UInt32, keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                HotKeys.handlers[hk.id]?()
                return noErr
            }, 1, &spec, nil, nil)
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5348_4F54), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

/// Region and window capture through the system picker (`screencapture -i`).
enum Capture {
    static func region(_ done: @escaping (LoadedImage) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotit-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", url.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                // No file means the user pressed Escape.
                guard let img = ImageLoader.load(url: url) else { return }
                try? FileManager.default.removeItem(at: url)
                done(img)
            }
        }
        do { try p.run() } catch { NSSound.beep() }
    }
}

enum Settings {
    /// Copy a Retina image at 1 pixel per point. The PNG is about half the size, which is good for Slack.
    static let copyAtPointSizeKey = "copyAtPointSize"
    static var copyAtPointSize: Bool { UserDefaults.standard.bool(forKey: copyAtPointSizeKey) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var editors: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = mainMenu()
        setupStatusItem()
        let cmdShift = cmdKey | shiftKey
        HotKeys.register(id: 1, keyCode: kVK_ANSI_2, modifiers: cmdShift) { [weak self] in self?.captureRegion() }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_1, modifiers: cmdShift) { [weak self] in self?.editClipboard() }

        let args = CommandLine.arguments.dropFirst()
        if args.contains("--clipboard") { editClipboard() }
        if args.contains("--capture") { captureRegion() }
        for path in args where !path.hasPrefix("-") { open(URL(fileURLWithPath: path)) }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(open) }

    /// A click on the Dock icon also shows minimized editors.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showEditors()
        return false
    }

    @objc func captureRegion() { Capture.region { [weak self] in self?.captured($0) } }

    // MARK: Quick access

    private static let openEditorKey = "openEditorAfterCapture"
    private var openEditorAfterCapture: Bool {
        get { UserDefaults.standard.bool(forKey: Self.openEditorKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.openEditorKey) }
    }

    private var thumbnails: [ThumbnailController] = []
    private let thumbnailGap: CGFloat = 4

    /// A capture goes to the clipboard at once. Then it shows a thumbnail, or the editor when that option is on.
    private func captured(_ img: LoadedImage) {
        guard let png = Exporter.png(img.image, scale: img.scale),
              let clip = Settings.copyAtPointSize
                  ? Exporter.clipboardPNG(img.image, scale: img.scale, pointSize: true) : png
        else { NSSound.beep(); return }
        Exporter.copy(clip)
        if openEditorAfterCapture { show(img); return }

        let thumb = ThumbnailController(img, png: png, clipboardPNG: clip, onOpen: { [weak self] t in
            self?.show(t.image)
            t.close()
        }, onClose: { [weak self] t in
            self?.thumbnails.removeAll { $0 === t }
            self?.layoutThumbnails(animated: true)
        })
        let area = thumbnailArea()
        let cap = ThumbnailLayout.capacity(size: ThumbnailController.size, in: area, gap: thumbnailGap)
        thumbnails.prefix(max(0, thumbnails.count - cap + 1)).forEach { $0.close() }
        thumbnails.append(thumb)
        layoutThumbnails(animated: true)
        thumb.show()
    }

    /// The screen with the mouse, below the menu bar.
    private func thumbnailArea() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        return (screen?.visibleFrame ?? .zero).insetBy(dx: 8, dy: 0)
    }

    private func layoutThumbnails(animated: Bool) {
        let frames = ThumbnailLayout.frames(count: thumbnails.count, size: ThumbnailController.size,
                                            in: thumbnailArea(), gap: thumbnailGap)
        for (t, f) in zip(thumbnails, frames) { t.place(f, animated: animated) }
    }

    @objc private func toggleOpenEditor(_ item: NSMenuItem) {
        openEditorAfterCapture.toggle()
        item.state = openEditorAfterCapture ? .on : .off
    }

    @objc private func toggleCopyAtPointSize(_ item: NSMenuItem) {
        UserDefaults.standard.set(!Settings.copyAtPointSize, forKey: Settings.copyAtPointSizeKey)
        item.state = Settings.copyAtPointSize ? .on : .off
    }

    @objc func showEditors() {
        guard !editors.isEmpty else { return }
        NSApp.activate()
        for e in editors {
            e.window?.deminiaturize(nil)
            e.window?.orderFront(nil)
        }
        editors.last?.window?.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(showEditors) ? !editors.isEmpty : true
    }

    @objc func editClipboard() {
        guard let img = ImageLoader.fromPasteboard() else { NSSound.beep(); return }
        show(img)
    }

    @objc func openFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    private func open(_ url: URL) {
        guard let img = ImageLoader.load(url: url) else { NSSound.beep(); return }
        show(img)
    }

    private func show(_ img: LoadedImage) {
        let editor = EditorWindowController(img)
        editor.onClose = { [weak self] e in
            self?.editors.removeAll { $0 === e }
            self?.updateActivationPolicy()
        }
        editors.append(editor)
        updateActivationPolicy()
        editor.show()
    }

    /// In the Dock and the Cmd-Tab switcher only while an editor is open, so an editor behind
    /// other windows is easy to find. With no editor open, shotit is a menu bar app only.
    private func updateActivationPolicy() {
        NSApp.setActivationPolicy(editors.isEmpty ? .accessory : .regular)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "shotit")
        let menu = NSMenu()
        menu.addItem(withTitle: "Capture Region   ⇧⌘2", action: #selector(captureRegion), keyEquivalent: "")
        menu.addItem(withTitle: "Edit Clipboard   ⇧⌘1", action: #selector(editClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Open Image…", action: #selector(openFile), keyEquivalent: "")
        menu.addItem(withTitle: "Show Editor Windows", action: #selector(showEditors), keyEquivalent: "")
        menu.addItem(.separator())
        let openEditor = menu.addItem(withTitle: "Open Editor After Capture", action: #selector(toggleOpenEditor(_:)),
                                      keyEquivalent: "")
        openEditor.state = openEditorAfterCapture ? .on : .off
        let pointSize = menu.addItem(withTitle: "Copy at 1x Size (Smaller for Slack)",
                                     action: #selector(toggleCopyAtPointSize(_:)), keyEquivalent: "")
        pointSize.state = Settings.copyAtPointSize ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit shotit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for i in menu.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = menu
        statusItem = item
    }

    /// Hidden while the app is an accessory, but it routes key equivalents,
    /// including Cut, Copy, and Paste inside the text editor.
    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let menu = NSMenu(title: title)
            for (t, sel, key, mods) in items {
                let i = menu.addItem(withTitle: t, action: sel, keyEquivalent: key)
                i.keyEquivalentModifierMask = mods
            }
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        submenu("shotit", [("Quit shotit", #selector(NSApplication.terminate(_:)), "q", .command)])
        submenu("File", [
            ("Open…", #selector(openFile), "o", .command),
            ("Save…", #selector(CanvasView.saveDocument(_:)), "s", .command),
            ("Close", #selector(NSWindow.performClose(_:)), "w", .command),
        ])
        submenu("Edit", [
            ("Undo", #selector(CanvasView.undo(_:)), "z", .command),
            ("Redo", #selector(CanvasView.redo(_:)), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(CanvasView.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
            ("Duplicate", #selector(CanvasView.duplicate(_:)), "d", .command),
        ])
        submenu("View", [
            ("Zoom In", #selector(CanvasView.zoomIn(_:)), "=", .command),
            ("Zoom Out", #selector(CanvasView.zoomOut(_:)), "-", .command),
            ("Zoom to Fit", #selector(CanvasView.zoomToFit(_:)), "0", .command),
            ("Actual Size", #selector(CanvasView.zoomActual(_:)), "1", .command),
            ("Show Grid", #selector(CanvasView.toggleGrid(_:)), "'", .command),
        ])
        submenu("Window", [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", .command),
            ("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", []),
        ])
        // AppKit adds a list of the open editor windows to this menu.
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        // Menu items with no target go to the first responder. File > Open targets the app delegate.
        main.item(withTitle: "File")?.submenu?.item(withTitle: "Open…")?.target = self
        return main
    }
}
