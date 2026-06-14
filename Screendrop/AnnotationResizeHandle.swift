//
//  AnnotationResizeHandle.swift
//  Screendrop
//

import CoreGraphics

enum AnnotationResizeHandle: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case start
    case control
    case end

    static var boxCases: [AnnotationResizeHandle] {
        [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    static var endpointCases: [AnnotationResizeHandle] {
        [.start, .end]
    }

    static var arrowCases: [AnnotationResizeHandle] {
        [.control, .start, .end]
    }

    static func handles(for tool: AnnotationTool) -> [AnnotationResizeHandle] {
        tool == .arrow ? arrowCases : endpointCases
    }

    func corner(in rect: CGRect) -> CGPoint? {
        switch self {
        case .topLeft:
            CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:
            CGPoint(x: rect.maxX, y: rect.maxY)
        case .start, .control, .end:
            nil
        }
    }

    func oppositeCorner(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight:
            CGPoint(x: rect.minX, y: rect.minY)
        case .start, .control, .end:
            .zero
        }
    }

    func constrainedPoint(_ point: CGPoint, from anchor: CGPoint, minimumSize: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: min(point.x, anchor.x - minimumSize), y: min(point.y, anchor.y - minimumSize))
        case .topRight:
            CGPoint(x: max(point.x, anchor.x + minimumSize), y: min(point.y, anchor.y - minimumSize))
        case .bottomLeft:
            CGPoint(x: min(point.x, anchor.x - minimumSize), y: max(point.y, anchor.y + minimumSize))
        case .bottomRight:
            CGPoint(x: max(point.x, anchor.x + minimumSize), y: max(point.y, anchor.y + minimumSize))
        case .start, .control, .end:
            point
        }
    }

    func point(in item: AnnotationItem) -> CGPoint? {
        switch self {
        case .start:
            item.points.first
        case .control:
            // The on-screen handle sits on the curve (its apex), not on the
            // raw Bezier control point, so hit-testing must use the same point.
            item.arrowCurveHandle
        case .end:
            item.points.last
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            nil
        }
    }
}
