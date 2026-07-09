import Foundation
import CoreGraphics

/// A single annotation, discriminated by kind. Value type → cheap snapshots
/// for undo, free Codable/Equatable.
public enum Annotation: Codable, Equatable, Sendable, Identifiable {
    case arrow(SegmentElement)
    case line(SegmentElement)
    case rectangle(ShapeElement)
    case ellipse(ShapeElement)
    case text(TextElement)
    case pixelate(RedactionElement)

    public var id: ElementID { geometry.id }

    /// Read-only access to the element's geometry behaviour.
    public var geometry: AnnotationGeometry {
        switch self {
        case .arrow(let e): return e
        case .line(let e): return e
        case .rectangle(let e): return e
        case .ellipse(let e): return e
        case .text(let e): return e
        case .pixelate(let e): return e
        }
    }

    public func boundingBox() -> CGRect { geometry.boundingBox() }
    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool { geometry.hitTest(p, tolerance: tolerance) }
    public func handles() -> [Handle] { geometry.handles() }

    /// Stroke width of the wrapped element; nil for kinds without one
    /// (text, pixelate). Setting is a no-op for those kinds and for nil.
    public var strokeWidth: CGFloat? {
        get {
            switch self {
            case .arrow(let e), .line(let e): return e.width
            case .rectangle(let e), .ellipse(let e): return e.width
            case .text, .pixelate: return nil
            }
        }
        set {
            guard let width = newValue else { return }
            switch self {
            case .arrow(var e): e.width = width; self = .arrow(e)
            case .line(var e): e.width = width; self = .line(e)
            case .rectangle(var e): e.width = width; self = .rectangle(e)
            case .ellipse(var e): e.width = width; self = .ellipse(e)
            case .text, .pixelate: break
            }
        }
    }

    /// Color of the wrapped element; nil for kinds without one (pixelate).
    /// Setting is a no-op for those kinds and for nil.
    public var color: RGBAColor? {
        get {
            switch self {
            case .arrow(let e), .line(let e): return e.color
            case .rectangle(let e), .ellipse(let e): return e.color
            case .text(let e): return e.color
            case .pixelate: return nil
            }
        }
        set {
            guard let color = newValue else { return }
            switch self {
            case .arrow(var e): e.color = color; self = .arrow(e)
            case .line(var e): e.color = color; self = .line(e)
            case .rectangle(var e): e.color = color; self = .rectangle(e)
            case .ellipse(var e): e.color = color; self = .ellipse(e)
            case .text(var e): e.color = color; self = .text(e)
            case .pixelate: break
            }
        }
    }

    /// Skitch-style placement: a plain click drops a degenerate (zero-size)
    /// element; give it a sensible default size anchored at the click point so
    /// the object appears without a drag. Non-degenerate (drag-created)
    /// elements and text (already placed at a default size) are unchanged.
    public func applyingDefaultInitialSize(canvasSize: CGSize) -> Annotation {
        switch self {
        case .arrow(let e):     return .arrow(Self.defaultSized(e, canvasSize: canvasSize))
        case .line(let e):      return .line(Self.defaultSized(e, canvasSize: canvasSize))
        case .rectangle(let e): return .rectangle(Self.defaultSized(e, canvasSize: canvasSize))
        case .ellipse(let e):   return .ellipse(Self.defaultSized(e, canvasSize: canvasSize))
        case .pixelate(let e):  return .pixelate(Self.defaultSized(e, canvasSize: canvasSize))
        case .text:             return self   // already placed at a default size
        }
    }

    // Degeneracy is judged on raw geometry (not boundingBox, whose -width inset
    // would make a zero-length segment look non-degenerate).
    private static func defaultSized(_ e: SegmentElement, canvasSize: CGSize) -> SegmentElement {
        guard GeometryMath.distance(from: e.start, to: e.end) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        let vector = DefaultInitialSize.segment(forCanvasSize: canvasSize)
        e.end = CGPoint(x: e.start.x + vector.dx,
                        y: e.start.y + vector.dy)
        return e
    }

    private static func defaultSized<T: RectGeometry>(_ e: T, canvasSize: CGSize) -> T {
        guard max(e.rect.width, e.rect.height) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        e.rect = DefaultInitialSize.rect(centeredOn: e.rect.origin, canvasSize: canvasSize)
        return e
    }

    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        mutate { $0.moveHandle(role, to: point) }
    }

    public mutating func translate(by delta: CGVector) {
        mutate { $0.translate(by: delta) }
    }

    /// Applies a mutation to the wrapped element while preserving its kind.
    private mutating func mutate(_ body: (inout AnnotationGeometry) -> Void) {
        switch self {
        case .arrow(var e): var g: AnnotationGeometry = e; body(&g); e = g as! SegmentElement; self = .arrow(e)
        case .line(var e): var g: AnnotationGeometry = e; body(&g); e = g as! SegmentElement; self = .line(e)
        case .rectangle(var e): var g: AnnotationGeometry = e; body(&g); e = g as! ShapeElement; self = .rectangle(e)
        case .ellipse(var e): var g: AnnotationGeometry = e; body(&g); e = g as! ShapeElement; self = .ellipse(e)
        case .text(var e): var g: AnnotationGeometry = e; body(&g); e = g as! TextElement; self = .text(e)
        case .pixelate(var e): var g: AnnotationGeometry = e; body(&g); e = g as! RedactionElement; self = .pixelate(e)
        }
    }
}
