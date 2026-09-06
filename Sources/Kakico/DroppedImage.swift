import CoreGraphics
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Payload accepted by the canvas pane's drop destination: a file on disk
/// (Finder drag) or raw image bytes (drag from a browser or another app).
///
/// Representations are listed in priority order. Image bytes win when the
/// drag carries them, so a browser drag that also exposes the page URL is not
/// mistaken for a file. Finder drags carry no image bytes and fall through
/// to the URL representation.
enum DroppedImage: Transferable, Equatable {
    case file(URL)
    case data(Data)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { .data($0) }
        ProxyRepresentation { (url: URL) in .file(url) }
    }

    /// Decodes the payload; nil when the file or bytes are not a readable image.
    var cgImage: CGImage? {
        switch self {
        case .file(let url): return ImageLoader.cgImage(from: url)
        case .data(let data): return ImageLoader.cgImage(from: data)
        }
    }

    /// Source URL to remember for export naming; nil for in-memory bytes.
    var sourceURL: URL? {
        if case .file(let url) = self { return url }
        return nil
    }
}
