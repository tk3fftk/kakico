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

    /// Skitch-style placement: a plain click drops a degenerate (zero-size)
    /// element; give it a sensible default size anchored at the click point so
    /// the object appears without a drag. Non-degenerate (drag-created)
    /// elements and text (already placed at a default size) are unchanged.
    public func applyingDefaultInitialSize() -> Annotation {
        switch self {
        case .arrow(let e):     return .arrow(Self.defaultSized(e))
        case .line(let e):      return .line(Self.defaultSized(e))
        case .rectangle(let e): return .rectangle(Self.defaultSized(e))
        case .ellipse(let e):   return .ellipse(Self.defaultSized(e))
        case .pixelate(let e):  return .pixelate(Self.defaultSized(e))
        case .text:             return self   // already placed at a default size
        }
    }

    // Degeneracy is judged on raw geometry (not boundingBox, whose -width inset
    // would make a zero-length segment look non-degenerate).
    private static func defaultSized(_ e: SegmentElement) -> SegmentElement {
        guard GeometryMath.distance(from: e.start, to: e.end) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        e.end = CGPoint(x: e.start.x + DefaultInitialSize.segment.dx,
                        y: e.start.y + DefaultInitialSize.segment.dy)
        return e
    }

    private static func defaultSized<T: RectGeometry>(_ e: T) -> T {
        guard max(e.rect.width, e.rect.height) < DefaultInitialSize.degenerateThreshold else { return e }
        var e = e
        e.rect = DefaultInitialSize.rect(centeredOn: e.rect.origin)
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
