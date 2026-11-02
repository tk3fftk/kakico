import XCTest
import CoreGraphics
import AnnotationModel
@testable import AnnotationRender

final class ShadowOptimizationTests: XCTestCase {
    private func document(size: CGSize, count: Int, width: CGFloat, phase: CGFloat = 0) -> Document {
        var doc = Document(baseImage: .pngData(Data()), canvasSize: size)
        for i in 0..<count {
            let x = CGFloat((i * 173) % max(1, Int(size.width) - 240)) + (i == 0 ? phase : 0)
            let y = CGFloat((i * 97) % max(1, Int(size.height) - 240))
            let color = RGBAColor(r: 1, g: 0.2, b: 0.1, a: 0.6)
            let shape = ShapeElement(rect: CGRect(x: x, y: y, width: 130 + (i == 0 ? phase : 0), height: 95),
                                     color: color, width: width, fill: RGBAColor(r: 0.1, g: 0.6, b: 1, a: 0.35))
            let line = SegmentElement(start: CGPoint(x: x, y: y + 140),
                                      end: CGPoint(x: x + 160 + (i == 0 ? phase : 0), y: y + 20), color: color, width: width)
            switch i % 4 {
            case 0: doc.add(.arrow(line))
            case 1: doc.add(.line(line))
            case 2: doc.add(.rectangle(shape))
            default: doc.add(.ellipse(shape))
            }
        }
        return doc
    }

    private func assertMatchesReference(_ doc: Document, scale: CGFloat,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try XCTUnwrap(ShadowReferenceRenderer.flatten(doc, baseImage: nil, scale: scale))
        let actual = try XCTUnwrap(Renderer.flatten(doc, baseImage: nil, scale: scale))
        let a = Array(try XCTUnwrap(actual.dataProvider?.data) as Data)
        let b = Array(try XCTUnwrap(original.dataProvider?.data) as Data)
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        let differences = zip(a, b).map { abs(Int($0) - Int($1)) }
        // Direct shadows and group compositing round 8-bit alpha differently at overlaps.
        XCTAssertLessThanOrEqual(Double(differences.reduce(0, +)) / Double(a.count), 0.15, file: file, line: line)
        XCTAssertLessThanOrEqual(differences.max() ?? 0, 4, file: file, line: line)
    }

    func testMatchesOriginalShadowRendering() throws {
        for scale: CGFloat in [1, 2] {
            for width: CGFloat in [6, 24, 48] {
                try assertMatchesReference(document(size: CGSize(width: 400, height: 300), count: 20,
                                                    width: width, phase: 0.5), scale: scale)
            }
        }
    }

    func testIndividualShapesAtEveryCanvasEdge() throws {
        let size = CGSize(width: 300, height: 300)
        for scale: CGFloat in [1, 2] {
            for width: CGFloat in [6, 24] {
                let shapes = document(size: size, count: 4, width: width).elements
                for element in shapes {
                    // Shift each kind to all four edges as well as the center.
                    for origin in [CGPoint(x: 0, y: 0), CGPoint(x: 250, y: 0),
                                   CGPoint(x: 0, y: 250), CGPoint(x: 250, y: 250), CGPoint(x: 70, y: 70)] {
                        var doc = Document(baseImage: .pngData(Data()), canvasSize: size)
                        var shifted = element
                        let box = shifted.boundingBox()
                        shifted.translate(by: CGVector(dx: origin.x - box.minX, dy: origin.y - box.minY))
                        doc.add(shifted)
                        try assertMatchesReference(doc, scale: scale)
                    }
                }
            }
        }
    }

    // Opt in: SHADOW_BENCHMARK=1 swift test -c release --filter ShadowOptimizationTests/testBenchmark
    func testBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SHADOW_BENCHMARK"] == "1" else { throw XCTSkip("opt-in Release benchmark") }
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160)] {
            for count in [1, 20, 100] {
                for width: CGFloat in [6, 24] {
                    for mode in ["noShadow", "original", "optimized"] {
                        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        ctx.translateBy(x: 0, y: size.height)
                        ctx.scaleBy(x: 1, y: -1)
                        var times: [Double] = []
                        for frame in 0..<35 {
                            let doc = document(size: size, count: count, width: width, phase: CGFloat(frame % 10))
                            ctx.clear(CGRect(origin: .zero, size: size))
                            let start = DispatchTime.now().uptimeNanoseconds
                            if mode != "optimized" { ShadowReferenceRenderer.draw(doc, baseImage: nil, shadows: mode != "noShadow", in: ctx) }
                            else { Renderer.draw(doc, baseImage: nil, in: ctx) }
                            ctx.flush()
                            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                            if frame >= 5 { times.append(elapsed) }
                        }
                        times.sort()
                        print("SHADOW_BENCH,\(Int(size.width)),\(count),\(Int(width)),\(mode),\(times[15]),\(times[28])")
                    }
                }
            }
        }
    }
}
