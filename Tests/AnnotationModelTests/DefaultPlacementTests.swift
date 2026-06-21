import XCTest
import CoreGraphics
@testable import AnnotationModel

/// Tests for `Annotation.applyingDefaultInitialSize()` — gives a freshly
/// clicked (degenerate) element a sensible default size so a plain click places
/// an object, Skitch-style. Non-degenerate elements (drag-created) are returned
/// unchanged.
final class DefaultPlacementTests: XCTestCase {

    private let acc: CGFloat = 0.0001
    private let p = CGPoint(x: 50, y: 60)

    func testDegenerateArrowGetsDefaultVector() {
        let result = Annotation.arrow(SegmentElement(start: p, end: p)).applyingDefaultInitialSize()
        guard case .arrow(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.start.x, p.x, accuracy: acc)
        XCTAssertEqual(e.start.y, p.y, accuracy: acc)
        XCTAssertEqual(e.end.x, p.x + DefaultInitialSize.segment.dx, accuracy: acc)
        XCTAssertEqual(e.end.y, p.y + DefaultInitialSize.segment.dy, accuracy: acc)
        XCTAssertGreaterThan(e.boundingBox().width, 3)
    }

    func testDegenerateLineGetsDefaultVector() {
        let result = Annotation.line(SegmentElement(start: p, end: p)).applyingDefaultInitialSize()
        guard case .line(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.end.x, p.x + DefaultInitialSize.segment.dx, accuracy: acc)
        XCTAssertEqual(e.end.y, p.y + DefaultInitialSize.segment.dy, accuracy: acc)
    }

    func testDegenerateRectIsCenteredDefaultSize() {
        let result = Annotation.rectangle(ShapeElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize()
        guard case .rectangle(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.size.width, accuracy: acc)
        XCTAssertEqual(e.rect.height, DefaultInitialSize.size.height, accuracy: acc)
        XCTAssertEqual(e.rect.midX, p.x, accuracy: acc)
        XCTAssertEqual(e.rect.midY, p.y, accuracy: acc)
    }

    func testDegenerateEllipseAndPixelateGetDefaultSize() {
        let ell = Annotation.ellipse(ShapeElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize()
        guard case .ellipse(let e) = ell else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.size.width, accuracy: acc)

        let pix = Annotation.pixelate(RedactionElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize()
        guard case .pixelate(let r) = pix else { return XCTFail("kind changed") }
        XCTAssertEqual(r.rect.width, DefaultInitialSize.size.width, accuracy: acc)
        XCTAssertEqual(r.rect.midY, p.y, accuracy: acc)
    }

    func testNonDegenerateArrowUnchanged() {
        let original = SegmentElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100))
        let result = Annotation.arrow(original).applyingDefaultInitialSize()
        XCTAssertEqual(result, .arrow(original))
    }

    func testNonDegenerateRectUnchanged() {
        let original = ShapeElement(rect: CGRect(x: 10, y: 10, width: 100, height: 80))
        let result = Annotation.rectangle(original).applyingDefaultInitialSize()
        XCTAssertEqual(result, .rectangle(original))
    }

    func testTextUnchanged() {
        let original = TextElement(origin: p, size: CGSize(width: 220, height: 44))
        let result = Annotation.text(original).applyingDefaultInitialSize()
        XCTAssertEqual(result, .text(original))
    }

    // MARK: - Boundary values (freeze current degeneracy behavior)

    /// A thin sliver drag (one axis well past the threshold) is an intentional
    /// shape and is left unchanged — rect degeneracy needs *both* axes tiny.
    func testThinRectIsLeftUnchanged() {
        let original = ShapeElement(rect: CGRect(x: 10, y: 10, width: 2, height: 200))
        let result = Annotation.rectangle(original).applyingDefaultInitialSize()
        XCTAssertEqual(result, .rectangle(original))
    }

    /// Both axes below the threshold (jitter on a plain click) counts as a click
    /// and gets the default size.
    func testTinyBoxBelowThresholdGetsDefaultSize() {
        let result = Annotation.rectangle(ShapeElement(rect: CGRect(x: 50, y: 60, width: 2.9, height: 2.9))).applyingDefaultInitialSize()
        guard case .rectangle(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.size.width, accuracy: acc)
        XCTAssertEqual(e.rect.height, DefaultInitialSize.size.height, accuracy: acc)
    }

    /// Exactly at the threshold is non-degenerate (comparison is strict `<`).
    func testRectAtThresholdIsLeftUnchanged() {
        let original = ShapeElement(rect: CGRect(x: 10, y: 10, width: 3, height: 3))
        let result = Annotation.rectangle(original).applyingDefaultInitialSize()
        XCTAssertEqual(result, .rectangle(original))
    }

    /// Segment hypot just below the threshold → promoted to the default vector.
    func testSegmentJustBelowThresholdGetsDefault() {
        let result = Annotation.line(SegmentElement(start: .zero, end: CGPoint(x: 2.99, y: 0))).applyingDefaultInitialSize()
        guard case .line(let e) = result else { return XCTFail("kind changed") }
        XCTAssertEqual(e.end.x, DefaultInitialSize.segment.dx, accuracy: acc)
        XCTAssertEqual(e.end.y, DefaultInitialSize.segment.dy, accuracy: acc)
    }

    /// Segment hypot at/above the threshold → left unchanged.
    func testSegmentJustAboveThresholdIsLeftUnchanged() {
        let original = SegmentElement(start: .zero, end: CGPoint(x: 3.01, y: 0))
        let result = Annotation.arrow(original).applyingDefaultInitialSize()
        XCTAssertEqual(result, .arrow(original))
    }
}
