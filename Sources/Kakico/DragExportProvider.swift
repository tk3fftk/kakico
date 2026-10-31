import AppKit
import UniformTypeIdentifiers

/// Keeps the delegate alive for as long as AppKit retains this promise.
final class DragExportProvider: NSFilePromiseProvider {
    private let exportDelegate: DragExportDelegate

    init(data: Data, fileName: String) {
        exportDelegate = DragExportDelegate(data: data, fileName: fileName)
        super.init()
        fileType = UTType.png.identifier
        delegate = exportDelegate
    }
}

/// An immutable snapshot of one drag; callbacks never access the UI.
private final class DragExportDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let data: Data
    private let fileName: String
    private let ioQueue = OperationQueue()

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
        super.init()
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                        fileNameForType fileType: String) -> String {
        fileName
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                        writePromiseTo url: URL,
                                        completionHandler: @escaping (Error?) -> Void) {
        do {
            try data.write(to: url)
        } catch {
            completionHandler(error)
            return
        }
        completionHandler(nil)
    }

    // File coordination can request this queue off the main actor despite the
    // SDK's MainActor annotation. Keep the Objective-C entry point nonisolated.
    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        ioQueue
    }
}
