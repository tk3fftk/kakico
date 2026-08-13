import UniformTypeIdentifiers
import AnnotationRender

/// Output formats offered by the export save panel.
enum ExportFormat: String, CaseIterable {
    case png
    case jpeg
    case webp

    /// Hard per-side pixel cap imposed by the format's encoder, if any.
    var maxPixelDimension: Int? {
        switch self {
        case .webp: WebPEncoder.maxDimension
        case .png, .jpeg: nil
        }
    }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .webp: .webP
        }
    }

    var filenameExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .webp: "webp"
        }
    }

    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .webp: "WebP"
        }
    }
}
