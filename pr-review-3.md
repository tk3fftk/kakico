# PR Review Response: #3 Shrink function

**PR:** https://github.com/tk3fftk/kakico/pull/3
**Author:** @tk3fftk
**State:** OPEN
**Date analyzed:** 2026-06-16

## Summary

| Metric | Count |
|--------|-------|
| Reviews | 4 |
| Inline comments | 11 |
| Already resolved | 8 |
| Action items remaining | 3 |

---

## Reviews

### @copilot-pull-request-reviewer — COMMENTED (×4 across commits 3d8af73, 92e54b7, d1a8d85, 987f3dc)

Copilot reviewed four times as the PR evolved. The overall approach is validated. Three open items remain from the latest round.

---

## Already Resolved (no action needed)

| # | Comment ID | File | Issue | Fixed in |
|---|-----------|------|-------|---------|
| 1 | 3414232126 | `KakicoApp.swift:57` | Edit menu found by hard-coded "Edit" title — locale bug | 92e54b7 (now uses `#selector(NSText.cut(_:))`) |
| 2 | 3414426064 | `KakicoApp.swift:8` | `blockedMenuActions` as `Set<String>` instead of `Set<Selector>` | d1a8d85 |
| 3 | 3414426122 | `KakicoApp.swift:67` | `EditMenuFilter` converted selector to string for comparison | d1a8d85 |
| 4 | 3414426162 | `CanvasView.swift:15` | `MinimalTextView` used `NSStringFromSelector` | d1a8d85 |
| 5 | 3414510832 | `Elements.swift:107` | `RedactionElement.init` default `amount: 16` conflicts with `defaultPixelateAmount = 14` | 987f3dc (init now uses `Self.defaultPixelateAmount`) |
| 6 | 3414510916 | `KakicoApp.swift:82` | Blocked items adjacent to separators left orphaned separators visible | 987f3dc (leading/trailing edge trim added) |
| 7 | 3414232205 | `AnnotationModelTests.swift:166` | `testDocumentCodableRoundTrip` was removed with `.blur` | Restored at L151–164 using `.pixelate` |

---

## Open Action Items

### 1. `Sources/Kakico/KakicoApp.swift` L62–81 — @Copilot (comment #3417173904, latest review)

**Diff context:**
```swift
private class EditMenuFilter: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard !item.isSeparatorItem else { continue }   // separators never reset here
            if let action = item.action {
                item.isHidden = blockedMenuActions.contains(action)
            } else {
                item.isHidden = blockedMenuTitles.contains(item.title)
            }
        }
        var trailingEdge = true
        for item in menu.items.reversed() {
            if trailingEdge, item.isSeparatorItem { item.isHidden = true }
            else if !item.isHidden { trailingEdge = false }
        }
        var leadingEdge = true
        for item in menu.items {
            if leadingEdge, item.isSeparatorItem { item.isHidden = true }
            else if !item.isHidden { leadingEdge = false }
        }
    }
}
```

**Comment:**
> `EditMenuFilter.menuWillOpen` never resets separator items' `isHidden` state (separators are skipped in the first loop), so once a separator is hidden on a prior open it can stay hidden even when it should be visible later. It also only trims leading/trailing separators, leaving consecutive separators between hidden items. Consider resetting separator visibility on every open and collapsing separator runs based on currently-visible items.

**Category:** Implementation needed

**Plan:**
1. Add a reset pass at the very start of `menuWillOpen` that sets `isHidden = false` on every item (both separators and regular items).
2. Apply the existing block logic for non-separator items.
3. Keep the leading/trailing edge trim.
4. Add a consecutive-separator collapse pass: walk the visible items in order and hide any separator that immediately follows another separator.

