import Foundation
import CoreGraphics

/// Identifies an editable control point on an element.
public enum HandleRole: Codable, Equatable, Hashable, Sendable {
    case move          // body drag (whole-element translate)
    case start         // vector start point
    case end           // vector end point
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// The diagonally opposite corner — the anchor when resizing by this
    /// corner. Nil for non-corner roles.
    public var opposite: HandleRole? {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        case .move, .start, .end: return nil
        }
    }
}

public struct Handle: Equatable, Sendable {
    public let role: HandleRole
    public let position: CGPoint

    public init(role: HandleRole, position: CGPoint) {
        self.role = role
        self.position = position
    }
}

/// Shared geometric behaviour every element implements. Kept pure so it is
/// unit-testable without any UI framework.
public protocol AnnotationGeometry {
    var id: ElementID { get }
    func boundingBox() -> CGRect
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool
    func handles() -> [Handle]
    mutating func moveHandle(_ role: HandleRole, to point: CGPoint)
    mutating func translate(by delta: CGVector)
}

/// A rect-backed element. Conformers get corner handles, opposite-corner
/// resizing, translation, and an inset-contains hit test for free.
public protocol RectGeometry: AnnotationGeometry {
    var rect: CGRect { get set }
}

public extension RectGeometry {
    func boundingBox() -> CGRect { rect }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    func handles() -> [Handle] { rect.cornerHandles() }

    mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        rect = rect.movingCorner(role, to: point)
    }

    mutating func translate(by delta: CGVector) {
        rect = rect.offsetBy(dx: delta.dx, dy: delta.dy)
    }
}

extension CGRect {
    public func cornerHandles() -> [Handle] {
        let c = corners
        return [
            Handle(role: .topLeft, position: c.topLeft),
            Handle(role: .topRight, position: c.topRight),
            Handle(role: .bottomLeft, position: c.bottomLeft),
            Handle(role: .bottomRight, position: c.bottomRight),
        ]
    }

    /// Returns a copy of this rect with the given corner moved to `point`.
    public func movingCorner(_ role: HandleRole, to point: CGPoint) -> CGRect {
        let c = corners
        switch role {
        case .topLeft:     return CGRect(corner: point, c.bottomRight)
        case .topRight:    return CGRect(corner: point, c.bottomLeft)
        case .bottomLeft:  return CGRect(corner: point, c.topRight)
        case .bottomRight: return CGRect(corner: point, c.topLeft)
        default:           return self
        }
    }
}
