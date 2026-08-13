import XCTest
import CoreGraphics
@testable import AnnotationModel

/// Tests for `Annotation.applyingDefaultInitialSize(canvasSize:)` — gives a
/// freshly clicked (degenerate) element a sensible default size so a plain
/// click places an object, Skitch-style. Non-degenerate elements
/// (drag-created) are returned unchanged. Sizes scale with the canvas
/// diagonal; at the reference canvas size the scale factor is exactly 1.
final class DefaultPlacementTests: XCTestCase {

    private let acc: CGFloat = 0.0001
    private let p = CGPoint(x: 50, y: 60)
    private let canvas = DefaultSizeScale.referenceCanvasSize

    func testDegenerateArrowGetsDefaultVector() {
        let result = Annotation.arrow(SegmentElement(start: p, end: p)).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .arrow(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.start.x, p.x, accuracy: acc)
        XCTAssertEqual(e.start.y, p.y, accuracy: acc)
        XCTAssertEqual(e.end.x, p.x + DefaultInitialSize.segment.dx, accuracy: acc)
        XCTAssertEqual(e.end.y, p.y + DefaultInitialSize.segment.dy, accuracy: acc)
        XCTAssertGreaterThan(e.boundingBox().width, 3)
    }

    func testDegenerateLineGetsDefaultVector() {
        let result = Annotation.line(SegmentElement(start: p, end: p)).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .line(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.end.x, p.x + DefaultInitialSize.segment.dx, accuracy: acc)
        XCTAssertEqual(e.end.y, p.y + DefaultInitialSize.segment.dy, accuracy: acc)
    }

    func testDegenerateRectIsCenteredDefaultSize() {
        let result = Annotation.rectangle(ShapeElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .rectangle(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.size.width, accuracy: acc)
        XCTAssertEqual(e.rect.height, DefaultInitialSize.size.height, accuracy: acc)
        XCTAssertEqual(e.rect.midX, p.x, accuracy: acc)
        XCTAssertEqual(e.rect.midY, p.y, accuracy: acc)
    }

    func testDegenerateEllipseAndPixelateGetDefaultSize() {
        let ell = Annotation.ellipse(ShapeElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .ellipse(let e) = ell else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.size.width, accuracy: acc)

        let pix = Annotation.pixelate(RedactionElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .pixelate(let r) = pix else { return XCTFail("kind changed") }
        XCTAssertEqual(r.rect.width, DefaultInitialSize.size.width, accuracy: acc)
        XCTAssertEqual(r.rect.midY, p.y, accuracy: acc)
    }

    func testNonDegenerateArrowUnchanged() {
        let original = SegmentElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100))
        let result = Annotation.arrow(original).applyingDefaultInitialSize(canvasSize: canvas)
        XCTAssertEqual(result, .arrow(original))
    }

    func testNonDegenerateRectUnchanged() {
        let original = ShapeElement(rect: CGRect(x: 10, y: 10, width: 100, height: 80))
        let result = Annotation.rectangle(original).applyingDefaultInitialSize(canvasSize: canvas)
        XCTAssertEqual(result, .rectangle(original))
    }

    func testTextUnchanged() {
        let original = TextElement(origin: p, size: CGSize(width: 220, height: 44))
        let result = Annotation.text(original).applyingDefaultInitialSize(canvasSize: canvas)
        XCTAssertEqual(result, .text(original))
    }

    // MARK: - Canvas-size scaling

    /// Doubling both canvas dimensions doubles the diagonal, so placed
    /// defaults double too.
    func testDefaultsScaleWithCanvasDiagonal() {
        let doubled = CGSize(width: canvas.width * 2, height: canvas.height * 2)

        let arrow = Annotation.arrow(SegmentElement(start: p, end: p)).applyingDefaultInitialSize(canvasSize: doubled)
        guard case .arrow(let a) = arrow else { return XCTFail("kind changed") }
        XCTAssertEqual(a.end.x, p.x + DefaultInitialSize.segment.dx * 2, accuracy: acc)
        XCTAssertEqual(a.end.y, p.y + DefaultInitialSize.segment.dy * 2, accuracy: acc)

        let rect = Annotation.rectangle(ShapeElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize(canvasSize: doubled)
        guard case .rectangle(let r) = rect else { return XCTFail("kind changed") }
        XCTAssertEqual(r.rect.width, DefaultInitialSize.size.width * 2, accuracy: acc)
        XCTAssertEqual(r.rect.height, DefaultInitialSize.size.height * 2, accuracy: acc)
        XCTAssertEqual(r.rect.midX, p.x, accuracy: acc)
        XCTAssertEqual(r.rect.midY, p.y, accuracy: acc)
    }

    func testScaleFactorIsOneAtReferenceAndGuardsZeroSize() {
        XCTAssertEqual(DefaultSizeScale.factor(forCanvasSize: canvas), 1, accuracy: acc)
        XCTAssertEqual(DefaultSizeScale.factor(forCanvasSize: .zero), 1, accuracy: acc)
    }

    // MARK: - Boundary values (freeze current degeneracy behavior)

    /// A thin sliver drag (one axis well past the threshold) is an intentional
    /// shape and is left unchanged — rect degeneracy needs *both* axes tiny.
    func testThinRectIsLeftUnchanged() {
        let original = ShapeElement(rect: CGRect(x: 10, y: 10, width: 2, height: 200))
        let result = Annotation.rectangle(original).applyingDefaultInitialSize(canvasSize: canvas)
        XCTAssertEqual(result, .rectangle(original))
    }

    /// Both axes below the threshold (jitter on a plain click) counts as a click
    /// and gets the default size.
    func testTinyBoxBelowThresholdGetsDefaultSize() {
        let shape = ShapeElement(rect: CGRect(x: 50, y: 60, width: 2.9, height: 2.9))
        let result = Annotation.rectangle(shape).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .rectangle(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.size.width, accuracy: acc)
        XCTAssertEqual(e.rect.height, DefaultInitialSize.size.height, accuracy: acc)
    }

    /// Exactly at the threshold is non-degenerate (comparison is strict `<`).
    func testRectAtThresholdIsLeftUnchanged() {
        let original = ShapeElement(rect: CGRect(x: 10, y: 10, width: 3, height: 3))
        let result = Annotation.rectangle(original).applyingDefaultInitialSize(canvasSize: canvas)
        XCTAssertEqual(result, .rectangle(original))
    }

    /// Segment hypot just below the threshold → promoted to the default vector.
    func testSegmentJustBelowThresholdGetsDefault() {
        let result = Annotation.line(SegmentElement(start: .zero, end: CGPoint(x: 2.99, y: 0))).applyingDefaultInitialSize(canvasSize: canvas)
        guard case .line(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.end.x, DefaultInitialSize.segment.dx, accuracy: acc)
        XCTAssertEqual(e.end.y, DefaultInitialSize.segment.dy, accuracy: acc)
    }

    /// Segment hypot at/above the threshold → left unchanged.
    func testSegmentJustAboveThresholdIsLeftUnchanged() {
        let original = SegmentElement(start: .zero, end: CGPoint(x: 3.01, y: 0))
        let result = Annotation.arrow(original).applyingDefaultInitialSize(canvasSize: canvas)
        XCTAssertEqual(result, .arrow(original))
    }
}