Proposed replacement for `KakicoApp.swift:62–82`:
```swift
private class EditMenuFilter: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Reset state from prior opens.
        for item in menu.items { item.isHidden = false }

        for item in menu.items {
            guard !item.isSeparatorItem else { continue }
            if let action = item.action {
                item.isHidden = blockedMenuActions.contains(action)
            } else {
                item.isHidden = blockedMenuTitles.contains(item.title)
            }
        }

        // Trim leading separators.
        var leadingEdge = true
        for item in menu.items {
            if leadingEdge, item.isSeparatorItem { item.isHidden = true }
            else if !item.isHidden { leadingEdge = false }
        }

        // Trim trailing separators.
        var trailingEdge = true
        for item in menu.items.reversed() {
            if trailingEdge, item.isSeparatorItem { item.isHidden = true }
            else if !item.isHidden { trailingEdge = false }
        }

        // Collapse consecutive separators.
        var lastWasSeparator = false
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                if lastWasSeparator { item.isHidden = true }
                else { lastWasSeparator = true }
            } else {
                lastWasSeparator = false
            }
        }
    }
}
```

**Draft reply:**
> You're right — the reset is missing and consecutive interior separators aren't collapsed. I'll add the full reset at the start of `menuWillOpen` and a consecutive-separator pass.

---

### 2. `Sources/AnnotationModel/Annotation.swift` L12 — @Copilot (comments #3414510886 and #3417173930, same concern raised twice)

**Diff context:**
```swift
 case text(TextElement)
-    case stamp(StampElement)
 case pixelate(RedactionElement)
-    case blur(RedactionElement)
```

**Comment:**
> Removing `.stamp`/`.blur` from `Annotation` changes the on-disk format. Previously-saved documents will now fail to open. Consider adding a migration path (e.g., map legacy `blur` → `pixelate`, drop `stamp`) or improving the user-facing error.

**Category:** Reply needed (no code change required if the break is intentional)

**Draft reply:**
> This is an intentional format break. The app is pre-release with no documents in the wild, so adding migration code now would be dead weight. If users accumulate saved documents before any breaking change is released, I'll add a custom `init(from:)` on `Annotation` that maps legacy `"blur"` → `.pixelate` and drops `"stamp"` elements.

---

### 3. `Tests/AnnotationRenderTests/AnnotationRenderTests.swift` after L105 — @Copilot (comment #3417173951)

**Diff context:**
```swift
// Removed blur redaction tests — nothing replaced them.
// Current render test suite ends at testArrowChangesPixels (L98).
// checkerImage helper (L107) is unused by any test.
```

**Comment:**
> After removing blur redaction tests, there are no unit tests exercising the pixelation path in `Renderer` (especially the CI region math/y-flip). Add a pixelate-focused regression test to validate that pixelation alters the intended region and is not vertically mirrored.

**Category:** Implementation needed

**Plan:**
1. Add `testPixelateChangesPixels` after `testArrowChangesPixels` (`AnnotationRenderTests.swift:105`):
   - Create a solid-white 100×100 base image.
   - Flatten once without annotations → `plain`.
   - Add `.pixelate(RedactionElement(rect: CGRect(x: 10, y: 10, width: 30, height: 30), amount: RedactionElement.defaultPixelateAmount))`.
   - Flatten again → `annotated`.
   - Assert `pixelHash(plain) != pixelHash(annotated)` — pixelation alters pixels.
2. Optionally add a y-flip guard: sample a pixel at `(25, 25)` (inside the rect, top area) in `annotated` and verify it differs from the same pixel in `plain`, while a pixel at `(75, 75)` (outside the rect) is unchanged.
3. The existing `checkerImage` helper at L107 can serve as a high-contrast base for this test instead of solid white, making any pixelation effect more detectable.

**Draft reply:**
> Good catch. I'll add a `testPixelateChangesPixels` test — pixel-hash diff to confirm the renderer fires at all, plus a spot-check within vs. outside the rect to guard against y-flip regressions.

---

## Action Items Checklist

- [ ] **`KakicoApp.swift:62–82`** — Reset all items at start of `menuWillOpen`; add consecutive-separator collapse pass (comment #3417173904)
- [ ] **Reply on `Annotation.swift`** — Acknowledge backward-compat break as intentional, no code change (comments #3414510886, #3417173930)
- [ ] **`AnnotationRenderTests.swift`** — Add `testPixelateChangesPixels` test covering the redaction render path and y-flip guard (comment #3417173951)
