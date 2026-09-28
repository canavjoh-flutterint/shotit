# shotit: plan

A fast, small, native macOS app to capture or paste a screenshot, annotate it, and copy it back to the clipboard.

## Goal

1. Press a global hotkey. Select a region. The editor opens with the image in under 150 ms.
2. Or press a second hotkey. The editor opens with the image from the clipboard.
3. Annotate with Excalidraw-style tools and single-key shortcuts.
4. Press Cmd+C (or Return). The flattened PNG goes to the clipboard. The window closes.

Success criteria:

- Cold launch to editor: < 300 ms. Warm (menu bar app already running): < 150 ms.
- App bundle: < 10 MB. Idle memory: < 40 MB.
- No Electron, no web view, no runtime dependencies outside the macOS SDK.
- Builds with Command Line Tools only (`swift build`). This machine has no full Xcode.

## Reference apps

| App | What we take from it |
| --- | --- |
| Skitch | Big, bold arrows. One window. Very few controls. |
| CleanShot X | Floating "quick access" thumbnail after capture. Background/padding ("extend"). Blur, counter steps, highlighter. |
| Shottr | Speed. Pixel-accurate zoom. Magnifier callout. Smart blur. |
| Excalidraw | Tool bar with number keys and letter keys. Hand-drawn stroke option. Small property panel (stroke, width, style, fill, roughness). Select, move, resize, duplicate, undo. |

## Stack decision

**Recommendation: native Swift, AppKit canvas + SwiftUI chrome, built with SwiftPM.**

| Option | Launch | Size | Capture/clipboard | Verdict |
| --- | --- | --- | --- | --- |
| Swift + AppKit/SwiftUI | Instant | ~2 to 5 MB | Direct system APIs | **Use this** |
| Tauri + embedded Excalidraw | Web view start, ~0.5 to 1 s | ~15 to 30 MB | Needs Rust bridge | Too heavy. Excalidraw is a whiteboard, not an image editor. |
| Electron | Slow | 150 MB+ | Bridge | No |

Parts:

- **Canvas:** one `NSView` subclass. Core Graphics draws the image and the annotation objects. AppKit gives precise mouse, trackpad pinch, and scroll events. SwiftUI canvas is weaker for hit testing and handles.
- **Chrome:** SwiftUI tool bar and property panel inside `NSHostingView`. Quick to build, looks modern.
- **Capture v1:** run `/usr/sbin/screencapture -i -x <file>`. This gives the native macOS region and window picker at zero cost. Replace with a custom ScreenCaptureKit overlay later only if we need features the system picker lacks (for example, capture straight into the editor with a live magnifier).
- **Global hotkey:** Carbon `RegisterEventHotKey`. No Accessibility permission needed. No dependency.
- **Clipboard:** `NSPasteboard` read (PNG, TIFF, file URL) and write (PNG).
- **Blur/pixelate:** Core Image (`CIPixellate`, `CIGaussianBlur`) on the region.
- **Font for hand-drawn text:** Excalifont or Virgil (both SIL OFL). Bundle one. System font is the default option.

## Libraries reviewed

