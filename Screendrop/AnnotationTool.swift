//
//  AnnotationTool.swift
//  Screendrop
//

import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case freehand
    case numberedCircle
    case text
    case highlight
    case pixelate
    case blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select:
            String(localized: "Select")
        case .rectangle:
            String(localized: "Rectangle")
        case .filledRectangle:
            String(localized: "Solid rectangle")
        case .ellipse:
            String(localized: "Circle")
        case .line:
            String(localized: "Straight line")
        case .arrow:
            String(localized: "Arrow")
        case .freehand:
            String(localized: "Freehand")
        case .numberedCircle:
            String(localized: "Numbered circle")
        case .pixelate:
            String(localized: "Pixelate")
        case .blur:
            String(localized: "Blur")
        case .text:
            String(localized: "Text")
        case .highlight:
            String(localized: "Highlight")
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
        case .highlight:
            "square.dashed.inset.filled"
        }
    }

    var helpText: String {
        if self == .highlight {
            return String(localized: "Draw an area to keep visible; everything outside is dimmed")
        }
        return title
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

    var supportsColorStyle: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .numberedCircle, .text:
            true
        case .select, .pixelate, .blur, .highlight:
            false
        }
    }

    var supportsStrokeStyle: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand:
            true
        case .select, .filledRectangle, .numberedCircle, .pixelate, .blur, .text, .highlight:
            false
        }
    }

    var supportsRedactionDensityStyle: Bool {
        isRedactionTool
    }

    var supportsAspectLock: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .highlight:
            true
        case .select, .line, .arrow, .freehand, .numberedCircle, .pixelate, .blur, .text:
            false
        }
    }

    var createsAnnotation: Bool {
        self != .select
    }
}
