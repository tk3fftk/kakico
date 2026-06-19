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
        XCTAssertEqual(e.rect.width, DefaultInitialSize.rect.width, accuracy: acc)
        XCTAssertEqual(e.rect.height, DefaultInitialSize.rect.height, accuracy: acc)
        XCTAssertEqual(e.rect.midX, p.x, accuracy: acc)
        XCTAssertEqual(e.rect.midY, p.y, accuracy: acc)
    }

    func testDegenerateEllipseAndPixelateGetDefaultSize() {
        let ell = Annotation.ellipse(ShapeElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize()
        guard case .ellipse(let e) = ell else { return XCTFail("kind changed") }
        XCTAssertEqual(e.rect.width, DefaultInitialSize.rect.width, accuracy: acc)

        let pix = Annotation.pixelate(RedactionElement(rect: CGRect(corner: p, p))).applyingDefaultInitialSize()
        guard case .pixelate(let r) = pix else { return XCTFail("kind changed") }
        XCTAssertEqual(r.rect.width, DefaultInitialSize.rect.width, accuracy: acc)
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
}
