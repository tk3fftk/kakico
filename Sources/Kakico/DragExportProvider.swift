import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps the delegate alive for as long as AppKit retains this promise.
final class DragExportProvider: NSFilePromiseProvider {
    private let exportDelegate: DragExportDelegate
    private let png: Data
    private let tiff: Data?
    private let fileURL: URL?

    init(data: Data, fileName: String, temporaryFiles: DragExportTemporaryFiles = .current) {
        png = data
        // Decode the frozen PNG, never the live document, for alternate formats.
        tiff = Self.tiffData(from: data)
        fileURL = temporaryFiles.write(data, fileName: fileName)
        exportDelegate = DragExportDelegate(data: data, fileName: fileName)
        super.init()
        fileType = UTType.png.identifier
        delegate = exportDelegate
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if fileURL != nil { types.append(.fileURL) }
        types.append(.png)
        if tiff != nil { types.append(.tiff) }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL: return fileURL?.absoluteString
        case .png: return png
        case .tiff: return tiff
        default: return super.pasteboardPropertyList(forType: type)
        }
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        switch type {
        case .fileURL, .png, .tiff: return []
        default: return super.writingOptions(forType: type, pasteboard: pasteboard)
        }
    }

    private static func tiffData(from png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString,
                                                                 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// Files outlive the provider and the drag so receivers can read them lazily.
/// Only stale directories belonging to earlier app sessions are removed.
struct DragExportTemporaryFiles: Sendable {
    static let current = DragExportTemporaryFiles(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("Kakico-DragExports", isDirectory: true))

    let root: URL
    let sessionID: UUID

    init(root: URL, sessionID: UUID = UUID()) {
        self.root = root
        self.sessionID = sessionID
    }

    func write(_ data: Data, fileName: String, now: Date = Date()) -> URL? {
        removeExpiredSessions(now: now)
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent((fileName as NSString).lastPathComponent)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    func removeExpiredSessions(now: Date) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys)) else { return }
        for session in sessions {
            guard UUID(uuidString: session.lastPathComponent) != nil,
                  session.lastPathComponent != sessionID.uuidString,
                  let values = try? session.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= 24 * 60 * 60 else { continue }
            try? FileManager.default.removeItem(at: session)
        }
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
