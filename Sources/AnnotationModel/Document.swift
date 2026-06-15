import Foundation
import CoreGraphics

/// The annotation document: a base image plus an ordered list of annotations
/// (draw order == array order) and an optional crop rect, all in image pixel
/// space.
public struct Document: Codable, Equatable, Sendable {
    public var baseImage: ImageRef
    public var canvasSize: CGSize
    public var elements: [Annotation]
    public var crop: CGRect?

    public init(baseImage: ImageRef, canvasSize: CGSize,
                elements: [Annotation] = [], crop: CGRect? = nil) {
        self.baseImage = baseImage
        self.canvasSize = canvasSize
        self.elements = elements
        self.crop = crop
    }

    /// Output bounds after crop (defaults to the full canvas).
    public var outputRect: CGRect {
        crop ?? CGRect(origin: .zero, size: canvasSize)
    }

    // MARK: Element lookup / mutation helpers

    public func index(of id: ElementID) -> Int? {
        elements.firstIndex { $0.id == id }
    }

    /// Topmost element hit at `point` (search front-to-back).
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> ElementID? {
        for element in elements.reversed() where element.hitTest(point, tolerance: tolerance) {
            return element.id
        }
        return nil
    }

    /// Mutates the element with `id` in place; no-op when absent.
    public mutating func mutate(_ id: ElementID, _ body: (inout Annotation) -> Void) {
        if let i = index(of: id) { body(&elements[i]) }
    }

    /// `rect` constrained to the canvas, or nil when the result is degenerate
    /// (thinner than 2pt either way) — the single source of crop validity.
    public func clampedCrop(_ rect: CGRect) -> CGRect? {
        let clamped = rect.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !clamped.isNull, clamped.width >= 2, clamped.height >= 2 else { return nil }
        return clamped
    }

    public mutating func add(_ element: Annotation) {
        elements.append(element)
    }

    public mutating func remove(_ id: ElementID) {
        if let i = index(of: id) { elements.remove(at: i) }
    }

    public mutating func bringToFront(_ id: ElementID) {
        guard let i = index(of: id) else { return }
        let e = elements.remove(at: i)
        elements.append(e)
    }
}
