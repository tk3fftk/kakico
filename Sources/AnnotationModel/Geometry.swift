import Foundation
import CoreGraphics

/// Model coordinate space is image pixel space with a top-left origin and y
/// increasing downward. The renderer is responsible for mapping this into a
/// drawing context.

public struct RGBAColor: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let red = RGBAColor(r: 0.90, g: 0.16, b: 0.22)
    public static let yellow = RGBAColor(r: 1.0, g: 0.80, b: 0.0)
    public static let green = RGBAColor(r: 0.16, g: 0.70, b: 0.30)
    public static let blue = RGBAColor(r: 0.0, g: 0.48, b: 1.0)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
}

public struct FontSpec: Codable, Equatable, Sendable {
    public var family: String
    public var pointSize: Double
    public var bold: Bool

    public init(family: String = "Helvetica Neue", pointSize: Double = 28, bold: Bool = true) {
        self.family = family
        self.pointSize = pointSize
        self.bold = bold
    }

    /// Point size for new text elements, derived from the current stroke
    /// width so text roughly matches the weight of drawn annotations.
    public static func suggestedPointSize(forStrokeWidth width: CGFloat) -> Double {
        Double(max(18, width * 4))
    }

    /// Inverse of `suggestedPointSize(forStrokeWidth:)`, used to reflect a
    /// selected text's size on the stroke-width slider.
    public static func strokeWidth(forPointSize pointSize: Double) -> CGFloat {
        CGFloat(pointSize / 4)
    }
}

/// A reference to the base image. Either an absolute file path or PNG bytes
/// embedded in the document package.
public enum ImageRef: Codable, Equatable, Sendable {
    case file(path: String)
    case pngData(Data)
}

/// Default geometry for click-to-place (no-drag) object creation, Skitch-style.
public enum DefaultInitialSize {
    /// Raw extent below which a freshly created element counts as a plain click
    /// (no real drag) and gets a default size instead.
    public static let degenerateThreshold: CGFloat = 3
    /// Tail→head vector for a freshly placed arrow/line (down-right).
    public static let segment = CGVector(dx: 100, dy: 70)
    /// Default box for a freshly placed rectangle/ellipse/pixelate.
    public static let size = CGSize(width: 120, height: 90)

    /// The default box centered on the click point.
    public static func rect(centeredOn point: CGPoint) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
               width: size.width, height: size.height)
    }
}

public enum GeometryMath {
    /// Euclidean distance between two points.
    public static func distance(from p: CGPoint, to q: CGPoint) -> CGFloat {
        hypot(q.x - p.x, q.y - p.y)
    }

    /// Shortest distance from point `p` to the line segment `a`–`b`.
    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 {
            return hypot(p.x - a.x, p.y - a.y)
        }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
    }
}

extension CGRect {
    /// A rect built from two arbitrary corner points (handles negative drags).
    public init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x),
                  y: min(a.y, b.y),
                  width: abs(b.x - a.x),
                  height: abs(b.y - a.y))
    }

    public var corners: (topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) {
        (CGPoint(x: minX, y: minY),
         CGPoint(x: maxX, y: minY),
         CGPoint(x: minX, y: maxY),
         CGPoint(x: maxX, y: maxY))
    }
}
