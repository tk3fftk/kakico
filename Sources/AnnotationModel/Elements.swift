import Foundation
import CoreGraphics

public typealias ElementID = UUID

// MARK: - Segment (arrow / line share geometry)

public struct SegmentElement: Codable, Equatable, Sendable, AnnotationGeometry {
    public var id: ElementID
    public var start: CGPoint
    public var end: CGPoint
    public var color: RGBAColor
    public var width: CGFloat

    public init(id: ElementID = UUID(), start: CGPoint, end: CGPoint,
                color: RGBAColor = .red, width: CGFloat = 6) {
        self.id = id; self.start = start; self.end = end
        self.color = color; self.width = width
    }

    public func boundingBox() -> CGRect {
        CGRect(corner: start, end).insetBy(dx: -width, dy: -width)
    }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        GeometryMath.distance(from: point, toSegment: start, end) <= max(tolerance, width)
    }

    public func handles() -> [Handle] {
        [Handle(role: .start, position: start), Handle(role: .end, position: end)]
    }

    public mutating func moveHandle(_ role: HandleRole, to point: CGPoint) {
        switch role {
        case .start: start = point
        case .end: end = point
        default: break
        }
    }

    public mutating func translate(by delta: CGVector) {
        start.x += delta.dx; start.y += delta.dy
        end.x += delta.dx; end.y += delta.dy
    }
}

// MARK: - Shape (rectangle / ellipse share geometry)

public struct ShapeElement: Codable, Equatable, Sendable, RectGeometry {
    public var id: ElementID
    public var rect: CGRect
    public var color: RGBAColor
    public var width: CGFloat
    public var fill: RGBAColor?

    public init(id: ElementID = UUID(), rect: CGRect,
                color: RGBAColor = .red, width: CGFloat = 6, fill: RGBAColor? = nil) {
        self.id = id; self.rect = rect; self.color = color
        self.width = width; self.fill = fill
    }

    public func boundingBox() -> CGRect { rect.insetBy(dx: -width, dy: -width) }

    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if fill != nil { return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        // Stroked: hit if near the edge band but not deep inside.
        let outer = rect.insetBy(dx: -max(tolerance, width), dy: -max(tolerance, width))
        let inner = rect.insetBy(dx: max(tolerance, width), dy: max(tolerance, width))
        return outer.contains(point) && !inner.contains(point)
    }
}

// MARK: - Text

public struct TextElement: Codable, Equatable, Sendable, RectGeometry {
    public var id: ElementID
    public var origin: CGPoint        // top-left of the text box
    public var size: CGSize           // measured/last-known box size
    public var string: String
    public var font: FontSpec
    public var color: RGBAColor

    /// Rect-backed view over the stored origin/size (which stay the encoded
    /// representation).
    public var rect: CGRect {
        get { CGRect(origin: origin, size: size) }
        set { origin = newValue.origin; size = newValue.size }
    }

    public init(id: ElementID = UUID(), origin: CGPoint, size: CGSize = CGSize(width: 160, height: 40),
                string: String = "", font: FontSpec = FontSpec(), color: RGBAColor = .red) {
        self.id = id; self.origin = origin; self.size = size
        self.string = string; self.font = font; self.color = color
    }
}

// MARK: - Stamp

public enum StampKind: String, Codable, Sendable, CaseIterable {
    case check, cross, star, exclaim, heart
}

public struct StampElement: Codable, Equatable, Sendable, RectGeometry {
    public var id: ElementID
    public var rect: CGRect
    public var kind: StampKind
    public var color: RGBAColor

    public init(id: ElementID = UUID(), rect: CGRect, kind: StampKind = .check, color: RGBAColor = .red) {
        self.id = id; self.rect = rect; self.kind = kind; self.color = color
    }
}

// MARK: - Redaction (pixelate / blur)

public struct RedactionElement: Codable, Equatable, Sendable, RectGeometry {
    /// Default strengths for freshly created redactions.
    public static let defaultPixelateAmount: CGFloat = 14
    public static let defaultBlurAmount: CGFloat = 12

    public var id: ElementID
    public var rect: CGRect
    public var amount: CGFloat        // pixel block size or blur radius

    public init(id: ElementID = UUID(), rect: CGRect, amount: CGFloat = 16) {
        self.id = id; self.rect = rect; self.amount = amount
    }
}
