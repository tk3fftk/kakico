import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnnotationRender

final class WebPEncoderTests: XCTestCase {

    /// Photo-like content: smooth gradients with flat blocks on top.
    private func makeTestImage(width: Int, height: Int, alpha: CGFloat = 1) throws -> CGImage {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in stride(from: 0, to: width, by: 8) {
            let hue = CGFloat(x) / CGFloat(width)
            ctx.setFillColor(red: hue, green: 1 - hue, blue: 0.5, alpha: alpha)
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: height))
        }
        ctx.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: alpha)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 4))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func decodeWebP(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source))
        XCTAssertEqual(type as String, UTType.webP.identifier)
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Mean absolute per-channel error between an image and its decoded
    /// lossy round-trip, both normalized through the same sRGB context.
    private func meanAbsoluteError(_ a: CGImage, _ b: CGImage) throws -> Double {
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            try buf.withUnsafeMutableBytes { raw in
                let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress,
                                                  width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                  space: cs,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return buf
        }
        let pa = try pixels(a)
        let pb = try pixels(b)
        XCTAssertEqual(pa.count, pb.count)
        let total = zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(pa.count)
    }

    func testLossyRoundTripStaysClose() throws {
        let image = try makeTestImage(width: 320, height: 240)
        let data = try XCTUnwrap(WebPEncoder.encodeLossy(image, quality: 0.8))
        let decoded = try decodeWebP(data)
        XCTAssertEqual(decoded.width, 320)
        XCTAssertEqual(decoded.height, 240)
        // Lossy, so approximate: quality 80 keeps this content within a few
        // intensity levels on average.
        XCTAssertLessThanOrEqual(try meanAbsoluteError(image, decoded), 8)
    }

    func testLossyIsSmallerThanPNG() throws {
        let image = try makeTestImage(width: 512, height: 384)
        let webp = try XCTUnwrap(WebPEncoder.encodeLossy(image, quality: 0.8))
        let png = try XCTUnwrap(Renderer.encode(image, as: .png))
        XCTAssertLessThan(webp.count, png.count)
    }

    func testQualityAffectsSize() throws {
        let image = try makeTestImage(width: 320, height: 240)
        let low = try XCTUnwrap(WebPEncoder.encodeLossy(image, quality: 0.3))
        let high = try XCTUnwrap(WebPEncoder.encodeLossy(image, quality: 0.95))
        XCTAssertLessThan(low.count, high.count)
    }

    func testAlphaSurvivesApproximately() throws {
        let image = try makeTestImage(width: 64, height: 64, alpha: 0.5)
        let data = try XCTUnwrap(WebPEncoder.encodeLossy(image, quality: 0.8))
        let decoded = try decodeWebP(data)
        let alphaInfo = decoded.alphaInfo
        XCTAssertTrue(alphaInfo != .none && alphaInfo != .noneSkipLast && alphaInfo != .noneSkipFirst,
                      "decoded image should carry an alpha channel")
        XCTAssertLessThanOrEqual(try meanAbsoluteError(image, decoded), 8)
    }

    func testDimensionGuard() throws {
        // libwebp caps sides at 16383 (WEBP_MAX_DIMENSION).
        let oversized = try makeTestImage(width: 16384, height: 1)
        XCTAssertNil(WebPEncoder.encodeLossy(oversized, quality: 0.8))
    }

    func testRendererEncodeRoutesWebP() throws {
        let image = try makeTestImage(width: 40, height: 30)
        let data = try XCTUnwrap(Renderer.encode(image, as: .webP))
        let decoded = try decodeWebP(data)
        XCTAssertEqual(decoded.width, 40)
        XCTAssertEqual(decoded.height, 30)
    }
}
