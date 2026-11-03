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

## Development & Contributions

Kakico is a personal project I built for my own use. Its features and design
reflect what works best for me in my day-to-day workflow.

With that in mind, this repository's GitHub settings limit pull requests
to collaborators only.
Feature requests are welcome through Issues, though I cannot promise
that every suggestion will be implemented. Thank you for your understanding
and interest in the project.

## License

Kakico is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE).
Please refer to the license for the terms governing use, modification,
and distribution.

## Build & Run

```sh
swift test                       # Run unit tests (model + renderer)
./scripts/build-app.sh release   # Build & assemble an ad-hoc-signed Kakico.app
open build/Kakico.app
```

Requirements: macOS 15+, Xcode/Swift toolchain. The build script produces a native
arm64, ad-hoc-signed bundle (no Apple Developer account required).

## Rendering benchmark

Run the standalone CLI from this repository (no AI service required):

```sh
python3 scripts/benchmark-rendering.py
python3 scripts/benchmark-rendering.py --baseline-ref v0.1.2
python3 scripts/benchmark-rendering.py --help
```

Requires macOS 15+, Swift 6+, Python 3.9+, Git, and network access or a populated
SwiftPM dependency cache. The default also requires Homebrew-installed Kakico,
its application bundle, and a matching local `v<version>` Git tag. The installed
Homebrew version must match the app's version; missing tags or mismatches stop
the run. An explicit `--baseline-ref` bypasses Homebrew detection.

The CLI builds the baseline source and current working tree (including uncommitted
source changes) in Release, verifying each snapshot's pinned dependencies.
It measures 1080p/4K, 1/20/100 shapes, stroke widths 6/24, and first/middle/last
active elements (deduplicated for one shape). Each condition runs 35 frames;
the first 5 are excluded from the median and nearest-rank p95. Frame 0 is
reported separately, including initial cache preparation. Baseline runs first,
then current normal and cached rendering. No performance threshold is enforced.

Each run preserves source snapshots, Git diffs, environment details, build/run
logs, all frame timings (`samples.csv`), statistics and ratios (`summary.csv`),
and `comparison.md` under a unique `build/benchmarks/<timestamp>-<suffix>/`.
The final path is printed; failures return nonzero and retain diagnostics.
Missing conditions or frames are treated as failures.

This compares rebuilt sources, **not the installed binary**. Rendering differences
such as shadows are included. There is no base image; scale is 1. Screen transfer,
UI processing, loading and export are excluded. System load can affect results.
The repository skill at `.agents/skills/benchmark-rendering/SKILL.md` invokes this
same CLI via `$benchmark-rendering` or a rendering benchmark request.
