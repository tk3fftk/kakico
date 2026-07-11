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

    /// Skitch-style arrow outline: a single filled polygon with a pointed tail,
    /// a shaft that tapers toward the head, and a wide head with backward barbs
    /// and a concave notch. Whole shape scales with `width`. Returns the 6
    /// points in winding order [tip, barbUpper, notchUpper, tail, notchLower,
    /// barbLower], or `[]` for a degenerate (zero-length) arrow.
    public func arrowOutline() -> [CGPoint] {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return [] }   // rendering floor

        let ux = dx / length, uy = dy / length      // axis unit vector
        let px = -uy, py = ux                        // perpendicular unit vector

        let shaftHalf = max(1, width * 0.5)          // shaft half-width at the head base
        let headHalf = max(shaftHalf * 2.4, width * 1.8) // barb half-span
        let headLen = min(max(width * 4.0, 14), length * 0.85)
        let notch = headLen * 0.30                    // concave inset toward the tip
        let baseX = length - headLen
        let notchX = baseX + notch

        func pt(_ t: CGFloat, _ o: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * t + px * o, y: start.y + uy * t + py * o)
        }
        return [
            pt(length, 0),       // tip
            pt(baseX, headHalf), // upper barb
            pt(notchX, shaftHalf), // upper notch
            pt(0, 0),            // tail
            pt(notchX, -shaftHalf), // lower notch
            pt(baseX, -headHalf),   // lower barb
        ]
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

// MARK: - Redaction (pixelate)

public struct RedactionElement: Codable, Equatable, Sendable, RectGeometry {
    /// Default strengths for freshly created redactions.
    public static let defaultPixelateAmount: CGFloat = 14
    /// Valid pixel-block-size range; scaled defaults are clamped to it.
    public static let amountRange: ClosedRange<CGFloat> = 4...60

    /// The default block size scaled to the canvas (like stroke widths); at
    /// the reference canvas size this is `defaultPixelateAmount` itself.
    public static func defaultAmount(forCanvasSize size: CGSize) -> CGFloat {
        DefaultSizeScale.scaledDefault(reference: defaultPixelateAmount, clampedTo: amountRange,
                                       forCanvasSize: size)
    }

    public var id: ElementID
    public var rect: CGRect
    public var amount: CGFloat        // pixel block size

    public init(id: ElementID = UUID(), rect: CGRect, amount: CGFloat = Self.defaultPixelateAmount) {
        self.id = id; self.rect = rect; self.amount = amount
    }
}
