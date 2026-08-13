# Kakico

![](https://github.com/user-attachments/assets/dcf8325a-cc4f-4c60-bd5a-a1bee41d629b)

Kakico is a native **Apple Silicon (arm64)** screenshot-annotation app for macOS, written in
Swift (SwiftUI shell + AppKit canvas, Core Graphics / Core Image rendering). Kakico aims to be a modern Skitch alternative.

## What it does

Open or paste an image, mark it up, and export (shortcuts shown in parentheses):

- **Tools:** Arrow (`A`), Line (`L`), Rectangle (`R`), Ellipse (`O`), Text (`T`), Pixelate (`P`), and Crop (`C`).
- **Editing:** Select/move/resize via handles, Undo (`Cmd+Z`), Redo (`Cmd+Shift+Z`), and Delete.
- **Output:** Export as PNG, JPEG, or lossy WebP; copy to clipboard (`Cmd+C`), and drag out as a PNG file.
- **Tabs:** Open tab (`Cmd+T`) and close tab (`Cmd+W`) and move tab (`Opt+Cmd+←/→`). Edit multiple images in separate tabs without losing active work.

## Install

```sh
brew tap tk3fftk/tap
brew install --cask kakico
```

Requires macOS 15+ on Apple Silicon. The app is ad-hoc signed (not notarized);
the cask removes the quarantine attribute on install so it opens normally.

## Build & Run

```sh
swift test                       # Run unit tests (model + renderer)
./scripts/build-app.sh release   # Build & assemble an ad-hoc-signed Kakico.app
open build/Kakico.app
```

Requirements: macOS 15+, Xcode/Swift toolchain. The build script produces a native
arm64, ad-hoc-signed bundle (no Apple Developer account required).
