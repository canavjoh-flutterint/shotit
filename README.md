# shotit

A fast, small macOS screenshot editor. Capture or paste, annotate in Excalidraw style, copy back.

## Build and run

Needs macOS 14+ and Command Line Tools (full Xcode is not necessary).

```sh
python3 scripts/bundle.py          # makes build/shotit.app
open build/shotit.app              # menu bar app, no Dock icon
swift run shotit-tests             # tests
```

You can also open an image or the clipboard from the command line:

```sh
build/shotit.app/Contents/MacOS/shotit --clipboard
build/shotit.app/Contents/MacOS/shotit path/to/image.png
```

## Keys

| Key | Action |
| --- | --- |
| ⇧⌘2 (global) | Capture a region or window |
| ⇧⌘1 (global) | Edit the image on the clipboard |
| V 1, R 2, O 3, A 4, L 5, P 6, T 7 | Select, rectangle, ellipse, arrow, line, pen, text |
| H, B, N, S, C | Highlighter, blur, number step, spotlight, crop and extend |
| E | Add padding |
| Shift while dragging | Square, circle, 15° angles, straight highlighter |
| Space + drag, pinch, ⌘= ⌘- ⌘0 ⌘1 | Pan, zoom, fit, 100% |
| ⌘C / Return | Copy / copy and close |
| ⌘S, ⌘Z, ⇧⌘Z, ⌘D, Delete, arrows | Save, undo, redo, duplicate, delete, nudge |

Capture needs the Screen Recording permission. macOS asks for it on the first capture.
An ad-hoc signed build can lose the permission after a rebuild. Grant it again in System Settings.
