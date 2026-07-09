import XCTest
import CoreGraphics
import AnnotationModel
@testable import Kakico

@MainActor
final class CanvasControllerTests: XCTestCase {

    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// A controller with a 2400×2000 image loaded — exactly double the
    /// reference canvas, so the expected widths are double the references
    /// (segment 32, shape 16).
    private func makeLoadedController() -> CanvasController {
        let controller = CanvasController()
        controller.loadImage(makeImage(width: 2400, height: 2000))
        return controller
    }

    // MARK: - Image-size-derived stroke width defaults (issue #32)

    func testLoadImageSetsStrokeWidthScaledToImageSize() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.tool, .arrow)
        XCTAssertEqual(controller.strokeWidth, 32, "double the reference canvas → double the segment reference")
    }

    func testLoadImageClampsStrokeWidthToSliderRange() {
        let controller = CanvasController()
        controller.loadImage(makeImage(width: 20, height: 20))
        XCTAssertEqual(controller.strokeWidth, DefaultStrokeWidth.range.lowerBound)
    }

    func testLoadingNewImageResetsUserAdjustedStrokeWidth() {
        let controller = makeLoadedController()
        controller.strokeWidth = 3
        controller.loadImage(makeImage(width: 2400, height: 2000))
        XCTAssertEqual(controller.strokeWidth, 32)
    }

    // MARK: - Per-tool-group stroke width memory

    func testShapeToolsGetThinnerDefaultThanArrow() {
        let controller = makeLoadedController()
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 16, "shape reference is half the segment reference")
        controller.tool = .ellipse
        XCTAssertEqual(controller.strokeWidth, 16)
    }

    func testLineSharesArrowWidthGroup() {
        let controller = makeLoadedController()
        controller.tool = .line
        XCTAssertEqual(controller.strokeWidth, 32)
        controller.strokeWidth = 5
        controller.tool = .arrow
        XCTAssertEqual(controller.strokeWidth, 5)
    }

    func testToolSwitchRestoresEachGroupsRememberedWidth() {
        let controller = makeLoadedController()
        controller.strokeWidth = 5          // remembered for the segment group
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 16)
        controller.strokeWidth = 9          // remembered for the shape group
        controller.tool = .arrow
        XCTAssertEqual(controller.strokeWidth, 5)
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 9)
    }

    func testGrouplessToolKeepsCurrentSliderValue() {
        let controller = makeLoadedController()
        controller.tool = .select
        XCTAssertEqual(controller.strokeWidth, 32)
        controller.tool = .rectangle
        XCTAssertEqual(controller.strokeWidth, 16)
    }

    // MARK: - Tool switch clears selection

    func testToolSwitchClearsSelection() {
        let controller = makeLoadedController()
        let seg = SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100))
        let arrow = Annotation.arrow(seg)
        controller.document?.elements.append(arrow)
        controller.selection = arrow.id
        XCTAssertNotNil(controller.selection)
        controller.tool = .rectangle
        XCTAssertNil(controller.selection)
    }
}
