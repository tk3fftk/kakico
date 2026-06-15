import XCTest
import CoreGraphics
@testable import AnnotationModel

final class AnnotationModelTests: XCTestCase {

    func testDistanceToSegment() {
        let d = GeometryMath.distance(from: CGPoint(x: 5, y: 5),
                                      toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        XCTAssertEqual(d, 5, accuracy: 0.0001)
        // Beyond the segment end clamps to the endpoint.
        let d2 = GeometryMath.distance(from: CGPoint(x: 20, y: 0),
                                       toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        XCTAssertEqual(d2, 10, accuracy: 0.0001)
    }

    func testRectFromCornersHandlesNegativeDrag() {
        let r = CGRect(corner: CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 0))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    func testArrowHitTest() {
        let arrow = SegmentElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), width: 6)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 50, y: 3), tolerance: 8))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 50, y: 40), tolerance: 8))
    }

    func testShapeStrokedHitTestEdgeOnly() {
        let shape = ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), width: 4)
        XCTAssertTrue(shape.hitTest(CGPoint(x: 0, y: 50), tolerance: 6))   // on the edge
        XCTAssertFalse(shape.hitTest(CGPoint(x: 50, y: 50), tolerance: 6)) // deep inside, no fill
    }

    func testShapeFilledHitTestInside() {
        let shape = ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), width: 4, fill: .red)
        XCTAssertTrue(shape.hitTest(CGPoint(x: 50, y: 50), tolerance: 0))
    }

    func testMoveHandleResizesShape() {
        var ann = Annotation.rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        ann.moveHandle(.bottomRight, to: CGPoint(x: 200, y: 150))
        if case .rectangle(let e) = ann {
            XCTAssertEqual(e.rect, CGRect(x: 0, y: 0, width: 200, height: 150))
        } else {
            XCTFail("kind changed")
        }
    }

    func testTranslatePreservesKind() {
        var ann = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 10, y: 0)))
        ann.translate(by: CGVector(dx: 5, dy: 5))
        guard case .arrow(let e) = ann else { return XCTFail("kind changed") }
        XCTAssertEqual(e.start, CGPoint(x: 5, y: 5))
        XCTAssertEqual(e.end, CGPoint(x: 15, y: 5))
    }

    func testDocumentTopmostHitTest() {
        let bottom = Annotation.rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), fill: .blue))
        let top = Annotation.rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), fill: .red))
        let doc = Document(baseImage: .file(path: "/x.png"), canvasSize: CGSize(width: 200, height: 200),
                           elements: [bottom, top])
        XCTAssertEqual(doc.hitTest(CGPoint(x: 50, y: 50), tolerance: 0), top.id)
    }

    /// Locks the on-disk JSON shape for `.arrow` / `.line` (fixture captured
    /// before Arrow/Line were merged into SegmentElement): old documents must
    /// keep decoding.
    func testArrowAndLineLegacyJSONDecodes() throws {
        let json = """
        [{"arrow":{"_0":{"color":{"a":1,"b":0.22,"g":0.16,"r":0.9},"end":[3,4],\
        "id":"11111111-1111-1111-1111-111111111111","start":[1,2],"width":6}}},\
        {"line":{"_0":{"color":{"a":1,"b":1,"g":0.48,"r":0},"end":[7,8],\
        "id":"22222222-2222-2222-2222-222222222222","start":[5,6],"width":3}}}]
        """
        let elements = try JSONDecoder().decode([Annotation].self, from: Data(json.utf8))
        guard case .arrow(let a) = elements[0], case .line(let l) = elements[1] else {
            return XCTFail("decoded wrong kinds")
        }
        XCTAssertEqual(a.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(a.start, CGPoint(x: 1, y: 2))
        XCTAssertEqual(a.end, CGPoint(x: 3, y: 4))
        XCTAssertEqual(a.width, 6)
        XCTAssertEqual(l.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(l.start, CGPoint(x: 5, y: 6))
        XCTAssertEqual(l.end, CGPoint(x: 7, y: 8))
        XCTAssertEqual(l.color, .blue)
    }

    func testArrowAndLineShareSegmentElement() {
        let seg = SegmentElement(start: .zero, end: CGPoint(x: 10, y: 0), width: 6)
        let arrow = Annotation.arrow(seg)
        let line = Annotation.line(seg)
        XCTAssertEqual(arrow.id, line.id)
        XCTAssertEqual(arrow.boundingBox(), line.boundingBox())
        XCTAssertEqual(arrow.handles(), line.handles())
    }

    /// Characterization for every rect-backed element: four corner handles,
    /// opposite-corner-anchored resize, translate, and inset-contains hit test.
    func testRectBackedElementsShareCornerEditing() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        var stamp = StampElement(rect: rect)
        var redaction = RedactionElement(rect: rect)
        var text = TextElement(origin: rect.origin, size: rect.size)

        for handles in [stamp.handles(), redaction.handles(), text.handles()] {
            XCTAssertEqual(handles.map(\.role), [.topLeft, .topRight, .bottomLeft, .bottomRight])
            XCTAssertEqual(handles[0].position, CGPoint(x: 10, y: 20))
            XCTAssertEqual(handles[3].position, CGPoint(x: 110, y: 70))
        }

        let resized = CGRect(x: 10, y: 20, width: 190, height: 200)
        stamp.moveHandle(.bottomRight, to: CGPoint(x: 200, y: 220))
        redaction.moveHandle(.bottomRight, to: CGPoint(x: 200, y: 220))
        text.moveHandle(.bottomRight, to: CGPoint(x: 200, y: 220))
        XCTAssertEqual(stamp.rect, resized)
        XCTAssertEqual(redaction.rect, resized)
        XCTAssertEqual(text.boundingBox(), resized)

        stamp.translate(by: CGVector(dx: 5, dy: -5))
        XCTAssertEqual(stamp.rect.origin, CGPoint(x: 15, y: 15))
        text.translate(by: CGVector(dx: 5, dy: -5))
        XCTAssertEqual(text.boundingBox(), resized.offsetBy(dx: 5, dy: -5))

        XCTAssertTrue(redaction.hitTest(CGPoint(x: 5, y: 15), tolerance: 6))   // tolerance band
        XCTAssertFalse(redaction.hitTest(CGPoint(x: -50, y: 0), tolerance: 6))
        XCTAssertTrue(text.hitTest(CGPoint(x: 16, y: 16), tolerance: 0))
    }

    func testTextElementCodableKeepsOriginAndSize() throws {
        let text = TextElement(origin: CGPoint(x: 7, y: 9), size: CGSize(width: 120, height: 30),
                               string: "hello")
        let data = try JSONEncoder().encode(Annotation.text(text))
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        XCTAssertEqual(decoded, .text(text))
        // origin/size are the stored representation — they must appear in JSON.
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"origin\""))
        XCTAssertTrue(json.contains("\"size\""))
    }

    func testAnnotationIDComesFromGeometry() {
        let seg = SegmentElement(start: .zero, end: CGPoint(x: 1, y: 1))
        let shape = ShapeElement(rect: .zero)
        let text = TextElement(origin: .zero)
        let stamp = StampElement(rect: .zero)
        let redaction = RedactionElement(rect: .zero)
        let cases: [(Annotation, ElementID)] = [
            (.arrow(seg), seg.id), (.line(seg), seg.id),
            (.rectangle(shape), shape.id), (.ellipse(shape), shape.id),
            (.text(text), text.id), (.stamp(stamp), stamp.id),
            (.pixelate(redaction), redaction.id), (.blur(redaction), redaction.id),
        ]
        for (annotation, id) in cases {
            XCTAssertEqual(annotation.id, id)
            XCTAssertEqual(annotation.geometry.id, id)
        }
    }

    func testDocumentMutateByID() {
        var doc = Document(baseImage: .file(path: "/x.png"), canvasSize: CGSize(width: 100, height: 100),
                           elements: [.stamp(StampElement(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))])
        let id = doc.elements[0].id
        doc.mutate(id) { $0.translate(by: CGVector(dx: 5, dy: 5)) }
        XCTAssertEqual(doc.elements[0].boundingBox().origin, CGPoint(x: 5, y: 5))

        let before = doc
        doc.mutate(UUID()) { $0.translate(by: CGVector(dx: 1, dy: 1)) }
        XCTAssertEqual(doc, before, "unknown id must be a no-op")
    }

    func testClampedCrop() {
        let doc = Document(baseImage: .file(path: "/x.png"), canvasSize: CGSize(width: 100, height: 80))
        // Fully inside: unchanged.
        XCTAssertEqual(doc.clampedCrop(CGRect(x: 10, y: 10, width: 50, height: 40)),
                       CGRect(x: 10, y: 10, width: 50, height: 40))
        // Overflowing: clamped to the canvas.
        XCTAssertEqual(doc.clampedCrop(CGRect(x: -20, y: 60, width: 200, height: 100)),
                       CGRect(x: 0, y: 60, width: 100, height: 20))
        // Degenerate or fully outside: nil.
        XCTAssertNil(doc.clampedCrop(CGRect(x: 10, y: 10, width: 1, height: 40)))
        XCTAssertNil(doc.clampedCrop(CGRect(x: 200, y: 200, width: 50, height: 50)))
    }

    func testCornerHandlesAndMovingCorner() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 20)
        let handles = rect.cornerHandles()
        XCTAssertEqual(handles.map(\.role), [.topLeft, .topRight, .bottomLeft, .bottomRight])
        XCTAssertEqual(handles[1].position, CGPoint(x: 10, y: 0))
        // Each corner resizes against the opposite (anchored) corner.
        XCTAssertEqual(rect.movingCorner(.topLeft, to: CGPoint(x: -5, y: -5)),
                       CGRect(x: -5, y: -5, width: 15, height: 25))
        XCTAssertEqual(rect.movingCorner(.bottomRight, to: CGPoint(x: 30, y: 40)),
                       CGRect(x: 0, y: 0, width: 30, height: 40))
        XCTAssertEqual(rect.movingCorner(.move, to: .zero), rect, "non-corner role: unchanged")
    }

    func testCornerRoleOpposite() {
        XCTAssertEqual(HandleRole.topLeft.opposite, .bottomRight)
        XCTAssertEqual(HandleRole.topRight.opposite, .bottomLeft)
        XCTAssertEqual(HandleRole.bottomLeft.opposite, .topRight)
        XCTAssertEqual(HandleRole.bottomRight.opposite, .topLeft)
        XCTAssertNil(HandleRole.move.opposite)
        XCTAssertNil(HandleRole.start.opposite)
    }

    func testRedactionDefaultAmounts() {
        XCTAssertEqual(RedactionElement.defaultPixelateAmount, 14)
        XCTAssertEqual(RedactionElement.defaultBlurAmount, 12)
    }

    func testSuggestedFontPointSizeScalesWithStrokeWidth() {
        XCTAssertEqual(FontSpec.suggestedPointSize(forStrokeWidth: 6), 24)
        XCTAssertEqual(FontSpec.suggestedPointSize(forStrokeWidth: 2), 18, "clamped to minimum")
        XCTAssertEqual(FontSpec.suggestedPointSize(forStrokeWidth: 10), 40)
    }

    func testDocumentCodableRoundTrip() throws {
        let doc = Document(
            baseImage: .pngData(Data([0, 1, 2, 3])),
            canvasSize: CGSize(width: 640, height: 480),
            elements: [
                .arrow(SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100))),
                .text(TextElement(origin: CGPoint(x: 10, y: 10), string: "hi")),
                .blur(RedactionElement(rect: CGRect(x: 0, y: 0, width: 50, height: 50), amount: 12)),
            ],
            crop: CGRect(x: 5, y: 5, width: 100, height: 100))
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(Document.self, from: data)
        XCTAssertEqual(doc, decoded)
    }
}
