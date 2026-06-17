import XCTest
import CoreGraphics
@testable import AnnotationModel

/// Tests for `Document.resolvePointer` — the pure decision that drives both
/// `select` mode and creation-mode pointer handling (handle grab / body move /
/// empty → create).
final class PointerTargetTests: XCTestCase {

    private func makeDoc(_ elements: [Annotation]) -> Document {
        Document(baseImage: .file(path: "/x.png"),
                 canvasSize: CGSize(width: 400, height: 400),
                 elements: elements)
    }

    private func filledRect() -> Annotation {
        .rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), fill: .red))
    }

    /// A corner of the current selection is grabbed as a resize handle.
    func testResolvePointerPrefersSelectionHandleWhenSelected() {
        let rect = filledRect()
        let doc = makeDoc([rect])
        let target = doc.resolvePointer(at: CGPoint(x: 102, y: 102), selection: rect.id,
                                        bodyTolerance: 8, handleTolerance: 8)
        XCTAssertEqual(target, .handle(rect.id, .bottomRight))
    }

    /// The same corner point is NOT a handle when nothing is selected — handles
    /// belong only to the current selection. It falls back to a body hit.
    func testResolvePointerHandleIgnoredWhenNotSelected() {
        let rect = filledRect()
        let doc = makeDoc([rect])
        let target = doc.resolvePointer(at: CGPoint(x: 102, y: 102), selection: nil,
                                        bodyTolerance: 8, handleTolerance: 8)
        XCTAssertEqual(target, .body(rect.id))
    }

    /// A point well inside the body (far from every corner) is a body hit even
    /// while selected.
    func testResolvePointerBodyHit() {
        let rect = filledRect()
        let doc = makeDoc([rect])
        let target = doc.resolvePointer(at: CGPoint(x: 50, y: 50), selection: rect.id,
                                        bodyTolerance: 8, handleTolerance: 8)
        XCTAssertEqual(target, .body(rect.id))
    }

    /// A point clear of every element resolves to empty (→ creation).
    func testResolvePointerEmpty() {
        let rect = filledRect()
        let doc = makeDoc([rect])
        let target = doc.resolvePointer(at: CGPoint(x: 300, y: 300), selection: rect.id,
                                        bodyTolerance: 8, handleTolerance: 8)
        XCTAssertEqual(target, .empty)
    }

    /// Overlapping bodies resolve to the topmost (front-to-back) element.
    func testResolvePointerTopmostBody() {
        let bottom = Annotation.rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), fill: .blue))
        let top = Annotation.rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 100, height: 100), fill: .red))
        let doc = makeDoc([bottom, top])
        let target = doc.resolvePointer(at: CGPoint(x: 50, y: 50), selection: nil,
                                        bodyTolerance: 0, handleTolerance: 8)
        XCTAssertEqual(target, .body(top.id))
    }
}
