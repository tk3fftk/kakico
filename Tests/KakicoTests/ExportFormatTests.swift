import XCTest
import UniformTypeIdentifiers
@testable import Kakico

@MainActor
final class ExportFormatTests: XCTestCase {

    private let key = "exportFormat"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testDefaultsToPNG() {
        XCTAssertEqual(ExportService.lastExportFormat, .png)
    }

    func testPersistsSelection() {
        ExportService.lastExportFormat = .webp
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "webp")
        XCTAssertEqual(ExportService.lastExportFormat, .webp)
    }

    func testGarbageStoredValueFallsBackToPNG() {
        UserDefaults.standard.set("bmp", forKey: key)
        XCTAssertEqual(ExportService.lastExportFormat, .png)
    }

    func testUTTypeAndFilenameExtension() {
        XCTAssertEqual(ExportFormat.png.utType, .png)
        XCTAssertEqual(ExportFormat.jpeg.utType, .jpeg)
        XCTAssertEqual(ExportFormat.webp.utType, .webP)
        XCTAssertEqual(ExportFormat.png.filenameExtension, "png")
        XCTAssertEqual(ExportFormat.jpeg.filenameExtension, "jpg")
        XCTAssertEqual(ExportFormat.webp.filenameExtension, "webp")
    }
}
