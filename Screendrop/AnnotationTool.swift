//
//  AnnotationTool.swift
//  Screendrop
//

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case freehand
    case numberedCircle
    case pixelate
    case blur
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select:
            "Select"
        case .rectangle:
            "Rectangle"
        case .filledRectangle:
            "Solid rectangle"
        case .ellipse:
            "Circle"
        case .line:
            "Straight line"
        case .arrow:
            "Arrow"
        case .freehand:
            "Freehand"
        case .numberedCircle:
            "Numbered circle"
        case .pixelate:
            "Pixelate"
        case .blur:
            "Blur"
        case .text:
            "Text"
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            "hand.point.up.left"
        case .rectangle:
            "rectangle"
        case .filledRectangle:
            "square.fill"
        case .ellipse:
            "circle"
        case .line:
            "line.diagonal"
        case .arrow:
            "arrow.up.right"
        case .freehand:
            "scribble"
        case .numberedCircle:
            "1.circle.fill"
        case .pixelate:
            "app.background.dotted"
        case .blur:
            "drop.fill"
        case .text:
            "textformat"
        }
    }

    var isFilledShape: Bool {
        self == .filledRectangle
    }

    var usesEndpoints: Bool {
        self == .line || self == .arrow
    }

    var isRedactionTool: Bool {
        self == .pixelate || self == .blur
    }

    var supportsAspectLock: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse:
            true
        case .select, .line, .arrow, .freehand, .numberedCircle, .pixelate, .blur, .text:
            false
        }
    }

    var createsAnnotation: Bool {
        self != .select
    }
}
