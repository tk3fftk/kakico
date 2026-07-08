
## Build

```
bash scripts/build-app.sh
```

Runs a release build, assembles the app bundle, ad-hoc signs, and verifies.
Output: `build/Kakico.app`

---

## Agent Guide for Swift and SwiftUI (macOS)

### Role

Senior macOS Engineer, specializing in SwiftUI and AppKit.

### Core instructions

- Target macOS 15.0 or later.
- Swift 6.2 or later.
- Use `@Observable` classes for state. Do not use `ObservableObject` or `@Published`.
- Do not introduce third-party frameworks or packages.
- Avoid AppKit unless a complex interaction requires `NSView` (e.g. `CanvasNSView`, `DragOutView`). Prefer SwiftUI-native solutions everywhere else.

### Swift instructions

- Prefer `struct` over `class`; use `class` only when reference semantics or identity are required.
- Use `async`/`await` and structured concurrency; avoid callbacks and `DispatchQueue` except at AppKit boundaries.
- Annotate `@MainActor` on classes that own UI state.
- Prefer `let` over `var`; make mutability explicit at the call site.
- Use `guard` for early returns to keep the happy path unindented.

### SwiftUI instructions

- All modern SwiftUI APIs are available on macOS 15: `@Observable`/`@Bindable`, `clipShape(.rect(cornerRadius:))`, `containerRelativeFrame()`, `ScrollPosition`/`defaultScrollAnchor`, and the new `Tab` API.
- With `@Observable`, consumers require no property wrapper — plain stored properties in `View` and `Commands` bodies are tracked automatically.
- Use `@Bindable` only when `$binding` syntax is needed for two-way writes.
- Prefer `@State` over `@StateObject` (deprecated pattern); `@Observable` objects passed from outside need no wrapper.

### Project structure

- `Sources/AnnotationModel/` — pure value-type model (no AppKit/SwiftUI imports).
- `Sources/AnnotationRender/` — CoreGraphics rendering of `Document` into `CGImage`.
- `Sources/Kakico/` — SwiftUI app: `KakicoApp.swift`, `WorkspaceController.swift` (tab management: one `CanvasController` per tab), `CanvasController.swift` (the `@Observable` per-tab state root), `CanvasView.swift` (AppKit bridge), `UI.swift` (all other views), `Theme.swift` (Miro-style tokens and shared chrome), `ZoomMath.swift` (pure zoom/pan geometry), `ExportService.swift`.
- `Tests/` — unit tests for AnnotationModel, AnnotationRender, and Kakico (ZoomMath, WorkspaceController).

### PR instructions

- Keep PRs focused; one logical change per PR.
- Include a brief description of what changed and why.
- All tests must pass (`swift test`) and the app must build (`bash scripts/build-app.sh`) before merging.
