import Foundation
import AnnotationModel

enum Tool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case pixelate
    case crop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .text: return "Text"
        case .pixelate: return "Pixelate"
        case .crop: return "Crop"
        }
    }

    /// Miro-style single-letter shortcut for the tool.
    var shortcutKey: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .text: return "t"
        case .pixelate: return "p"
        case .crop: return "c"
        }
    }

    /// SF Symbol name for the palette button.
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .pixelate: return "squareshape.split.3x3"
        case .crop: return "crop"
        }
    }

    /// Which stroke-width memory this tool draws with; nil for tools that
    /// don't create stroked elements.
    var strokeWidthGroup: StrokeWidthGroup? {
        switch self {
        case .arrow, .line: return .segment
        case .rectangle, .ellipse: return .shape
        case .text: return .text
        case .select, .pixelate, .crop: return nil
        }
    }
}

/// Tools remember their stroke width per group (Miro-style): arrows/lines
/// share one width, shape outlines another, text its own. The kind→group
/// taxonomy is defined here, in `Tool.strokeWidthGroup` and
/// `Annotation.strokeWidthGroup` below — keep the two switches in step.
enum StrokeWidthGroup {
    case segment
    case shape
    case text
}

extension Annotation {
    /// The stroke-width memory this element belongs to; mirrors
    /// `Tool.strokeWidthGroup` on the element side.
    var strokeWidthGroup: StrokeWidthGroup? {
        switch self {
        case .arrow, .line: return .segment
        case .rectangle, .ellipse: return .shape
        case .text: return .text
        case .pixelate: return nil
        }
    }
}
