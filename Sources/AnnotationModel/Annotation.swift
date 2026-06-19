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
        // Degeneracy is judged on raw geometry (not boundingBox, whose -width
        // inset would make a zero-length segment look non-degenerate).
        switch self {
        case .arrow(var e):
            guard hypot(e.end.x - e.start.x, e.end.y - e.start.y) < 3 else { return self }
            e.end = CGPoint(x: e.start.x + DefaultInitialSize.segment.dx,
                            y: e.start.y + DefaultInitialSize.segment.dy)
            return .arrow(e)
        case .line(var e):
            guard hypot(e.end.x - e.start.x, e.end.y - e.start.y) < 3 else { return self }
            e.end = CGPoint(x: e.start.x + DefaultInitialSize.segment.dx,
                            y: e.start.y + DefaultInitialSize.segment.dy)
            return .line(e)
        case .rectangle(var e):
            guard e.rect.width < 3, e.rect.height < 3 else { return self }
            e.rect = DefaultInitialSize.rect(centeredOn: e.rect.origin)
            return .rectangle(e)
        case .ellipse(var e):
            guard e.rect.width < 3, e.rect.height < 3 else { return self }
            e.rect = DefaultInitialSize.rect(centeredOn: e.rect.origin)
            return .ellipse(e)
        case .pixelate(var e):
            guard e.rect.width < 3, e.rect.height < 3 else { return self }
            e.rect = DefaultInitialSize.rect(centeredOn: e.rect.origin)
            return .pixelate(e)
        case .text:
            return self
        }
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
