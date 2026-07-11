# Kakico

A native **Apple Silicon (arm64)** screenshot-annotation app for macOS, written in
Swift (SwiftUI shell + AppKit canvas, Core Graphics / Core Image rendering).


## What it does

Open or paste an image, mark it up, and export:

- **Tools:** arrow, line, rectangle, ellipse, text (inline editing), stamp
  (check / cross / star / exclaim / heart), pixelate, blur, and crop.
- **Editing:** select/move/resize via handles, undo/redo, delete.
- **Crop:** drag a crop rect (marching ants), re-edit it via corner handles or by
  dragging it around; `Return` applies it destructively (undoable), `Esc` cancels.
  Export honors a pending crop without applying it.
- **Output:** export PNG/JPEG, copy to clipboard, and drag-out as a PNG file
  (`NSFilePromiseProvider`).

Screen capture is intentionally out of scope — feed it images from macOS's built-in
Screenshot (⇧⌘4), Finder drag-drop, or paste.

## Build & run

```sh
swift test                       # run unit tests (model + renderer)
./scripts/build-app.sh release   # build & assemble an ad-hoc-signed Kakico.app
open build/Kakico.app
```

Requirements: macOS 13+, Xcode/Swift toolchain. The build script produces a native
arm64, ad-hoc-signed bundle (no Apple Developer account required).

## Architecture

- `AnnotationModel` (SwiftPM library, no UI deps) — value-type `Annotation` enum,
  `Document`, geometry/hit-testing, handles. Unit-tested headless.
- `AnnotationRender` (SwiftPM library) — one pure renderer used by both the on-screen
  canvas and file/clipboard export, so what you see equals what you get; pixelate/blur
  via Core Image.
- `Kakico` (executable) — SwiftUI app shell + AppKit `CanvasNSView` (mouse tracking,
  handles, crop overlay, inline text editing) + export/clipboard/drag-out services.

## Provenance / clean-room notice

This is an **independent, clean-room reimplementation** of a generic screenshot-annotation
workflow. It is **not affiliated with, derived from, or endorsed by Evernote or Skitch**.

No source code, artwork, icons, trademarks, or file formats were copied from Skitch.app.
All code and stamp artwork here are original. Runtime metadata from the old binary was
consulted only to enumerate *which features the workflow needed* — never as source to
translate. "Skitch" is a trademark of its respective owner and is not used as this
product's name.
