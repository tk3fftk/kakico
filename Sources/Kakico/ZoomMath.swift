import CoreGraphics

/// Canvas zoom state. `.fit` scales the image to fill the available viewport
/// (the historical default); `.percent` pins the scale so 1.0 draws one image
/// pixel per view point.
enum ZoomMode: Equatable {
    case fit
    case percent(CGFloat)
}

/// Pure geometry for zoom and pan. All sizes are in view points; pan offsets
/// are the displacement of the image center from the viewport center.
enum ZoomMath {
    static let presets: [CGFloat] = [0.25, 0.5, 1.0, 2.0, 4.0]

    /// Shared formatter for zoom UI labels (live percentage and menu presets).
    static func percentLabel(for scale: CGFloat) -> String {
        "\(Int((scale * 100).rounded()))%"
    }

    /// Largest scale at which `canvas` fits entirely inside `viewport`.
    static func fittedScale(canvas: CGSize, viewport: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        return min(viewport.width / canvas.width, viewport.height / canvas.height)
    }

    /// Size of the scaled canvas in view points.
    static func contentSize(canvas: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    /// Clamps a continuous (pinch) scale to the allowed zoom range. The floor
    /// drops below the smallest preset when the fitted scale is smaller, so
    /// huge images can still zoom back out to (roughly) fit.
    static func clampedScale(_ scale: CGFloat, canvas: CGSize, viewport: CGSize) -> CGFloat {
        let floor = min(presets.first!, fittedScale(canvas: canvas, viewport: viewport))
        return min(max(scale, floor), presets.last!)
    }

    /// Per axis: content that fits stays centered (offset 0); content that
    /// overflows is clamped so its edges never pull inside the viewport edge.
    static func clampedPan(_ pan: CGVector, content: CGSize, viewport: CGSize) -> CGVector {
        func clamp(_ v: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat {
            let slack = (content - viewport) / 2
            guard slack > 0 else { return 0 }
            return min(max(v, -slack), slack)
        }
        return CGVector(dx: clamp(pan.dx, content: content.width, viewport: viewport.width),
                        dy: clamp(pan.dy, content: content.height, viewport: viewport.height))
    }

    /// View-space rect for the scaled canvas: centered in the viewport, then
    /// displaced by the (clamped) pan offset.
    static func imageRect(canvas: CGSize, viewport: CGSize, scale: CGFloat, pan: CGVector) -> CGRect {
        let content = contentSize(canvas: canvas, scale: scale)
        let pan = clampedPan(pan, content: content, viewport: viewport)
        return CGRect(x: (viewport.width - content.width) / 2 + pan.dx,
                      y: (viewport.height - content.height) / 2 + pan.dy,
                      width: content.width, height: content.height)
    }

    /// Keeps the model point at the viewport center fixed across a scale
    /// change (zoom anchored at the view center).
    static func panPreservingCenter(oldPan: CGVector, oldScale: CGFloat, newScale: CGFloat) -> CGVector {
        guard oldScale > 0 else { return oldPan }
        let f = newScale / oldScale
        return CGVector(dx: oldPan.dx * f, dy: oldPan.dy * f)
    }

    // swiftlint:disable function_parameter_count
    /// Keeps the model point under `viewPoint` fixed across a scale change
    /// (pinch zoom anchored at the cursor). With `viewPoint` at the viewport
    /// center this reduces to `panPreservingCenter`. Pure geometry — all six
    /// parameters are independent coordinates of one mapping.
    static func panPreservingPoint(_ viewPoint: CGPoint, oldPan: CGVector,
                                   oldScale: CGFloat, newScale: CGFloat,
                                   canvas: CGSize, viewport: CGSize) -> CGVector {
        guard oldScale > 0 else { return oldPan }
        let f = newScale / oldScale
        func solve(_ v: CGFloat, pan: CGFloat, canvas: CGFloat, viewport: CGFloat) -> CGFloat {
            let rectMin = (viewport - canvas * oldScale) / 2 + pan
            let newRectMin = v - (v - rectMin) * f
            return newRectMin - (viewport - canvas * newScale) / 2
        }
        return CGVector(dx: solve(viewPoint.x, pan: oldPan.dx, canvas: canvas.width, viewport: viewport.width),
                        dy: solve(viewPoint.y, pan: oldPan.dy, canvas: canvas.height, viewport: viewport.height))
    }
    // swiftlint:enable function_parameter_count

    /// First preset above `current`; the epsilon keeps an exact preset from
    /// matching itself. Clamps at the largest preset.
    static func zoomInScale(from current: CGFloat) -> CGFloat {
        presets.first { $0 > current * 1.001 } ?? presets.last!
    }

    /// Last preset below `current`. Clamps at the smallest preset.
    static func zoomOutScale(from current: CGFloat) -> CGFloat {
        presets.last { $0 < current * 0.999 } ?? presets.first!
    }
}
