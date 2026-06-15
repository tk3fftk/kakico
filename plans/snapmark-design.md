# Kakico — Design

> The product is **not** affiliated with or derived from Skitch.

> **Status: ✅ implemented (2026-06-12).** All phases (0–4) plus optional stamps are done;
> see `Sources/Kakico/` and the *Implementation status* section at the bottom for what shipped
> and where it deviates from this design.

## Context

The goal is a screenshot-annotation tool that runs **natively on Apple Silicon**. The
bundle at `./Skitch.app` is an **x86_64-only** Mach-O from 2020, signed by Evernote, with
**no source code**. It links dead frameworks (QTKit — removed, Carbon, StoreKit) and
bundles defunct Evernote sync frameworks (EDAM, ENAttachmentToPDF), all x86_64-only. A
real arm64-native version cannot be produced by recompiling — it must be reimplemented
from scratch.

**Decisions (locked):**
- **Scope:** Phase 1 core **plus** shape tools, blur/pixelate, crop, and drag-out.
  **Screen capture is out of scope** — images are opened from disk / pasted in (macOS's
  built-in Screenshot can feed the app). No ScreenCaptureKit, no Screen Recording TCC
  permission needed.
- **Legal posture: open-source-grade rigor.** Original product name (not "Skitch"),
  **original assets** (self-drawn icons/stamps or SF Symbols — **no PNG reuse** from the
  old bundle), and **no decompiled-source derivation**. The recovered Objective-C class
  catalog is used **only as behavioral reference** to understand *what the app did*, never
  as a source to translate. Document provenance in the repo.
- **Signing:** local **ad-hoc** signing (no paid Apple Developer account).

### Clean-room note
We observed Skitch's public, user-visible behavior and recovered a high-level class
inventory via runtime metadata (it had a vector annotation model with arrows, lines,
rectangles, ellipses, text, stamps, and a pixel-blur redaction tool). That informs *which
features to build*. We do **not** copy code, names, art, file formats, or method bodies.
The Swift model below is an independent design for a generic annotation editor.

## Target stack

- **Xcode app project** (not bare SwiftPM) — needs Info.plist, entitlements, ad-hoc
  signing, asset catalog. Internal logic in SwiftPM packages for clean, headless-testable
  boundaries (no AppKit in the model).
- **Minimum macOS target: 13 (Ventura)** — capture dropped, so the `SCScreenshotManager`
  floor no longer applies; 13 is a safe, broad baseline for AppKit + Core Image + file-promise drag.
- **SwiftUI shell + AppKit canvas.** AppKit `NSView` for the annotation surface (precise
  mouse-tracked handles, hit-testing, marching-ants crop, Core Graphics drawing); SwiftUI
  for tool palette / inspector / menus, canvas embedded via `NSViewRepresentable`. Entry:
  SwiftUI `App` + `NSApplicationDelegateAdaptor`.
- **Distribution:** ad-hoc signed, hardened runtime optional. Build-from-source for others.

## Layout

```
Kakico.xcodeproj
KakicoApp/
  App/        KakicoApp.swift (@main), AppDelegate, menus/commands
  Canvas/     CanvasView.swift (AppKit NSView: mouse tracking, handles, selection/crop overlay)
  Toolbar/    tool palette + color/stroke/font inspector (SwiftUI)
  Export/     ExportService.swift (CGImageDestination, NSPasteboard, NSFilePromiseProvider)
  Resources/  Assets.xcassets (ORIGINAL icons/stamps or SF Symbols), Info.plist
Packages/
  AnnotationModel/   Sources/.../Annotation.swift  (element enum, Document, geometry/hit-test)
  AnnotationRender/  Sources/.../Renderer.swift     (shared CG/CI drawing, flatten, pixelate/blur)
  AnnotationModelTests / AnnotationRenderTests
```

## Model design (`AnnotationModel`)

Value-type, enum-discriminated model (`Codable`/`Equatable`/`Sendable` — free undo via snapshots):

```swift
enum Annotation: Codable, Equatable, Identifiable {
    case arrow(SegmentElement)      // arrow + line share one struct
    case line(SegmentElement)
    case rectangle(ShapeElement)    // rectangle + ellipse share one struct
    case ellipse(ShapeElement)
    case text(TextElement)
    case stamp(StampElement)
    case pixelate(RedactionElement)
    case blur(RedactionElement)
}

struct Document: Codable, Equatable {
    var baseImage: ImageRef         // file ref or embedded PNG
    var canvasSize: CGSize
    var elements: [Annotation]      // draw order = array order
    var crop: CGRect?
}
```

