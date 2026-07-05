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

    /// Largest scale at which `canvas` fits entirely inside `viewport`.
    static func fittedScale(canvas: CGSize, viewport: CGSize) -> CGFloat {
        guard canvas.width > 0, canvas.height > 0 else { return 1 }
        return min(viewport.width / canvas.width, viewport.height / canvas.height)
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
        let content = CGSize(width: canvas.width * scale, height: canvas.height * scale)
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
