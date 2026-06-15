import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnnotationModel
@testable import AnnotationRender

/// Produces a real annotated artifact from /tmp/claude/sample.png so the full
/// pipeline (every tool + crop) can be inspected visually. Skips silently if
/// the sample image is absent.
final class EndToEndArtifactTest: XCTestCase {

    func testAnnotateRealImage() throws {
        let inURL = URL(fileURLWithPath: "/tmp/claude/sample.png")
        guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw XCTSkip("sample.png not present")
        }
        let size = CGSize(width: base.width, height: base.height)
        var doc = Document(baseImage: .file(path: inURL.path), canvasSize: size)

        doc.add(.arrow(SegmentElement(start: CGPoint(x: 80, y: 320), end: CGPoint(x: 250, y: 150),
                                    color: .red, width: 8)))
        doc.add(.rectangle(ShapeElement(rect: CGRect(x: 300, y: 60, width: 200, height: 150),
                                        color: .blue, width: 6)))
        doc.add(.ellipse(ShapeElement(rect: CGRect(x: 60, y: 60, width: 200, height: 140),
                                      color: .green, width: 6)))
        doc.add(.line(SegmentElement(start: CGPoint(x: 60, y: 240), end: CGPoint(x: 540, y: 240),
                                  color: .yellow, width: 5)))
        doc.add(.text(TextElement(origin: CGPoint(x: 70, y: 20), size: CGSize(width: 400, height: 40),
                                  string: "Kakico — native arm64", font: FontSpec(pointSize: 30, bold: true),
                                  color: .black)))
        doc.add(.blur(RedactionElement(rect: CGRect(x: 340, y: 250, width: 140, height: 90), amount: 12)))
        doc.add(.pixelate(RedactionElement(rect: CGRect(x: 100, y: 250, width: 120, height: 80), amount: 14)))
        doc.add(.stamp(StampElement(rect: CGRect(x: 480, y: 300, width: 80, height: 80),
                                    kind: .check, color: .green)))

        let flat = try XCTUnwrap(Renderer.flatten(doc, baseImage: base, scale: 1))
        XCTAssertEqual(flat.width, base.width)
        let png = try XCTUnwrap(Renderer.encode(flat, as: .png))
        try png.write(to: URL(fileURLWithPath: "/tmp/claude/annotated.png"))

        // And a cropped variant.
        doc.crop = CGRect(x: 40, y: 10, width: 480, height: 360)
        let cropped = try XCTUnwrap(Renderer.flatten(doc, baseImage: base, scale: 1))
        XCTAssertEqual(cropped.width, 480)
        XCTAssertEqual(cropped.height, 360)
        try XCTUnwrap(Renderer.encode(cropped, as: .png)).write(to: URL(fileURLWithPath: "/tmp/claude/annotated-cropped.png"))
    }
}