Geometry via an `AnnotationGeometry` protocol defined **in `AnnotationModel`** (the element
value types conform directly — "pure" meaning no UI-framework dependency, so it stays
headless-testable):
`boundingBox()`, `hitTest(_:tolerance:)`, `handles()`, `moveHandle(_:to:)`, `translate(by:)`
(plus `id`). Rect-backed elements share a `RectGeometry` sub-protocol that supplies the
common corner-handle / resize / translate / hit-test defaults.
`Handle` roles (`HandleRole`): `.move`, `.start`, `.end`, and the four corners
`.topLeft` / `.topRight` / `.bottomLeft` / `.bottomRight`. (No `.width` handle — stroke
width is set from the toolbar slider, not by dragging.)

- Hit-test: distance-to-segment for vectors; edge-band/area for shapes; bbox for text/stamp; topmost-first (reversed iteration).
- `CanvasController` (`ObservableObject` + `@Published`) holds document + selection; undo is
  a hand-rolled snapshot stack of `(Document, baseImage)` pairs (not `UndoManager` — applying
  a crop swaps the base image, so the snapshot must carry it).
- Model in **image pixel space**; canvas applies one zoom/offset transform.
- Native save format: own `.kakico` JSON package (`document.json` + embedded `base.png`).

## Rendering & export (`AnnotationRender`)

One pure renderer used by both screen and export so WYSIWYG holds:
`Renderer.draw(_ doc:in ctx:scale:)` and `render(_:scale:) -> CGImage`.
- Vectors via Core Graphics paths (arrowhead via path math), text via `NSAttributedString`/`CTLine`, stamps via `CGImage` blit.
- Canvas: start with CG `draw(_:)`; move to CALayer-per-element if live drag needs it. Selection/crop overlay = `CAShapeLayer` with animated `lineDashPhase` (marching ants).
- Flatten → `CGContext` (sRGB, `canvasSize * scale`) → PNG/JPEG via `CGImageDestination`.
- Clipboard: `NSPasteboard.general` writes `NSImage` / `.png` data.
- Drag-out: `NSFilePromiseProvider` + delegate writing flattened PNG on demand; `beginDraggingSession` from canvas.

## Pixelate / blur (Core Image)

`RedactionElement` (rect + amount) rendered at draw/export time:
- Pixelate: `CIAffineClamp` → `CIPixellate(inputScale:)` → crop to rect → composite.
- Blur: `CIAffineClamp` → `CIGaussianBlur(inputRadius:)` → crop to rect → composite.
- Blur the base-image region only (predictable, cheap). Shared Metal-backed `CIContext` cached in the renderer; same path for live preview on a `CALayer`.

## Crop

- Crop widget: handle-driven crop rect over the canvas, marching-ants overlay (`CAShapeLayer`), edge/corner `NSTrackingArea`s. `Esc` cancels, `Return` applies.
- Crop stored as `Document.crop`; export/flatten honors it (output bounds = crop rect). Non-destructive (re-editable) until applied.

## Milestones (matched to the locked scope)

- ✅ **Phase 0 — Scaffold (2–3d):** Xcode project + `AnnotationModel`/`AnnotationRender` packages, SwiftUI app shell + AppDelegate, empty AppKit `CanvasView` embedded, Info.plist + ad-hoc signing, asset catalog. Model types compiling with geometry unit tests.
- ✅ **Phase 1 — MVP (5–8d):** Open image (File → Open, drag-drop, paste) → **Arrow + Text** tools → select/move/resize via handles → undo/redo → flatten → export PNG/JPEG + copy to clipboard. Color + stroke-width inspector, inline `NSTextView` text editing, selection overlay/handles. *First genuinely useful build.*
- ✅ **Phase 2 — Shapes (3–4d):** Rectangle, ellipse, line (reuse the vector/handle machinery from Phase 1).
- ✅ **Phase 3 — Redaction (2–3d):** Pixelate + blur via Core Image.
- ✅ **Phase 4 — Crop + drag-out (4–6d):** Crop widget + marching ants, `NSFilePromiseProvider` drag-out, native `.kakico` save/open.
- ✅ **Stamps (optional, 2–3d):** done with **original** vector stamp art (`StampPaths.swift` — check / cross / star / exclaim / heart; no PNG reuse).

**Total: ~2.5–3.5 weeks. First demoable, useful build ~1.5–2 weeks (end of Phase 1).**

## Verification

- **Unit (headless):** `swift test` in `AnnotationModel` (hit-testing, handle math, geometry, Codable round-trip) and `AnnotationRender` (flatten a known doc → compare CGImage pixels / hash; pixelate/blur/crop region correctness).
- **Per-phase manual (use the `/verify` or `/run` skill):**
  - Phase 1: build & launch, open a test PNG, drop an arrow + text, move/resize handles, undo/redo, Export PNG and Copy → paste into another app; confirm exported image matches on-screen.
  - Phase 2: each shape draws and re-edits via handles.
  - Phase 3: pixelate/blur visibly redacts a region and survives export.
  - Phase 4: crop changes export bounds and is re-editable; drag-out drops a PNG into Finder/Slack/Mail; `.kakico` save then reopen restores all elements + crop.
- **Native check:** `lipo -archs <app>/Contents/MacOS/Kakico` reports `arm64`; running process arch is arm64 (not Rosetta). `codesign --verify` passes for the ad-hoc signature.

