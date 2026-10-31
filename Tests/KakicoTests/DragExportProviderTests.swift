import AppKit
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
}
