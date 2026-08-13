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

    // MARK: - Pixelate amount ↔ selection sync

    private func makeRedaction(amount: CGFloat = 22) -> Annotation {
        .pixelate(RedactionElement(rect: CGRect(x: 10, y: 10, width: 200, height: 100), amount: amount))
    }

    func testLoadImageSetsPixelateAmountScaledToImageSize() {
        let controller = makeLoadedController()
        XCTAssertEqual(controller.pixelateAmount, 28, "double the reference canvas → double the pixelate reference")
    }

    func testLoadImageClampsPixelateAmountToRange() {
        let controller = CanvasController()
        controller.loadImage(makeImage(width: 20, height: 20))
        XCTAssertEqual(controller.pixelateAmount, RedactionElement.amountRange.lowerBound)
    }

    func testSelectingPixelateElementAdoptsItsAmount() {
        let controller = makeLoadedController()
        let redaction = makeRedaction(amount: 22)
        controller.document?.elements.append(redaction)
        controller.selection = redaction.id
        XCTAssertEqual(controller.pixelateAmount, 22)
    }

    func testSelectionSyncDoesNotWriteBackIntoDocument() {
        let controller = makeLoadedController()
        let redaction = makeRedaction(amount: 22)
        controller.document?.elements.append(redaction)
        let before = controller.document
        controller.selection = redaction.id
        XCTAssertEqual(controller.document, before, "adopting the amount must not count as an edit (isSyncing guard)")
    }

    func testChangingAmountEditsSelectedPixelateElement() {
        let controller = makeLoadedController()
        let redaction = makeRedaction(amount: 22)
        controller.document?.elements.append(redaction)
        controller.selection = redaction.id
        controller.pixelateAmount = 30
        XCTAssertEqual(controller.document?.elements.last?.pixelateAmount, 30)
    }

    func testChangingAmountLeavesNonPixelateSelectionUntouched() {
        let controller = makeLoadedController()
        let arrow = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100)))
        controller.document?.elements.append(arrow)
        controller.selection = arrow.id
        let before = controller.document
        controller.pixelateAmount = 30
        XCTAssertEqual(controller.document, before)
    }

    func testSliderEditsPixelateAmountForPixelateTool() {
        let controller = makeLoadedController()
        XCTAssertFalse(controller.sliderEditsPixelateAmount)
        controller.tool = .pixelate
        XCTAssertTrue(controller.sliderEditsPixelateAmount)
    }

    func testSliderEditsPixelateAmountFollowsSelection() {
        let controller = makeLoadedController()
        let redaction = makeRedaction()
        let arrow = Annotation.arrow(SegmentElement(start: .zero, end: CGPoint(x: 100, y: 100)))
        controller.document?.elements.append(contentsOf: [redaction, arrow])
        controller.tool = .select
        controller.selection = redaction.id
        XCTAssertTrue(controller.sliderEditsPixelateAmount)
        controller.selection = arrow.id
        XCTAssertFalse(controller.sliderEditsPixelateAmount)
        controller.selection = nil
        XCTAssertFalse(controller.sliderEditsPixelateAmount)
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
