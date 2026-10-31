import AppKit
import ImageIO
import AnnotationModel
import AnnotationRender
import Synchronization
import XCTest
import UniformTypeIdentifiers
@testable import Kakico

final class DragExportProviderTests: XCTestCase {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private static func onBackground(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Use Objective-C dispatch like file coordination does, bypassing the SDK's
    /// MainActor annotations so an isolated witness would trap in this test.
    private static func callbacks(for provider: NSFilePromiseProvider) throws -> (String, OperationQueue) {
        let delegate = try XCTUnwrap(provider.delegate)
        let object = try XCTUnwrap(delegate as? NSObject)
        let name = try XCTUnwrap(object.perform(
            #selector(NSFilePromiseProviderDelegate.filePromiseProvider(_:fileNameForType:)),
            with: provider, with: UTType.png.identifier)?.takeUnretainedValue() as? String)
        let queue = try XCTUnwrap(object.perform(
            #selector(NSFilePromiseProviderDelegate.operationQueue(for:)),
            with: provider)?.takeUnretainedValue() as? OperationQueue)
        XCTAssertFalse(queue === OperationQueue.main)
        return (name, queue)
    }

    private static func write(_ provider: NSFilePromiseProvider, to url: URL, succeeds: Bool) throws {
        let delegate = try XCTUnwrap(provider.delegate)
        let calls = Mutex(0)
        delegate.filePromiseProvider(provider, writePromiseTo: url) { error in
            calls.withLock { $0 += 1 }
            XCTAssertEqual(error == nil, succeeds)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testBackgroundCallbacksWritePNGAndRetainDelegate() async throws {
        try await Self.onBackground {
            XCTAssertFalse(Thread.isMainThread)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            // No separate reference retains the delegate.
            let provider = DragExportProvider(data: Self.png, fileName: "image.png")
            XCTAssertEqual(provider.fileType, UTType.png.identifier)
            let (name, _) = try Self.callbacks(for: provider)
            XCTAssertEqual(name, "image.png")
            try Self.write(provider, to: url, succeeds: true)
            XCTAssertEqual(try Data(contentsOf: url), Self.png)
        }
    }

    func testWriteFailureCompletesOnceWithError() async throws {
        try await Self.onBackground {
            let missingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let url = missingDirectory.appendingPathComponent("image.png")
            let provider = DragExportProvider(data: Self.png, fileName: "image.png")
            try Self.write(provider, to: url, succeeds: false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testLaterDragDoesNotReplaceEarlierPromise() async throws {
        try await Self.onBackground {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = DragExportProvider(data: Self.png, fileName: "first.png")
            let secondData = Self.png + Data([0])
            let second = DragExportProvider(data: secondData, fileName: "second.png")
            // Fulfill in reverse order, after both snapshots have been created.
            for (provider, expectedName, expectedData) in [
                (second, "second.png", secondData), (first, "first.png", Self.png)
            ] {
                let (name, _) = try Self.callbacks(for: provider)
                XCTAssertEqual(name, expectedName)
                let url = directory.appendingPathComponent(name)
                try Self.write(provider, to: url, succeeds: true)
                XCTAssertEqual(try Data(contentsOf: url), expectedData)
            }
        }
    }

    private func temporaryFiles() -> DragExportTemporaryFiles {
        DragExportTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func fileURL(_ provider: DragExportProvider) throws -> URL {
        let value = try XCTUnwrap(provider.pasteboardPropertyList(forType: .fileURL) as? String)
        return try XCTUnwrap(URL(string: value))
    }

    private func pixels(_ data: Data, width: Int, height: Int) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(bytes: try XCTUnwrap(context.data), count: width * height * 4)
    }

    @MainActor
    func testSinglePasteboardItemContainsFrozenCropAndAnnotationsInAllFormats() throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let controller = CanvasController()
        controller.loadImage(try XCTUnwrap(context.makeImage()))
        controller.document?.crop = CGRect(x: 10, y: 10, width: 20, height: 10)
        let unannotated = try XCTUnwrap(ExportService.pngData(controller))
        controller.document?.elements.append(.rectangle(ShapeElement(
            rect: CGRect(x: 12, y: 12, width: 6, height: 6), color: .black, width: 1, fill: .black)))
        let png = try XCTUnwrap(ExportService.pngData(controller))
        let expected = try pixels(png, width: 20, height: 10)
        XCTAssertNotEqual(expected, try pixels(unannotated, width: 20, height: 10))
        let provider = DragExportProvider(data: png, fileName: "annotated.png", temporaryFiles: files)
        // Editing after the drag starts cannot change any representation.
        controller.document?.crop = nil
        controller.document?.elements.removeAll()

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let promise = try NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: XCTUnwrap(provider.delegate))
        let promiseTypes = promise.writableTypes(for: pasteboard)
        XCTAssertFalse(promiseTypes.isEmpty)
        XCTAssertTrue(Set(promiseTypes).isSubset(of: Set(provider.writableTypes(for: pasteboard))))
        XCTAssertTrue(pasteboard.writeObjects([provider]))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        let url = try XCTUnwrap(URL(string: XCTUnwrap(item.string(forType: .fileURL))))
        XCTAssertEqual(url.lastPathComponent, "annotated.png")
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertEqual(item.data(forType: .png), png)
        XCTAssertEqual(try pixels(XCTUnwrap(item.data(forType: .tiff)), width: 20, height: 10), expected)
        let promisedURL = files.root.appendingPathComponent("promised.png")
        try Self.write(provider, to: promisedURL, succeeds: true)
        XCTAssertEqual(try Data(contentsOf: promisedURL), png)
    }

    func testTemporaryFilesStayDistinctAndReadableAfterProvidersAreReleased() throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let secondData = Self.png + Data([0])
        let urls = try autoreleasepool {
            let first = DragExportProvider(data: Self.png, fileName: "same.png", temporaryFiles: files)
            let second = DragExportProvider(data: secondData, fileName: "same.png", temporaryFiles: files)
            return try [fileURL(first), fileURL(second)]
        }
        XCTAssertNotEqual(urls[0].deletingLastPathComponent(), urls[1].deletingLastPathComponent())
        files.removeExpiredSessions(now: Date().addingTimeInterval(48 * 60 * 60))
        XCTAssertEqual(try Data(contentsOf: urls[0]), Self.png)
        XCTAssertEqual(try Data(contentsOf: urls[1]), secondData)
    }

    func testTemporaryFileFailureStillOffersImageDataAndPromise() throws {
        let files = temporaryFiles()
        // A regular file cannot contain the session/drag subdirectories.
        try Self.png.write(to: files.root)
        defer { try? FileManager.default.removeItem(at: files.root) }
        let provider = DragExportProvider(data: Self.png, fileName: "image.png", temporaryFiles: files)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertFalse(provider.writableTypes(for: pasteboard).contains(.fileURL))
        XCTAssertNil(provider.pasteboardPropertyList(forType: .fileURL))
        XCTAssertEqual(provider.pasteboardPropertyList(forType: .png) as? Data, Self.png)
        let tiff = try XCTUnwrap(provider.pasteboardPropertyList(forType: .tiff) as? Data)
        XCTAssertEqual(try pixels(tiff, width: 1, height: 1), try pixels(Self.png, width: 1, height: 1))
        let destination = files.root.appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Self.write(provider, to: destination, succeeds: true)
        XCTAssertEqual(try Data(contentsOf: destination), Self.png)
    }

    func testNextSessionDragCleansOnlyExpiredSessionDirectories() throws {
        let files = temporaryFiles()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let oldSession = DragExportTemporaryFiles(root: files.root)
        let oldURL = try XCTUnwrap(oldSession.write(Self.png, fileName: "old.png"))
        let recentSession = DragExportTemporaryFiles(root: files.root)
        let recentURL = try XCTUnwrap(recentSession.write(Self.png, fileName: "recent.png"))
        let currentURL = try XCTUnwrap(files.write(Self.png, fileName: "current.png"))
        let unrelated = files.root.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let now = Date()
        for directory in [oldURL.deletingLastPathComponent().deletingLastPathComponent(),
                          currentURL.deletingLastPathComponent().deletingLastPathComponent(), unrelated] {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
                                                   ofItemAtPath: directory.path)
        }
        _ = try XCTUnwrap(files.write(Self.png, fileName: "next.png", now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

}
