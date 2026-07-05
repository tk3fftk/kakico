import XCTest
import CoreGraphics
@testable import Kakico

final class ZoomMathTests: XCTestCase {

    private let acc: CGFloat = 0.0001

    // MARK: fittedScale

    func testFittedScaleWideCanvas() {
        // 200×100 into 100×100 → width limits: 0.5
        let s = ZoomMath.fittedScale(canvas: CGSize(width: 200, height: 100),
                                     viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(s, 0.5, accuracy: acc)
    }

    func testFittedScaleTallCanvas() {
        let s = ZoomMath.fittedScale(canvas: CGSize(width: 100, height: 400),
                                     viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(s, 0.25, accuracy: acc)
    }

    func testFittedScaleDegenerateCanvas() {
        XCTAssertEqual(ZoomMath.fittedScale(canvas: .zero, viewport: CGSize(width: 100, height: 100)), 1)
    }

    // MARK: clampedPan

    func testClampedPanCenteredWhenContentFits() {
        let pan = ZoomMath.clampedPan(CGVector(dx: 50, dy: -30),
                                      content: CGSize(width: 80, height: 60),
                                      viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(pan.dx, 0)
        XCTAssertEqual(pan.dy, 0)
    }

    func testClampedPanClampsOverflowAxisOnly() {
        // Width overflows by 100 → ±50 slack; height fits → 0.
        let pan = ZoomMath.clampedPan(CGVector(dx: 80, dy: 20),
                                      content: CGSize(width: 200, height: 50),
                                      viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(pan.dx, 50, accuracy: acc)
        XCTAssertEqual(pan.dy, 0)
    }

    func testClampedPanBothAxesOverflow() {
        let pan = ZoomMath.clampedPan(CGVector(dx: -999, dy: 10),
                                      content: CGSize(width: 300, height: 300),
                                      viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(pan.dx, -100, accuracy: acc)
        XCTAssertEqual(pan.dy, 10, accuracy: acc)  // within ±100 slack, untouched
    }

    // MARK: imageRect

    func testImageRectCenteredWhenFitting() {
        let r = ZoomMath.imageRect(canvas: CGSize(width: 40, height: 20),
                                   viewport: CGSize(width: 100, height: 100),
                                   scale: 1, pan: .zero)
        XCTAssertEqual(r, CGRect(x: 30, y: 40, width: 40, height: 20))
    }

    func testImageRectEdgesNeverInsideViewportWhenOverflowing() {
        // 100×100 canvas at 4× = 400×400 in a 100×100 viewport, panned hard.
        let r = ZoomMath.imageRect(canvas: CGSize(width: 100, height: 100),
                                   viewport: CGSize(width: 100, height: 100),
                                   scale: 4, pan: CGVector(dx: 9999, dy: -9999))
        XCTAssertLessThanOrEqual(r.minX, 0 + acc)
        XCTAssertGreaterThanOrEqual(r.maxX, 100 - acc)
        XCTAssertLessThanOrEqual(r.minY, 0 + acc)
        XCTAssertGreaterThanOrEqual(r.maxY, 100 - acc)
        // Clamped exactly to the edges at the panned corners.
        XCTAssertEqual(r.minX, 0, accuracy: acc)
        XCTAssertEqual(r.maxY, 100, accuracy: acc)
    }

    // MARK: panPreservingCenter

    func testPanPreservingCenterKeepsCenterModelPointFixed() {
        let canvas = CGSize(width: 100, height: 100)
        let viewport = CGSize(width: 100, height: 100)
        let oldScale: CGFloat = 2, newScale: CGFloat = 4
        let oldPan = CGVector(dx: 30, dy: -20)
        let oldRect = ZoomMath.imageRect(canvas: canvas, viewport: viewport, scale: oldScale, pan: oldPan)
        // Model point under the viewport center before the zoom.
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let modelX = (center.x - oldRect.minX) / oldScale
        let modelY = (center.y - oldRect.minY) / oldScale

        let newPan = ZoomMath.panPreservingCenter(oldPan: oldPan, oldScale: oldScale, newScale: newScale)
        let newRect = ZoomMath.imageRect(canvas: canvas, viewport: viewport, scale: newScale, pan: newPan)
        XCTAssertEqual(newRect.minX + modelX * newScale, center.x, accuracy: acc)
        XCTAssertEqual(newRect.minY + modelY * newScale, center.y, accuracy: acc)
    }

    // MARK: panPreservingPoint

    func testPanPreservingPointKeepsAnchorModelPointFixed() {
        let canvas = CGSize(width: 120, height: 80)
        let viewport = CGSize(width: 100, height: 100)
        let oldScale: CGFloat = 2, newScale: CGFloat = 3.5
        let oldPan = CGVector(dx: -15, dy: 25)
        let anchor = CGPoint(x: 70, y: 20)
        let oldRect = ZoomMath.imageRect(canvas: canvas, viewport: viewport, scale: oldScale, pan: oldPan)
        // Model point under the anchor before the zoom.
        let modelX = (anchor.x - oldRect.minX) / oldScale
        let modelY = (anchor.y - oldRect.minY) / oldScale

        let newPan = ZoomMath.panPreservingPoint(anchor, oldPan: oldPan,
                                                 oldScale: oldScale, newScale: newScale,
                                                 canvas: canvas, viewport: viewport)
        let newRect = ZoomMath.imageRect(canvas: canvas, viewport: viewport, scale: newScale, pan: newPan)
        XCTAssertEqual(newRect.minX + modelX * newScale, anchor.x, accuracy: acc)
        XCTAssertEqual(newRect.minY + modelY * newScale, anchor.y, accuracy: acc)
    }

    func testPanPreservingPointAtViewportCenterMatchesPanPreservingCenter() {
        let canvas = CGSize(width: 200, height: 150)
        let viewport = CGSize(width: 100, height: 100)
        let oldScale: CGFloat = 1.5, newScale: CGFloat = 0.75
        let oldPan = CGVector(dx: 12, dy: -8)
        let atCenter = ZoomMath.panPreservingPoint(CGPoint(x: 50, y: 50), oldPan: oldPan,
                                                   oldScale: oldScale, newScale: newScale,
                                                   canvas: canvas, viewport: viewport)
        let center = ZoomMath.panPreservingCenter(oldPan: oldPan, oldScale: oldScale, newScale: newScale)
        XCTAssertEqual(atCenter.dx, center.dx, accuracy: acc)
        XCTAssertEqual(atCenter.dy, center.dy, accuracy: acc)
    }

    func testPanPreservingPointIdentityWhenScaleUnchanged() {
        let pan = ZoomMath.panPreservingPoint(CGPoint(x: 10, y: 90), oldPan: CGVector(dx: 5, dy: -7),
                                              oldScale: 2, newScale: 2,
                                              canvas: CGSize(width: 100, height: 100),
                                              viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(pan.dx, 5, accuracy: acc)
        XCTAssertEqual(pan.dy, -7, accuracy: acc)
    }

    // MARK: clampedScale

    func testClampedScaleFloorsAtSmallestPreset() {
        // Fit scale is 1.0, so the floor is the 25% preset.
        let s = ZoomMath.clampedScale(0.05, canvas: CGSize(width: 100, height: 100),
                                      viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(s, 0.25, accuracy: acc)
    }

    func testClampedScaleFloorsAtFitForHugeImages() {
        // 1000×1000 into 100×100 → fit 0.1, below the smallest preset.
        let s = ZoomMath.clampedScale(0.01, canvas: CGSize(width: 1000, height: 1000),
                                      viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(s, 0.1, accuracy: acc)
    }

    func testClampedScaleCapsAtLargestPreset() {
        let s = ZoomMath.clampedScale(9, canvas: CGSize(width: 100, height: 100),
                                      viewport: CGSize(width: 100, height: 100))
        XCTAssertEqual(s, 4.0, accuracy: acc)
    }

    // MARK: zoom stepping

    func testZoomInFromFitFraction() {
        XCTAssertEqual(ZoomMath.zoomInScale(from: 0.63), 1.0)
    }

    func testZoomOutFromFitFraction() {
        XCTAssertEqual(ZoomMath.zoomOutScale(from: 0.63), 0.5)
    }

    func testZoomInFromExactPresetAdvances() {
        XCTAssertEqual(ZoomMath.zoomInScale(from: 1.0), 2.0)
        XCTAssertEqual(ZoomMath.zoomOutScale(from: 1.0), 0.5)
    }

    func testZoomClampsAtEnds() {
        XCTAssertEqual(ZoomMath.zoomInScale(from: 4.0), 4.0)
        XCTAssertEqual(ZoomMath.zoomInScale(from: 10.0), 4.0)
        XCTAssertEqual(ZoomMath.zoomOutScale(from: 0.25), 0.25)
        XCTAssertEqual(ZoomMath.zoomOutScale(from: 0.1), 0.25)
    }
}
