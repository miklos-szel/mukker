import Foundation

/// The selectable editor tools. `select` and `crop` are not annotation kinds;
/// every other case maps to an `AnnotationKind` it creates.
enum Tool: String, CaseIterable, Identifiable {
    case select
    case hand
    case arrow
    case line
    case rectangle
    case roundedRectangle
    case ellipse
    case highlight
    case blur
    case text
    case freehand
    case counter
    case crop

    var id: String { rawValue }

    /// The tool palette split into related clusters, so the toolbar can render
    /// them as separated groups instead of one undifferentiated run of 13 tiles.
    /// Must stay a partition of `allCases` — `EditorModelTests` asserts it.
    static let groups: [[Tool]] = [
        [.select, .hand],
        [.arrow, .line, .rectangle, .roundedRectangle, .ellipse],
        [.freehand, .text, .counter],
        [.highlight, .blur],
        [.crop],
    ]

    var systemImage: String {
        switch self {
        case .select:           return "cursorarrow"
        case .hand:             return "hand.raised"
        case .arrow:            return "arrow.up.right"
        case .line:             return "line.diagonal"
        case .rectangle:        return "rectangle"
        case .roundedRectangle: return "rectangle.roundedtop"
        case .ellipse:          return "circle"
        case .highlight:        return "highlighter"
        case .blur:             return "square.grid.3x3.fill"
        case .text:             return "textformat"
        case .freehand:         return "pencil.tip"
        case .counter:          return "number.circle"
        case .crop:             return "crop"
        }
    }

    var help: String {
        switch self {
        case .select:           return "Select / move"
        case .hand:             return "Pan view (visual only)"
        case .arrow:            return "Arrow"
        case .line:             return "Line"
        case .rectangle:        return "Rectangle"
        case .roundedRectangle: return "Rounded rectangle"
        case .ellipse:          return "Ellipse"
        case .highlight:        return "Highlight"
        case .blur:             return "Blur / pixelate"
        case .text:             return "Text"
        case .freehand:         return "Freehand"
        case .counter:          return "Step counter"
        case .crop:             return "Crop"
        }
    }

    var annotationKind: AnnotationKind? {
        switch self {
        case .select, .crop, .hand: return nil
        case .arrow:            return .arrow
        case .line:             return .line
        case .rectangle:        return .rectangle
        case .roundedRectangle: return .roundedRectangle
        case .ellipse:          return .ellipse
        case .highlight:        return .highlight
        case .blur:             return .blur
        case .text:             return .text
        case .freehand:         return .freehand
        case .counter:          return .counter
        }
    }

    /// Single-key shortcut that selects this tool in the editor (no modifiers).
    var shortcut: Character {
        switch self {
        case .select:           return "v"
        case .hand:             return "m"
        case .arrow:            return "a"
        case .line:             return "l"
        case .rectangle:        return "o"
        case .roundedRectangle: return "r"
        case .ellipse:          return "e"
        case .highlight:        return "h"
        case .blur:             return "b"
        case .text:             return "t"
        case .freehand:         return "p"
        case .counter:          return "n"
        case .crop:             return "c"
        }
    }

    init?(shortcut: Character) {
        guard let match = Tool.allCases.first(where: { $0.shortcut == shortcut }) else { return nil }
        self = match
    }
}
