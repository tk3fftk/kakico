import Foundation
import CoreGraphics

/// What a pointer is targeting on the canvas. Resolved purely from the model so
/// both `select` mode and creation-mode pointer handling share one decision.
public enum PointerTarget: Equatable, Sendable {
    case handle(ElementID, HandleRole)  // a resize handle of the current selection
    case body(ElementID)                // the topmost element hit under the point
    case empty                          // nothing hit
}

public extension Document {
    /// Resolves what the pointer is targeting, in priority order:
    /// 1. a resize handle of the current `selection` (within `handleTolerance`),
    /// 2. the topmost element body hit at `point` (within `bodyTolerance`),
    /// 3. `.empty`.
    ///
    /// Handles belong only to the current selection, mirroring what the canvas
    /// actually draws.
    func resolvePointer(at point: CGPoint, selection: ElementID?,
                        bodyTolerance: CGFloat, handleTolerance: CGFloat) -> PointerTarget {
        if let sel = selection, let element = elements.first(where: { $0.id == sel }) {
            for handle in element.handles()
            where hypot(handle.position.x - point.x, handle.position.y - point.y) <= handleTolerance {
                return .handle(sel, handle.role)
            }
        }
        if let hit = hitTest(point, tolerance: bodyTolerance) {
            return .body(hit)
        }
        return .empty
    }
}
