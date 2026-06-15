import XCTest
import CoreGraphics
import UniformTypeIdentifiers
@testable import AnnotationModel
@testable import AnnotationRender

final class AnnotationRenderTests: XCTestCase {

    private func solidImage(_ size: CGSize, color: (Double, Double, Double)) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    func testFlattenProducesFullCanvasImage() {
        let base = solidImage(CGSize(width: 100, height: 80), color: (0, 0, 1))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 80))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)
        XCTAssertNotNil(out)
        XCTAssertEqual(out?.width, 100)
        XCTAssertEqual(out?.height, 80)
    }

    func testFlattenHonorsCrop() {
        let base = solidImage(CGSize(width: 100, height: 80), color: (0, 0, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 80))
        doc.crop = CGRect(x: 10, y: 10, width: 40, height: 20)
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)
        XCTAssertEqual(out?.width, 40)
        XCTAssertEqual(out?.height, 20)
    }

    func testFlattenScale() {
        let base = solidImage(CGSize(width: 50, height: 50), color: (1, 0, 0))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 50, height: 50))
        let out = Renderer.flatten(doc, baseImage: base, scale: 2)
        XCTAssertEqual(out?.width, 100)
        XCTAssertEqual(out?.height, 100)
    }

    func testPNGEncodeRoundTrips() {
        let base = solidImage(CGSize(width: 20, height: 20), color: (0, 1, 0))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 20, height: 20))
        let img = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let png = Renderer.encode(img, as: .png)
        XCTAssertNotNil(png)
        XCTAssertGreaterThan(png!.count, 8)
        // PNG magic number.
        XCTAssertEqual(Array(png!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    /// Top-red / bottom-blue base image must come out of `flatten` with red
    /// still on top (model space and CGImage row order are both top-down).
    private func topRedBottomBlueImage(_ size: CGSize) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGBitmapContext is y-up: the upper half is y >= h/2.
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
        return ctx.makeImage()!
    }

    func testFlattenPreservesBaseImageOrientation() {
        let base = topRedBottomBlueImage(CGSize(width: 40, height: 40))
        let doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 40))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let top = samplePixel(out, x: 20, y: 5)
        let bottom = samplePixel(out, x: 20, y: 35)
        XCTAssertGreaterThan(top.r, 200, "top of flattened image should be red")
        XCTAssertLessThan(top.b, 50)
        XCTAssertGreaterThan(bottom.b, 200, "bottom of flattened image should be blue")
        XCTAssertLessThan(bottom.r, 50)
    }

    /// An annotation near the model-space top must land near the top of the
    /// output, on top of the red half.
    func testElementPositionMatchesBaseImageOrientation() {
        let base = topRedBottomBlueImage(CGSize(width: 40, height: 40))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 40, height: 40))
        doc.add(.rectangle(ShapeElement(rect: CGRect(x: 2, y: 2, width: 36, height: 8),
                                        color: .black, width: 2, fill: .black)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        let inked = samplePixel(out, x: 20, y: 6)
        XCTAssertLessThan(inked.r + inked.g + inked.b, 90, "rect at model top should ink the output top")
        let bottom = samplePixel(out, x: 20, y: 35)
        XCTAssertGreaterThan(bottom.b, 200, "bottom half should remain blue")
    }

    func testArrowChangesPixels() {
        let base = solidImage(CGSize(width: 100, height: 100), color: (1, 1, 1))
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 100, height: 100))
        let plain = Renderer.flatten(doc, baseImage: base, scale: 1)!
        doc.add(.arrow(SegmentElement(start: CGPoint(x: 10, y: 50), end: CGPoint(x: 90, y: 50), color: .red, width: 8)))
        let annotated = Renderer.flatten(doc, baseImage: base, scale: 1)!
        XCTAssertNotEqual(pixelHash(plain), pixelHash(annotated))
    }

    private func checkerImage(_ size: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for y in 0..<size where y % 2 == 0 {
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: size, height: 1))
        }
        return ctx.makeImage()!
    }

    func testBlurAltersTexturedRegion() {
        let base = checkerImage(64)
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 64, height: 64))
        doc.add(.blur(RedactionElement(rect: CGRect(x: 16, y: 16, width: 32, height: 32), amount: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!
        // Average the blurred region; blurring a fine 2px black/white checker
        // must yield a mid-tone, not the original pure black/white extremes.
        var total = 0, count = 0
        for y in 22...42 {
            for x in 22...42 {
                total += samplePixel(out, x: x, y: y).r
                count += 1
            }
        }
        let avg = total / count
        XCTAssertGreaterThan(avg, 50, "blurred region too dark — redaction not averaging")
        XCTAssertLessThan(avg, 205, "blurred region too light — redaction not averaging")
    }

    /// Vertically asymmetric redaction: blur only the top quarter and verify
    /// the effect lands there — not mirrored to the bottom (regression guard
    /// for the y-flip in the CI region math).
    func testBlurRegionIsNotVerticallyMirrored() {
        let base = checkerImage(64)
        var doc = Document(baseImage: .pngData(Data()), canvasSize: CGSize(width: 64, height: 64))
        doc.add(.blur(RedactionElement(rect: CGRect(x: 8, y: 4, width: 48, height: 12), amount: 6)))
        let out = Renderer.flatten(doc, baseImage: base, scale: 1)!

        func rowAverage(_ y: Int) -> Int {
            var total = 0
            for x in 16...48 { total += samplePixel(out, x: x, y: y).r }
            return total / 33
        }
        // Inside the blurred band: averaged mid-tone.
        let inside = rowAverage(10)
        XCTAssertGreaterThan(inside, 50, "blur did not land in the requested band")
        XCTAssertLessThan(inside, 205, "blur did not land in the requested band")
        // Mirrored band near the bottom: untouched checker rows stay extreme.
        let mirroredBlack = rowAverage(54), mirroredWhite = rowAverage(55)
        let extreme = min(mirroredBlack, 255 - mirroredWhite) < 20
            || min(mirroredWhite, 255 - mirroredBlack) < 20
        XCTAssertTrue(extreme, "bottom band was altered — redaction region mirrored")
    }

    private func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
    }

    private func pixelHash(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        return data.reduce(into: Hasher()) { $0.combine($1) }.finalize()
    }
}
