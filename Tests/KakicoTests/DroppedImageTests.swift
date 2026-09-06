import XCTest
import UniformTypeIdentifiers
@testable import Kakico

/// Exercises `DroppedImage` through `NSItemProvider`, the same mechanism
/// SwiftUI's `dropDestination` uses to hand pasteboard items to a
/// `Transferable`, so the representations are matched the way a real drop
/// matches them.
final class DroppedImageTests: XCTestCase {

    /// Smallest valid PNG (1×1 transparent pixel).
    private let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private func load(from provider: NSItemProvider) async throws -> DroppedImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: DroppedImage.self) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// A browser or app drag exposes image bytes under an image UTI.
    func testImageBytesImportAsData() async throws {
        let provider = NSItemProvider(item: onePixelPNG as NSData,
                                      typeIdentifier: UTType.png.identifier)
        let dropped = try await load(from: provider)
        XCTAssertEqual(dropped, .data(onePixelPNG))
    }

    /// A Finder drag exposes only a file URL, never the file's bytes.
    func testFileURLImportsAsFile() async throws {
        let url = URL(fileURLWithPath: "/tmp/example.png")
        let provider = NSItemProvider(item: url as NSURL,
                                      typeIdentifier: UTType.fileURL.identifier)
        let dropped = try await load(from: provider)
        XCTAssertEqual(dropped, .file(url))
    }

    func testImageBytesDecodeToCGImage() {
        XCTAssertNotNil(DroppedImage.data(onePixelPNG).cgImage)
        XCTAssertNil(DroppedImage.data(Data([0, 1, 2])).cgImage)
    }

    func testOnlyFilesCarryASourceURL() {
        let url = URL(fileURLWithPath: "/tmp/example.png")
        XCTAssertEqual(DroppedImage.file(url).sourceURL, url)
        XCTAssertNil(DroppedImage.data(onePixelPNG).sourceURL)
    }
}
