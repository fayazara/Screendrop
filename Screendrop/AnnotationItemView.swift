//
//  AnnotationItemView.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationItemView: View {
    let item: AnnotationItem
    let image: NSImage
    let originalImageSize: CGSize
    let imageFrame: CGRect
    let isSelected: Bool
    let showsResizeHandles: Bool
    let isEditingText: Bool
    let allowsRedactionPreviewCaching: Bool
    let text: Binding<String>
    let onCommitText: () -> Void
    let onTextSizeChange: (CGSize) -> Void

    private var selectionOutset: CGFloat {
        item.tool == .text ? 0 : 5
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if item.tool.isRedactionTool {
                RedactionPreview(
                    image: image,
                    item: item,
                    originalImageSize: originalImageSize,
                    imageFrame: imageFrame,
                    viewBounds: viewBounds,
                    allowsCaching: allowsRedactionPreviewCaching
                )
            } else if item.tool.isFilledShape {
                itemPath
                    .fill(fillStyle)
            } else if item.tool == .numberedCircle {
                NumberedCircleAnnotationView(item: item, viewBounds: viewBounds)
            } else if item.tool == .text {
                AnnotationTextItemView(
                    item: item,
                    text: text,
                    viewBounds: viewBounds,
                    imageFrameHeight: imageFrame.height,
                    isEditing: isEditingText,
                    onCommit: onCommitText,
                    onSizeChange: onTextSizeChange
                )
            } else {
                itemPath
                    .stroke(item.swatch.color, style: StrokeStyle(lineWidth: item.strokeWidth, lineCap: .round, lineJoin: .round))
            }

            if let arrowHeadPath {
                arrowHeadPath
                    .stroke(item.swatch.color, style: StrokeStyle(lineWidth: item.strokeWidth, lineCap: .round, lineJoin: .round))
            }

            if isSelected {
                selectionOverlay
            }
        }
        .allowsHitTesting(item.tool == .text && isEditingText)
    }

    private var itemPath: Path {
        let rect = viewRect(item.bounds)

        switch item.tool {
        case .select:
            return Path()

        case .rectangle:
            return Path(rect)

        case .filledRectangle:
            return Path(
                roundedRect: rect,
                cornerRadius: AnnotationFilledRectangleMetrics.cornerRadius(for: rect)
            )

        case .pixelate, .blur:
            return Path(rect)

        case .numberedCircle:
            return Path(ellipseIn: rect)

        case .text:
            return Path()

        case .ellipse:
            return Path(ellipseIn: rect)

        case .line:
            var path = Path()
            if let start = endpointViewPoints.first,
               let end = endpointViewPoints.last {
                path.move(to: start)
                path.addLine(to: end)
            }
            return path

        case .freehand:
            return freehandPath(points: item.points.map(viewPoint))

        case .arrow:
            var path = Path()
            guard let start = endpointViewPoints.first,
                  let geometry = arrowGeometry else {
                return path
            }

            path.move(to: start)
            path.addQuadCurve(to: geometry.tip, control: geometry.shaftControl)
            return path
        }
    }

    private var fillStyle: Color {
        item.tool.isFilledShape ? item.swatch.color : .clear
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if !showsResizeHandles {
            SelectionOutlineFrame()
                .frame(
                    width: max(viewBounds.width + selectionOutset * 2, 18),
                    height: max(viewBounds.height + selectionOutset * 2, 18)
                )
                .position(x: viewBounds.midX, y: viewBounds.midY)
        } else if item.tool.usesEndpoints {
            ForEach(endpointViewPoints.indices, id: \.self) { index in
                SelectionHandle()
                    .position(endpointViewPoints[index])
            }

            if let controlViewPoint {
                CurveControlHandle()
                    .position(controlViewPoint)
            }
        } else if item.tool == .text {
            // Text items: simple border, no corner handles (Apple Preview style).
            TextSelectionFrame()
                .frame(
                    width: max(viewBounds.width, 18),
                    height: max(viewBounds.height, 18)
                )
                .position(x: viewBounds.midX, y: viewBounds.midY)
        } else {
            SelectionFrame()
                .frame(
                    width: max(viewBounds.width + selectionOutset * 2, 18),
                    height: max(viewBounds.height + selectionOutset * 2, 18)
                )
                .position(x: viewBounds.midX, y: viewBounds.midY)
        }
    }

    private var arrowHeadPath: Path? {
        guard let geometry = arrowGeometry else {
            return nil
        }

        var path = Path()
        path.move(to: geometry.firstWing)
        path.addLine(to: geometry.tip)
        path.addLine(to: geometry.secondWing)
        return path
    }

    private var arrowGeometry: AnnotationArrowGeometry? {
        guard item.tool == .arrow,
              let start = endpointViewPoints.first,
              let control = controlViewPoint,
              let end = endpointViewPoints.last else {
            return nil
        }

        return AnnotationArrowGeometry(start: start, control: control, end: end, lineWidth: item.strokeWidth)
    }

    private var endpointViewPoints: [CGPoint] {
        guard item.points.count >= 2,
              let first = item.points.first,
              let last = item.points.last else {
            return []
        }

        return [viewPoint(first), viewPoint(last)]
    }

    private var controlViewPoint: CGPoint? {
        guard let curveHandle = item.arrowCurveHandle else { return nil }
        return viewPoint(curveHandle)
    }

    private var viewBounds: CGRect {
        viewRect(item.bounds)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + rect.minX * imageFrame.width,
            y: imageFrame.minY + rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        )
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + point.x * imageFrame.width,
            y: imageFrame.minY + point.y * imageFrame.height
        )
    }

    private func freehandPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }

        path.move(to: first)
        guard points.count > 1 else { return path }

        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            path.addQuadCurve(to: midpoint(previous, current), control: previous)
        }

        path.addLine(to: points[points.count - 1])
        return path
    }

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}