| Library | Use? | Reason |
| --- | --- | --- |
| [RoughSwift](https://github.com/onmyway133/RoughSwift) (MIT) | No | Runs rough.js inside JavaScriptCore. iOS only. Too heavy for a per-frame drawing path. |
| [rough.js](https://github.com/rough-stuff/rough) (MIT) | Port the idea | The sketchy line algorithm is small (random offset double strokes, hachure fill). Port only line, rect, ellipse, arrow to Swift (~200 lines). |
| [perfect-freehand](https://github.com/steveruizok/perfect-freehand) (MIT) | Port | Smooth, tapered pen strokes. Core is ~300 lines. Ports exist in Dart and Rust, no Swift port. |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT) | Later | User-configurable hotkeys. Not needed for v1 hardcoded keys. |
| [Capso](https://github.com/lzhgus/Capso) AnnotationKit | No | Business Source License. Needs Xcode 16. Good reference for feature list only. |
| [localshot](https://github.com/1shanpanta/localshot), [Snapzy](https://github.com/duongductrong/Snapzy) | Reference only | Native AppKit examples of the same app shape. |

Result: zero runtime dependencies in v1.

## Tools and shortcuts (Excalidraw style)

| Key | Tool |
| --- | --- |
| V / 1 | Select, move, resize |
| R / 2 | Rectangle (highlight an element) |
| O / 3 | Ellipse |
| A / 4 | Arrow |
| L / 5 | Line |
| P / 6 | Pen (freehand) |
| T / 7 | Text |
| H | Highlighter (translucent marker) |
| B | Blur / pixelate region |
| N | Number step (1, 2, 3 badges) |
| S | Spotlight (dim all except a region) |
| C | Crop |
| E | Extend canvas (padding, background color) |

Other keys: Cmd+Z / Shift+Cmd+Z undo and redo. Delete removes selection. Cmd+D duplicates. Shift constrains angle and aspect. Space+drag pans. Pinch, Cmd+scroll, Cmd+= / Cmd+- zoom. Cmd+0 fits. Cmd+1 shows 100%. Return or Cmd+C copies and closes. Cmd+S saves PNG. Esc closes.

Property panel (appears for the active tool or selection): color (6 swatches + picker), stroke width (thin, bold, extra bold), stroke style (solid, dashed), fill (none, solid, translucent), roughness (clean, sketchy), font size for text.

## UI

- One borderless-style window, sized to the image, max 85% of screen.
- Floating tool bar at the top center (Excalidraw pill shape). Property panel on the left, only when relevant.
- Dark neutral canvas background around the image. The image has a subtle shadow.
- Menu bar icon with: Capture region, Edit clipboard, Open file, Quit.

## Architecture

```
Sources/ShotitCore/         no UI state, tested
  Model.swift               Style, Annotation, Document, History (undo), SeededRandom
  Geometry.swift            hit test, handles, resize, crop frame handles
  Rough.swift               rough.js port (sketchy line, rect, ellipse)
  Renderer.swift            draws a Document into a CGContext (screen and export)
  ImageIO.swift             load from file or clipboard, flatten to PNG, copy
Sources/shotit/             the app
  App.swift                 menu bar item, main menu, hotkeys, capture
  EditorModel.swift         Tool, per-tool styles, selection, undo commands
  CanvasView.swift          NSView: mouse, keys, text editing, zoom
  EditorWindow.swift        window, scroll view, SwiftUI overlays
  Chrome.swift              SwiftUI toolbar, property panel, toast
scripts/bundle.py           release build, shotit.app, Info.plist, ad-hoc signature
Tests/ShotitCoreTests/      export, crop, extend, undo, geometry, rough
```

Key rule: one `Renderer` draws both the on-screen view and the exported PNG. The export then always matches what the user sees.

Annotations are value types (`struct`) in an array. Undo stores snapshots of the array. This is simple and correct, and the arrays are small.

## Phases

1. **Skeleton.** SwiftPM app, menu bar, bundle script, open clipboard image in a window, Cmd+C copies it back. *Verify:* round trip of a clipboard image is pixel-identical (unit test on export).
2. **Canvas core.** Zoom, pan, fit. Rectangle, ellipse, arrow, line. Select, move, resize handles, delete, undo/redo. *Verify:* tests for hit testing, resize geometry, undo.
3. **More tools.** Pen (freehand port), text (in-place edit), highlighter, number step, blur/pixelate, spotlight.
4. **Crop and extend.** Crop is non-destructive (canvas rect). Extend adds padding and background. *Verify:* export size tests.
5. **Capture.** Global hotkeys, `screencapture -i`, open editor. Quick access thumbnail (optional).
6. **Style.** Sketchy mode (rough port), bundled hand-drawn font, property panel polish.
7. **Later.** Magnifier callout, custom ScreenCaptureKit overlay, configurable hotkeys, OCR copy text (Vision), history.

## Known risks

- **Screen Recording permission.** macOS ties the grant to the code signature. An ad-hoc signed dev build can lose the grant after each rebuild. Mitigation: sign with a stable local certificate, or accept a re-grant during development. Clipboard mode needs no permission.
- **No full Xcode.** SwiftPM with Command Line Tools builds AppKit and SwiftUI apps. No asset catalogs or Interface Builder. We build the `.app` bundle by script.
- **Text editing on canvas.** This is the hardest single tool. Use a temporary `NSTextView` over the canvas while the user edits, then convert to a text annotation.

## Decisions (2026-09-28)

1. Extend: padding and background around the image. The crop tool does both (handles inside crop, outside extend).
2. Zoom: view zoom now. Magnifier callout stays in phase 7.
3. Minimum macOS: 14.
4. Default look: **sketchy** (Excalidraw). Clean and Wild are options in the panel.

## Status

Done: phases 1 to 6 in a first version. See "Changes from the plan" and "Not done yet".

### Changes from the plan

- Tests are an executable (`swift run shotit-tests`), not a test target. With Command Line Tools only, `swift test` finds zero Swift Testing tests (CLT Testing build 1902 with the Swift 6.3 compiler).
- Cmd+C copies and the window stays open. Return copies and closes. Cmd+W closes.
- Esc does not close the window (it clears the selection, then goes to the select tool). This prevents lost work.
- Pen uses midpoint smoothing, not a perfect-freehand port. Strokes have a constant width.
- Sketchy text uses the system font Chalkboard SE, not a bundled Excalifont. No font file to ship.
- The default tool is Arrow (Skitch style).
- Single selection only.

### Added after v1

- Quick-access card after capture (top center, tilted, sketchy border, "copied" tag). Capture copies at once.
  Click to annotate, drag out the file, hover for Annotate/Copy/Save/Close, closes after 10 s.
  Menu option "Open Editor After Capture" skips it.
- Grid (G, ⌘', toolbar popover): 8/16/32/64 pt, aligned to the image, major line every 4th.
  "Add grid to image" puts it in the export, only while it is visible. Not part of undo. No snap to grid.

### Not done yet

- Magnifier callout, custom ScreenCaptureKit overlay, configurable hotkeys, OCR, history.
- Drag the image out of the editor window into another app (the card supports drag out).
- Multi-select, copy and paste of annotations, custom color picker.
- Launch at login.
- Launch time and memory are not measured yet.
