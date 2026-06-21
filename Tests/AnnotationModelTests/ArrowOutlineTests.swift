import XCTest
import CoreGraphics
@testable import AnnotationModel

/// Tests for the Skitch-style arrow outline — a single filled polygon with a
/// pointed tail, a shaft that tapers toward the head, and a wide barbed head.
/// `arrowOutline()` returns the 6 polygon points in winding order:
/// [tip, barbUpper, notchUpper, tail, notchLower, barbLower].
final class ArrowOutlineTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    func testReturnsSixPoints() {
        let a = SegmentElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 0), width: 6)
        XCTAssertEqual(a.arrowOutline().count, 6)
    }

    func testTipIsEndAndTailIsStart() {
        let start = CGPoint(x: 17, y: 23)
        let end = CGPoint(x: 140, y: 90)
        let pts = SegmentElement(start: start, end: end, width: 6).arrowOutline()
        XCTAssertEqual(pts[0].x, end.x, accuracy: acc)
        XCTAssertEqual(pts[0].y, end.y, accuracy: acc)
        XCTAssertEqual(pts[3].x, start.x, accuracy: acc)
        XCTAssertEqual(pts[3].y, start.y, accuracy: acc)
    }

    func testSymmetricAcrossAxisForHorizontalArrow() {
        let pts = SegmentElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 0), width: 6).arrowOutline()
        let (barbU, notchU, notchL, barbL) = (pts[1], pts[2], pts[4], pts[5])
        // Same axis position, mirrored perpendicular offset.
        XCTAssertEqual(barbU.x, barbL.x, accuracy: acc)
        XCTAssertEqual(barbU.y, -barbL.y, accuracy: acc)
        XCTAssertEqual(notchU.x, notchL.x, accuracy: acc)
        XCTAssertEqual(notchU.y, -notchL.y, accuracy: acc)
        // Head is wider than the shaft.
        XCTAssertGreaterThan(abs(barbU.y), abs(notchU.y))
    }

    func testHeadScalesWithWidth() {
        // Long arrow so the head length is not clamped at either width.
        let thin = SegmentElement(start: .zero, end: CGPoint(x: 400, y: 0), width: 6).arrowOutline()
        let thick = SegmentElement(start: .zero, end: CGPoint(x: 400, y: 0), width: 12).arrowOutline()
        // barb half-span (perpendicular offset) doubles with doubled width.
        XCTAssertEqual(abs(thick[1].y), abs(thin[1].y) * 2, accuracy: 0.01)
        // head length (length - baseX) also grows with width.
        let thinHead = 400 - thin[1].x
        let thickHead = 400 - thick[1].x
        XCTAssertGreaterThan(thickHead, thinHead)
    }

    func testHeadLengthClampedForShortArrow() {
        let length: CGFloat = 10
        let pts = SegmentElement(start: .zero, end: CGPoint(x: length, y: 0), width: 6).arrowOutline()
        let headLen = length - pts[1].x   // baseX = tip.x - headLen
        XCTAssertLessThanOrEqual(headLen, length * 0.85 + acc)
        XCTAssertGreaterThan(pts[1].x, 0)  // barbs do not cross behind the tail
    }

    func testRotationForVerticalArrow() {
        let pts = SegmentElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 100), width: 6).arrowOutline()
        XCTAssertEqual(pts[0].x, 0, accuracy: acc)       // tip
        XCTAssertEqual(pts[0].y, 100, accuracy: acc)
        XCTAssertEqual(pts[3].x, 0, accuracy: acc)       // tail
        XCTAssertEqual(pts[3].y, 0, accuracy: acc)
        // Barbs splay perpendicular to the (vertical) axis → mirrored in x.
        XCTAssertEqual(pts[1].x, -pts[5].x, accuracy: acc)
        XCTAssertEqual(pts[1].y, pts[5].y, accuracy: acc)
    }

    func testDegenerateArrowReturnsEmpty() {
        let pts = SegmentElement(start: CGPoint(x: 5, y: 5), end: CGPoint(x: 5, y: 5), width: 6).arrowOutline()
        XCTAssertTrue(pts.isEmpty)
    }
}