## Appendix — recovered behavioral reference (NOT source)

Runtime-metadata inventory from the old binary, used only to enumerate which features
existed. No code/art/format is copied from these.

- Vector annotation model: arrow, line, rectangle, ellipse, text, stamp, color, layer.
- Redaction: pixel-blur tool over a rectangular region.
- Rendering: separate bitmap / vector / document renderers; per-node renderers.
- Edit affordances: per-element widget views with resize / reposition / width handles.
- Tools: a tool model with a current-tool concept and a tool bar.
- Crop: crop widget with grid, marching-ants selection, crop property on the document.
- Export/share: image export formats, pasteboard image, drag-out to share.

## Provenance (for the open-source repo)
- README: state the app is an independent, clean-room reimplementation of a generic
  screenshot-annotation workflow; not affiliated with or derived from Evernote/Skitch
  source, assets, or trademarks. All code and art original. Decompiled metadata was used
  only to enumerate which features existed, never copied.

## Implementation status (2026-06-12)

Everything above is implemented in `Kakico/`. Verified: `swift test` all green
(20 model + 10 render/E2E tests), `scripts/build-app.sh release` produces an
ad-hoc-signed bundle (`codesign --verify` passes, `lipo` reports `arm64`), and the app
was launched natively (proc_translated = 0) and exercised end-to-end.

### Deviations from this design (intentional)

- **SwiftPM instead of an Xcode project.** A single `Package.swift` builds the two
  libraries + the executable; `scripts/build-app.sh` assembles `build/Kakico.app`
  (Info.plist, PkgInfo, ad-hoc signing). No asset catalog — all icons are SF Symbols
  and stamps are code-drawn `CGPath`s, so none was needed.
- **Canvas drawing is plain CG `draw(_:)`** (the "start with" option). No
  CALayer-per-element; marching ants are a timer-driven dash phase rather than an
  animated `CAShapeLayer`. Performance is fine at current scope.
- **`.kakico` is a single JSON file** (base image embedded as PNG `Data`), not a
  `document.json` + `base.png` package directory.
- **Paste Image is ⇧⌘V**, not ⌘V — plain ⌘V must stay free for Edit ▸ Paste so the
  inline `NSTextView` text editor works.
- **Undo snapshots carry (Document, baseImage) pairs**, not just the document —
  applying a crop destructively swaps the base image, and undo must restore it.
- **Zoom/offset transform:** the canvas aspect-fits the image (one computed
  scale/offset); there is no user-controlled zoom yet.

### Simplification pass (2026-06-15)

A `/simplify` review consolidated duplicated code without changing behavior (the
on-disk `.kakico` JSON shape is unchanged — a legacy-fixture decode test guards it):

- **`SegmentElement` replaces `ArrowElement`/`LineElement`** — they were identical, so
  arrow and line now wrap one struct (mirroring how rectangle/ellipse share `ShapeElement`).
- **`RectGeometry` protocol** (in `AnnotationModel`) supplies the shared corner-handle /
  resize / translate / inset-hit-test behaviour for `ShapeElement`, `StampElement`,
  `RedactionElement`, and `TextElement` (which conforms via a computed `rect` over its
  stored origin/size). `id` moved onto the `AnnotationGeometry` protocol.
- **UI policy pushed into the model:** `RedactionElement.defaultPixelateAmount/.defaultBlurAmount`
  and `FontSpec.suggestedPointSize(forStrokeWidth:)` (was hard-coded in the view), plus
  `Document.mutate(id:_:)` and a single `Document.clampedCrop(_:)` normalizer (crop
  clamping had been duplicated with diverging rules in the view and controller).
- **Renderer** factored out the y-flip transform, fill-colour setup, and the
  pixelate/blur `CIFilter` construction into shared helpers.
- **Canvas** now caches the flattened image by content (re-renders only when the document
  or base image changes, not on every selection redraw) and shares `viewRect`/`drawHandle`
  helpers; crop corners reuse `cornerHandles()`/`HandleRole.opposite`. A shared
  `ImageLoader` deduplicates `CGImageSource` decoding.

### Notable fix found during verification

`CGContext.draw(_:in:)` assumes a y-up space; under the renderer's y-down model-space
CTM it mirrored the base image (and CI redaction patches) vertically — every export and
the on-screen canvas showed the photo upside down. Fixed with a local flip around each
image rect; orientation and asymmetric-region regression tests now guard this
(`testFlattenPreservesBaseImageOrientation`, `testBlurRegionIsNotVerticallyMirrored`).

### Crop behaviour as shipped

Drag a rect with the crop tool; re-edit via corner handles or drag inside to move;
clamped to the canvas on mouse-up. `Esc` cancels, `Return` (or the toolbar button)
applies **destructively but undoably** — trims the base image, translates elements,
shrinks the canvas. A *pending* crop stays non-destructive and export honors it.
