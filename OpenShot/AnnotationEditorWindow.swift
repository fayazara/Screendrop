//
//  AnnotationEditorWindow.swift
//  OpenShot
//
//  Created by Codex on 27/04/26.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationEditorWindow: View {
    @Binding var url: URL?

    @State private var model = AnnotationEditorModel()
    @Environment(\.dismiss) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            ZStack {
                Rectangle()
                    .fill(.regularMaterial)

                if let previewImage = model.previewImage, model.imageSize != .zero {
                    AnnotationCanvas(model: model, image: previewImage)
                        .padding(.horizontal, 34)
                        .padding(.vertical, 28)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .frame(minWidth: 920, minHeight: 580)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .task(id: url) {
            model.load(url: url, dismiss: dismissWindow)
        }
        .onDeleteCommand {
            model.deleteSelectedAnnotation()
        }
        .background(AnnotationKeyCommandHandler(
            onDelete: model.deleteSelectedAnnotation,
            onUndo: model.undo,
            onRedo: model.redo
        ))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            AnnotationToolPicker(selectedTool: model.selectedTool) { tool in
                model.selectedTool = tool
            }

            AnnotationColorMenu(selectedSwatch: model.selectedSwatch) { swatch in
                model.setSwatch(swatch)
            }

            AnnotationStrokeMenu(strokeWidth: model.strokeWidth) { strokeWidth in
                model.setStrokeWidth(strokeWidth)
            }

            if model.selectedTool.isRedactionTool {
                AnnotationRedactionDensitySlider(value: model.redactionDensity) { density in
                    model.setRedactionDensity(density)
                }
            }

            Spacer()

            AnnotationToolbarPillButton(title: "Save as...", help: "Save as") {
                saveAs()
            }

            AnnotationToolbarPillButton(title: "Done", help: "Done", isProminent: true) {
                finishEditing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background {
            AnnotationToolbarStyle.background
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AnnotationToolbarStyle.stroke)
                        .frame(height: 1)
                }
        }
    }

    private func saveAs() {
        guard let sourceURL = model.sourceURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Save Annotated Screenshot"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                try AnnotationRenderer.render(
                    sourceURL: sourceURL,
                    items: model.items,
                    destinationURL: destinationURL,
                    contentType: ScreenshotFileActions.exportContentType
                )
            } catch {
                model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
            }
        }
    }

    private func finishEditing() {
        guard let sourceURL = model.sourceURL else {
            dismissWindow()
            return
        }

        guard !model.items.isEmpty else {
            dismissWindow()
            return
        }

        do {
            let annotatedURL = try AnnotationRenderer.renderToTemporaryFile(
                sourceURL: sourceURL,
                items: model.items
            )
            ScreenshotPreviewStack.shared.replace(originalURL: sourceURL, with: annotatedURL)
            dismissWindow()
        } catch {
            model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
        }
    }
}

@MainActor
@Observable
private final class AnnotationEditorModel {
    var sourceURL: URL?
    var previewImage: NSImage?
    var imageSize: CGSize = .zero
    var items: [AnnotationItem] = []
    var draftItem: AnnotationItem?
    var selectedItemID: AnnotationItem.ID?
    var selectedTool: AnnotationTool = .rectangle
    var selectedSwatch: AnnotationSwatch = .red
    var strokeWidth: CGFloat = 4
    var redactionDensity: CGFloat = 0.55
    var errorMessage: String?
    private(set) var statePath = AnnotationToolState.idle.path(for: .rectangle)

    private var interaction: AnnotationInteraction?
    private var history = AnnotationHistory()
    private let minimumItemSize: CGFloat = 0.006

    func load(url: URL?, dismiss: DismissAction) {
        guard let url else {
            dismiss()
            return
        }

        sourceURL = url
        imageSize = ScreenshotImageLoader.imageSize(at: url) ?? .zero
        previewImage = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 2400)
        items = []
        draftItem = nil
        selectedItemID = nil
        interaction = nil
        history.reset(to: items)
        statePath = AnnotationToolState.idle.path(for: selectedTool)
        errorMessage = nil

        if previewImage == nil || imageSize == .zero {
            errorMessage = "Unable to load screenshot."
        }
    }

    func beginInteraction(at location: CGPoint, in imageFrame: CGRect) {
        guard let point = normalizedPoint(location, in: imageFrame, clamped: false) else {
            selectedItemID = nil
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return
        }

        if let selectedItem,
           let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: selectedItem) {
            applyStyleFromItem(selectedItem)
            draftItem = nil
            history.push(items)
            interaction = .resizing(id: selectedItem.id, handle: resizeHandle, originalItem: selectedItem)
            statePath = AnnotationToolState.resizing.path(for: selectedTool)
            return
        }

        if let item = hitTest(point) {
            selectedItemID = item.id
            applyStyleFromItem(item)
            draftItem = nil
            history.push(items)

            if let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: item) {
                interaction = .resizing(id: item.id, handle: resizeHandle, originalItem: item)
                statePath = AnnotationToolState.resizing.path(for: selectedTool)
            } else {
                interaction = .moving(id: item.id, startPoint: point, originalItem: item)
                statePath = AnnotationToolState.translating.path(for: selectedTool)
            }
        } else {
            selectedItemID = nil
            draftItem = AnnotationItem(
                tool: selectedTool,
                rect: CGRect(origin: point, size: .zero),
                points: initialPoints(for: selectedTool, at: point),
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                redactionDensity: redactionDensity
            )
            interaction = .drawing(startPoint: point)
            statePath = AnnotationToolState.drawing.path(for: selectedTool)
        }
    }

    func updateInteraction(to location: CGPoint, in imageFrame: CGRect) {
        guard let interaction,
              let point = normalizedPoint(location, in: imageFrame, clamped: true) else {
            return
        }

        switch interaction {
        case .drawing(let startPoint):
            updateDraftItem(from: startPoint, to: point)

        case .moving(let id, let startPoint, let originalItem):
            let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            updateItem(id: id, item: originalItem.offsetBy(clampedDelta(delta, for: originalItem.bounds)))

        case .resizing(let id, let handle, let originalItem):
            updateItem(id: id, item: resizedItem(originalItem, handle: handle, to: point))
        }
    }

    func endInteraction(at location: CGPoint, in imageFrame: CGRect) {
        defer { interaction = nil }

        guard let interaction,
              let point = normalizedPoint(location, in: imageFrame, clamped: true) else {
            draftItem = nil
            return
        }

        switch interaction {
        case .drawing(let startPoint):
            updateDraftItem(from: startPoint, to: point)

            guard let item = draftItem,
                  item.isRenderable(minimumSize: minimumItemSize) else {
                draftItem = nil
                statePath = AnnotationToolState.idle.path(for: selectedTool)
                return
            }

            history.push(items)
            items.append(item)
            selectedItemID = item.id
            draftItem = nil

        case .moving, .resizing:
            break
        }

        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func setSwatch(_ swatch: AnnotationSwatch) {
        selectedSwatch = swatch

        if let selectedItemID {
            history.push(items)
            updateItem(id: selectedItemID) { item in
                item.swatch = swatch
            }
        }

        if var draftItem {
            draftItem.swatch = swatch
            self.draftItem = draftItem
        }
    }

    func setStrokeWidth(_ strokeWidth: CGFloat) {
        self.strokeWidth = strokeWidth

        if let selectedItemID {
            history.push(items)
            updateItem(id: selectedItemID) { item in
                item.strokeWidth = strokeWidth
            }
        }

        if var draftItem {
            draftItem.strokeWidth = strokeWidth
            self.draftItem = draftItem
        }
    }

    func setRedactionDensity(_ redactionDensity: CGFloat) {
        self.redactionDensity = redactionDensity

        if let selectedItemID {
            history.push(items)
            updateItem(id: selectedItemID) { item in
                item.redactionDensity = redactionDensity
            }
        }

        if var draftItem {
            draftItem.redactionDensity = redactionDensity
            self.draftItem = draftItem
        }
    }

    func deleteSelectedAnnotation() {
        guard let selectedItemID else { return }

        history.push(items)
        items.removeAll { $0.id == selectedItemID }
        self.selectedItemID = nil
        interaction = nil
        draftItem = nil
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func undo() {
        guard let restoredItems = history.undo(current: items) else { return }

        items = restoredItems
        selectedItemID = nil
        draftItem = nil
        interaction = nil
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func redo() {
        guard let restoredItems = history.redo(current: items) else { return }

        items = restoredItems
        selectedItemID = nil
        draftItem = nil
        interaction = nil
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    private func updateDraftItem(from startPoint: CGPoint, to point: CGPoint) {
        guard var draftItem else { return }

        switch selectedTool {
        case .line:
            draftItem.points = [startPoint, point]
            draftItem.rect = boundingRect(for: draftItem.points)
        case .arrow:
            draftItem.points = [startPoint, midpoint(startPoint, point), point]
            draftItem.rect = boundingRect(for: draftItem.points)
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
            draftItem.rect = rect(from: startPoint, to: point)
        }

        self.draftItem = draftItem
    }

    private func hitTest(_ point: CGPoint) -> AnnotationItem? {
        items.reversed().first { item in
            item.hitTest(point, tolerance: 0.01)
        }
    }

    private var selectedItem: AnnotationItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    private func hitTestResizeHandle(
        _ point: CGPoint,
        in imageFrame: CGRect,
        item: AnnotationItem
    ) -> AnnotationResizeHandle? {
        let xTolerance = 12 / max(imageFrame.width, 1)
        let yTolerance = 12 / max(imageFrame.height, 1)

        if item.tool.usesEndpoints {
            return AnnotationResizeHandle.handles(for: item.tool).first { handle in
                guard let endpoint = handle.point(in: item) else { return false }
                return abs(point.x - endpoint.x) <= xTolerance && abs(point.y - endpoint.y) <= yTolerance
            }
        }

        return AnnotationResizeHandle.boxCases.first { handle in
            guard let corner = handle.corner(in: item.bounds) else { return false }
            return abs(point.x - corner.x) <= xTolerance && abs(point.y - corner.y) <= yTolerance
        }
    }

    private func applyStyleFromItem(_ item: AnnotationItem) {
        selectedTool = item.tool
        selectedSwatch = item.swatch
        strokeWidth = item.strokeWidth
        redactionDensity = item.redactionDensity
    }

    private func normalizedPoint(_ location: CGPoint, in imageFrame: CGRect, clamped: Bool) -> CGPoint? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }

        let point: CGPoint
        if clamped {
            point = CGPoint(
                x: min(max(location.x, imageFrame.minX), imageFrame.maxX),
                y: min(max(location.y, imageFrame.minY), imageFrame.maxY)
            )
        } else {
            guard imageFrame.contains(location) else { return nil }
            point = location
        }

        return CGPoint(
            x: (point.x - imageFrame.minX) / imageFrame.width,
            y: (point.y - imageFrame.minY) / imageFrame.height
        )
    }

    private func rect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        ).standardized
    }

    private func resizedItem(
        _ originalItem: AnnotationItem,
        handle: AnnotationResizeHandle,
        to point: CGPoint
    ) -> AnnotationItem {
        if originalItem.tool.usesEndpoints {
            return originalItem.withEndpoint(handle, movedTo: point)
        }

        let originalRect = originalItem.bounds
        let anchor = handle.oppositeCorner(in: originalRect)
        let constrainedPoint = handle.constrainedPoint(
            point,
            from: anchor,
            minimumSize: minimumItemSize
        )

        return originalItem.resized(to: rect(from: anchor, to: constrainedPoint))
    }

    private func initialPoints(for tool: AnnotationTool, at point: CGPoint) -> [CGPoint] {
        switch tool {
        case .line:
            [point, point]
        case .arrow:
            [point, point, point]
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
            []
        }
    }

    private func clampedDelta(_ delta: CGPoint, for bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(delta.x, -bounds.minX), 1 - bounds.maxX),
            y: min(max(delta.y, -bounds.minY), 1 - bounds.maxY)
        )
    }

    private func updateItem(id: AnnotationItem.ID, item: AnnotationItem) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = item
    }

    private func updateItem(id: AnnotationItem.ID, mutate: (inout AnnotationItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }

        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

}

private enum AnnotationInteraction {
    case drawing(startPoint: CGPoint)
    case moving(id: AnnotationItem.ID, startPoint: CGPoint, originalItem: AnnotationItem)
    case resizing(id: AnnotationItem.ID, handle: AnnotationResizeHandle, originalItem: AnnotationItem)
}

private enum AnnotationToolState: String {
    case idle
    case drawing
    case translating
    case resizing

    func path(for tool: AnnotationTool) -> String {
        "root.\(tool.rawValue).\(rawValue)"
    }
}

private struct AnnotationHistory {
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []

    mutating func reset(to items: [AnnotationItem]) {
        undoStack = []
        redoStack = []
    }

    mutating func push(_ items: [AnnotationItem]) {
        guard undoStack.last != items else { return }

        undoStack.append(items)
        redoStack.removeAll()
    }

    mutating func undo(current: [AnnotationItem]) -> [AnnotationItem]? {
        guard let previous = undoStack.popLast() else { return nil }

        redoStack.append(current)
        return previous
    }

    mutating func redo(current: [AnnotationItem]) -> [AnnotationItem]? {
        guard let next = redoStack.popLast() else { return nil }

        undoStack.append(current)
        return next
    }
}

private enum AnnotationResizeHandle: CaseIterable {
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
            item.controlPoint
        case .end:
            item.points.last
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            nil
        }
    }
}

private struct AnnotationCanvas: View {
    @Bindable var model: AnnotationEditorModel
    let image: NSImage

    @State private var hasActiveInteraction = false

    var body: some View {
        GeometryReader { proxy in
            let imageFrame = aspectFitRect(imageSize: model.imageSize, in: proxy.size)

            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .shadow(color: .black.opacity(0.26), radius: 18, x: 0, y: 8)

                ForEach(model.items) { item in
                    AnnotationItemView(
                        item: item,
                        image: image,
                        imageFrame: imageFrame,
                        isSelected: item.id == model.selectedItemID
                    )
                }

                if let draftItem = model.draftItem {
                    AnnotationItemView(
                        item: draftItem,
                        image: image,
                        imageFrame: imageFrame,
                        isSelected: false
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(interactionGesture(imageFrame: imageFrame))
        }
    }

    private func interactionGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !hasActiveInteraction {
                    hasActiveInteraction = true
                    model.beginInteraction(at: value.startLocation, in: imageFrame)
                }

                model.updateInteraction(to: value.location, in: imageFrame)
            }
            .onEnded { value in
                model.endInteraction(at: value.location, in: imageFrame)
                hasActiveInteraction = false
            }
    }

    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct AnnotationItemView: View {
    let item: AnnotationItem
    let image: NSImage
    let imageFrame: CGRect
    let isSelected: Bool

    private let selectionOutset: CGFloat = 5

    var body: some View {
        ZStack(alignment: .topLeading) {
            if item.tool.isRedactionTool {
                RedactionPreview(
                    image: image,
                    item: item,
                    imageFrame: imageFrame,
                    viewBounds: viewBounds
                )
            } else if item.tool.isFilledShape {
                itemPath
                    .fill(fillStyle)
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
        .allowsHitTesting(false)
    }

    private var itemPath: Path {
        let rect = viewRect(item.bounds)

        switch item.tool {
        case .rectangle, .filledRectangle:
            return Path(rect)

        case .pixelate, .blur:
            return Path(rect)

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
        if item.tool.usesEndpoints {
            ForEach(endpointViewPoints.indices, id: \.self) { index in
                SelectionHandle()
                    .position(endpointViewPoints[index])
            }

            if let controlViewPoint {
                CurveControlHandle()
                    .position(controlViewPoint)
            }
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
        guard let controlPoint = item.controlPoint else { return nil }
        return viewPoint(controlPoint)
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
}

private struct RedactionPreview: View {
    let image: NSImage
    let item: AnnotationItem
    let imageFrame: CGRect
    let viewBounds: CGRect

    var body: some View {
        if let redactedImage = RedactionImageProcessor.previewImage(
            source: image,
            tool: item.tool,
            density: item.redactionDensity
        ) {
            Image(nsImage: redactedImage)
                .interpolation(item.tool == .pixelate ? .none : .medium)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .mask {
                    Rectangle()
                        .frame(width: max(viewBounds.width, 1), height: max(viewBounds.height, 1))
                        .position(x: viewBounds.midX, y: viewBounds.midY)
                }
        }
    }
}

private enum RedactionImageProcessor {
    private static let cache = NSCache<NSString, NSImage>()
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func previewImage(source: NSImage, tool: AnnotationTool, density: CGFloat) -> NSImage? {
        guard tool.isRedactionTool else { return nil }

        let quantizedDensity = Int((density * 100).rounded())
        let cacheKey = "\(ObjectIdentifier(source).hashValue)-\(tool.rawValue)-\(quantizedDensity)" as NSString
        if let cachedImage = cache.object(forKey: cacheKey) {
            return cachedImage
        }

        let image: NSImage?
        switch tool {
        case .pixelate:
            image = makePixelatedImage(source: source, density: density)
        case .blur:
            image = makeBlurredImage(source: source, density: density)
        default:
            image = nil
        }

        if let image {
            cache.setObject(image, forKey: cacheKey)
        }

        return image
    }

    static func makePixelatedImage(source: NSImage, density: CGFloat) -> NSImage? {
        guard let cgImage = source.bestCGImage() else { return nil }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let blockSize = max(1, Int(round(pixelBlockSize(for: density))))
        let smallWidth = max(1, pixelWidth / blockSize)
        let smallHeight = max(1, pixelHeight / blockSize)
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = cgImage.bitmapInfo

        guard let downsampleContext = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        downsampleContext.interpolationQuality = .medium
        downsampleContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let downsampledImage = downsampleContext.makeImage() else { return nil }

        guard let upsampleContext = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: cgImage.bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        upsampleContext.interpolationQuality = .none
        upsampleContext.draw(downsampledImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let output = upsampleContext.makeImage() else { return nil }

        return NSImage(cgImage: output, size: source.size)
    }

    static func makeBlurredImage(source: NSImage, density: CGFloat) -> NSImage? {
        guard let cgImage = source.bestCGImage() else { return nil }

        let inputImage = CIImage(cgImage: cgImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = inputImage.clampedToExtent()
        filter.radius = Float(blurRadius(for: density))

        guard let outputImage = filter.outputImage?.cropped(to: inputImage.extent),
              let blurredImage = ciContext.createCGImage(outputImage, from: inputImage.extent) else {
            return nil
        }

        return NSImage(cgImage: blurredImage, size: source.size)
    }

    static func pixelBlockSize(for density: CGFloat) -> CGFloat {
        let normalized = min(max(density, 0), 1)
        return 4 + normalized * 36
    }

    static func blurRadius(for density: CGFloat) -> CGFloat {
        let normalized = min(max(density, 0), 1)
        return 2 + normalized * 28
    }
}

private extension NSImage {
    func bestCGImage() -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

private struct SelectionFrame: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)

                SelectionHandle().position(x: 0, y: 0)
                SelectionHandle().position(x: proxy.size.width, y: 0)
                SelectionHandle().position(x: 0, y: proxy.size.height)
                SelectionHandle().position(x: proxy.size.width, y: proxy.size.height)
            }
        }
    }
}

private struct SelectionHandle: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}

private struct CurveControlHandle: View {
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }
}

private struct AnnotationArrowGeometry {
    let tip: CGPoint
    let shaftControl: CGPoint
    let firstWing: CGPoint
    let secondWing: CGPoint

    init?(start: CGPoint, control: CGPoint, end: CGPoint, lineWidth: CGFloat) {
        let curveLength = Self.approximateCurveLength(start: start, control: control, end: end)
        guard curveLength > 0.5 else { return nil }

        let tangent = Self.tangent(start: start, control: control, end: end)
        let tangentLength = hypot(tangent.x, tangent.y)
        guard tangentLength > 0.5 else { return nil }

        let direction = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
        let backwardDirection = CGPoint(x: -direction.x, y: -direction.y)
        let headLength = min(max(16, lineWidth * 5.4), curveLength * 0.42)
        let headAngle = CGFloat.pi * 0.24
        let firstDirection = Self.rotate(backwardDirection, by: headAngle)
        let secondDirection = Self.rotate(backwardDirection, by: -headAngle)

        tip = end
        shaftControl = control
        firstWing = CGPoint(
            x: end.x + firstDirection.x * headLength,
            y: end.y + firstDirection.y * headLength
        )
        secondWing = CGPoint(
            x: end.x + secondDirection.x * headLength,
            y: end.y + secondDirection.y * headLength
        )
    }

    private static func approximateCurveLength(start: CGPoint, control: CGPoint, end: CGPoint) -> CGFloat {
        var length: CGFloat = 0
        var previous = start

        for step in 1...24 {
            let point = quadraticPoint(start: start, control: control, end: end, t: CGFloat(step) / 24)
            length += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }

        return length
    }

    private static func quadraticPoint(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let first = lerp(start, control, t)
        let second = lerp(control, end, t)
        return lerp(first, second, t)
    }

    private static func tangent(start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let tangent = CGPoint(
            x: 2 * (end.x - control.x),
            y: 2 * (end.y - control.y)
        )

        if hypot(tangent.x, tangent.y) > 0.5 {
            return tangent
        }

        return CGPoint(
            x: end.x - start.x,
            y: end.y - start.y
        )
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }

    private static func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: lhs.x + (rhs.x - lhs.x) * t,
            y: lhs.y + (rhs.y - lhs.y) * t
        )
    }
}

private struct AnnotationToolPicker: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Divider()
                        .frame(height: 17)
                        .padding(.horizontal, 2)
                }

                Button {
                    onSelect(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTool == tool ? .white : .primary)
                .background {
                    if selectedTool == tool {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .clipShape(Capsule())
                .contentShape(Capsule())
                .help(tool.title)
            }
        }
        .padding(3)
        .background(AnnotationToolbarStyle.controlBackground, in: Capsule())
        .overlay(Capsule().stroke(AnnotationToolbarStyle.stroke, lineWidth: 1))
    }
}

private struct AnnotationColorMenu: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void

    var body: some View {
        Menu {
            ForEach(AnnotationSwatch.allCases) { swatch in
                Button {
                    onSelect(swatch)
                } label: {
                    Label(swatch.title, systemImage: selectedSwatch == swatch ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(selectedSwatch.color)
                    .frame(width: 15, height: 15)
                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1.5))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .frame(width: 50, height: 30)
            .contentShape(Capsule())
            .background(AnnotationToolbarStyle.controlBackground, in: Capsule())
            .overlay(Capsule().stroke(AnnotationToolbarStyle.stroke, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(width: 50, height: 30)
        .contentShape(Capsule())
        .help("Color")
    }
}

private struct AnnotationStrokeMenu: View {
    let strokeWidth: CGFloat
    let onSelect: (CGFloat) -> Void

    private let widths: [CGFloat] = [2, 4, 6, 8, 12]

    var body: some View {
        Menu {
            ForEach(widths, id: \.self) { width in
                Button {
                    onSelect(width)
                } label: {
                    Label("\(Int(width)) px", systemImage: strokeWidth == width ? "checkmark" : "line.diagonal")
                }
            }
        } label: {
            HStack(spacing: 6) {
                StrokePreview(width: strokeWidth)
                    .frame(width: 22, height: 14)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .frame(width: 54, height: 30)
            .contentShape(Capsule())
            .background(AnnotationToolbarStyle.controlBackground, in: Capsule())
            .overlay(Capsule().stroke(AnnotationToolbarStyle.stroke, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(width: 54, height: 30)
        .contentShape(Capsule())
        .help("Stroke thickness")
    }
}

private struct AnnotationRedactionDensitySlider: View {
    let value: CGFloat
    let onChange: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding<Double>(
                    get: { Double(value) },
                    set: { onChange(CGFloat($0)) }
                ),
                in: 0.15...1
            )
            .controlSize(.small)
        }
        .frame(width: 150, height: 30)
        .padding(.horizontal, 9)
        .background(AnnotationToolbarStyle.controlBackground, in: Capsule())
        .overlay(Capsule().stroke(AnnotationToolbarStyle.stroke, lineWidth: 1))
        .help("Redaction density")
    }
}

private struct StrokePreview: View {
    let width: CGFloat

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 3, y: 13))
            path.addLine(to: CGPoint(x: 21, y: 3))
        }
        .stroke(.primary, style: StrokeStyle(lineWidth: min(width, 7), lineCap: .round))
    }
}

private struct AnnotationToolbarPillButton: View {
    let title: String
    let help: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(height: 30)
                .padding(.horizontal, isProminent ? 15 : 16)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isProminent ? .white : .primary)
        .background {
            if isProminent {
                Capsule().fill(Color.accentColor)
            } else {
                Capsule().fill(AnnotationToolbarStyle.controlBackground)
            }
        }
        .overlay(Capsule().stroke(isProminent ? .clear : AnnotationToolbarStyle.stroke, lineWidth: 1))
        .contentShape(Capsule())
        .help(help)
    }
}

private enum AnnotationToolbarStyle {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    static let stroke = Color(nsColor: .separatorColor)
}

private struct AnnotationKeyCommandHandler: NSViewRepresentable {
    let onDelete: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeNSView(context: Context) -> AnnotationKeyCommandHandlerView {
        let view = AnnotationKeyCommandHandlerView()
        view.onDelete = onDelete
        view.onUndo = onUndo
        view.onRedo = onRedo
        return view
    }

    func updateNSView(_ nsView: AnnotationKeyCommandHandlerView, context: Context) {
        nsView.onDelete = onDelete
        nsView.onUndo = onUndo
        nsView.onRedo = onRedo
    }
}

private final class AnnotationKeyCommandHandlerView: NSView {
    var onDelete: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private var localKeyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLocalKeyMonitor()
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    private func updateLocalKeyMonitor() {
        guard localKeyMonitor == nil else { return }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else {
                return event
            }

            if Self.isPlainDelete(event) {
                self.onDelete?()
                return nil
            }

            if Self.isUndo(event) {
                self.onUndo?()
                return nil
            }

            if Self.isRedo(event) {
                self.onRedo?()
                return nil
            }

            return event
        }
    }

    private static func isPlainDelete(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            && (event.keyCode == 51 || event.keyCode == 117)
    }

    private static func isUndo(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers?.lowercased() == "z"
    }

    private static func isRedo(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.modifierFlags.contains(.shift)
            && event.charactersIgnoringModifiers?.lowercased() == "z"
    }
}

private struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var rect: CGRect
    var points: [CGPoint]
    var swatch: AnnotationSwatch
    var strokeWidth: CGFloat
    var redactionDensity: CGFloat

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        rect: CGRect,
        points: [CGPoint] = [],
        swatch: AnnotationSwatch,
        strokeWidth: CGFloat,
        redactionDensity: CGFloat = 0.55
    ) {
        self.id = id
        self.tool = tool
        self.rect = rect
        self.points = points
        self.swatch = swatch
        self.strokeWidth = strokeWidth
        self.redactionDensity = redactionDensity
    }

    var bounds: CGRect {
        switch tool {
        case .line, .arrow:
            let boundsPoints = tool == .arrow ? arrowPoints : points
            guard let first = boundsPoints.first else { return rect.standardized }
            let bounds = boundsPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
                rect.union(CGRect(origin: point, size: .zero))
            }
            return bounds.standardized
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
            return rect.standardized
        }
    }

    var controlPoint: CGPoint? {
        guard tool == .arrow,
              let start = points.first,
              let end = points.last else {
            return nil
        }

        if points.count >= 3 {
            return points[1]
        }

        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    func isRenderable(minimumSize: CGFloat) -> Bool {
        switch tool {
        case .line:
            guard points.count == 2 else { return false }
            return hypot(points[0].x - points[1].x, points[0].y - points[1].y) >= minimumSize
        case .arrow:
            guard let start = points.first,
                  let end = points.last else {
                return false
            }

            return hypot(start.x - end.x, start.y - end.y) >= minimumSize
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
            return bounds.width >= minimumSize && bounds.height >= minimumSize
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .line:
            guard let start = points.first,
                  let end = points.last else {
                return false
            }

            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance

        case .arrow:
            guard let start = points.first,
                  let controlPoint,
                  let end = points.last else {
                return false
            }

            return distance(from: point, toQuadraticFrom: start, control: controlPoint, to: end) <= tolerance

        case .rectangle, .filledRectangle, .pixelate, .blur:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .ellipse:
            let expandedBounds = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard expandedBounds.width > 0, expandedBounds.height > 0 else { return false }

            let center = CGPoint(x: expandedBounds.midX, y: expandedBounds.midY)
            let normalizedX = (point.x - center.x) / (expandedBounds.width / 2)
            let normalizedY = (point.y - center.y) / (expandedBounds.height / 2)
            return normalizedX * normalizedX + normalizedY * normalizedY <= 1
        }
    }

    func offsetBy(_ delta: CGPoint) -> AnnotationItem {
        var item = self
        item.rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        item.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return item
    }

    func withEndpoint(_ handle: AnnotationResizeHandle, movedTo point: CGPoint) -> AnnotationItem {
        guard tool.usesEndpoints else { return self }

        var item = self
        if item.points.count < 2 {
            let fallback = item.points.first ?? point
            item.points = [fallback, fallback]
        }

        switch handle {
        case .start:
            item.ensureArrowPointStorage()
            item.points[0] = point
        case .control:
            guard item.tool == .arrow else { return self }
            item.ensureArrowPointStorage()
            item.points[1] = point
        case .end:
            item.ensureArrowPointStorage()
            item.points[item.points.count - 1] = point
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return self
        }

        item.rect = item.bounds
        return item
    }

    func resized(to newBounds: CGRect) -> AnnotationItem {
        let oldBounds = bounds.standardized
        guard oldBounds.width > 0, oldBounds.height > 0 else {
            var item = self
            item.rect = newBounds
            return item
        }

        var item = self
        item.rect = newBounds
        item.points = points.map { point in
            CGPoint(
                x: newBounds.minX + ((point.x - oldBounds.minX) / oldBounds.width) * newBounds.width,
                y: newBounds.minY + ((point.y - oldBounds.minY) / oldBounds.height) * newBounds.height
            )
        }
        return item
    }

    private var arrowPoints: [CGPoint] {
        guard tool == .arrow,
              let start = points.first,
              let controlPoint,
              let end = points.last else {
            return points
        }

        return [start, controlPoint, end]
    }

    private mutating func ensureArrowPointStorage() {
        guard tool == .arrow,
              points.count == 2,
              let start = points.first,
              let end = points.last else {
            return
        }

        points = [start, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), end]
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clampedProjection = min(max(projection, 0), 1)
        let closest = CGPoint(
            x: start.x + clampedProjection * dx,
            y: start.y + clampedProjection * dy
        )

        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private func distance(from point: CGPoint, toQuadraticFrom start: CGPoint, control: CGPoint, to end: CGPoint) -> CGFloat {
        var shortestDistance = CGFloat.greatestFiniteMagnitude
        var previous = start

        for step in 1...32 {
            let t = CGFloat(step) / 32
            let current = quadraticPoint(start: start, control: control, end: end, t: t)
            shortestDistance = min(shortestDistance, distance(from: point, toSegmentFrom: previous, to: current))
            previous = current
        }

        return shortestDistance
    }

    private func quadraticPoint(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let first = CGPoint(
            x: start.x + (control.x - start.x) * t,
            y: start.y + (control.y - start.y) * t
        )
        let second = CGPoint(
            x: control.x + (end.x - control.x) * t,
            y: control.y + (end.y - control.y) * t
        )

        return CGPoint(
            x: first.x + (second.x - first.x) * t,
            y: first.y + (second.y - first.y) * t
        )
    }
}

private enum AnnotationTool: String, CaseIterable, Identifiable {
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case pixelate
    case blur

    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .pixelate:
            "Pixelate"
        case .blur:
            "Blur"
        }
    }

    var systemImage: String {
        switch self {
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
        case .pixelate:
            "square.grid.3x3.fill"
        case .blur:
            "drop.fill"
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
}

enum AnnotationSwatch: String, CaseIterable, Identifiable {
    case red
    case blue
    case yellow
    case green
    case white
    case black

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .red:
            Color(red: 0.97, green: 0.22, blue: 0.2)
        case .blue:
            Color(red: 0.18, green: 0.48, blue: 1)
        case .yellow:
            Color(red: 1, green: 0.82, blue: 0.18)
        case .green:
            Color(red: 0.18, green: 0.72, blue: 0.36)
        case .white:
            .white
        case .black:
            .black
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red:
            NSColor(red: 0.97, green: 0.22, blue: 0.2, alpha: 1)
        case .blue:
            NSColor(red: 0.18, green: 0.48, blue: 1, alpha: 1)
        case .yellow:
            NSColor(red: 1, green: 0.82, blue: 0.18, alpha: 1)
        case .green:
            NSColor(red: 0.18, green: 0.72, blue: 0.36, alpha: 1)
        case .white:
            .white
        case .black:
            .black
        }
    }
}

private enum AnnotationRenderer {
    static func renderToTemporaryFile(sourceURL: URL, items: [AnnotationItem]) throws -> URL {
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenShot_Annotated_\(UUID().uuidString.prefix(6)).png")
        try render(sourceURL: sourceURL, items: items, destinationURL: destinationURL, contentType: .png)
        return destinationURL
    }

    static func render(
        sourceURL: URL,
        items: [AnnotationItem],
        destinationURL: URL,
        contentType: UTType
    ) throws {
        guard let source = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(cgImage, in: fullRect)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for item in items {
            context.setStrokeColor(item.swatch.nsColor.cgColor)
            context.setFillColor(item.swatch.nsColor.cgColor)

            let lineWidth = renderedLineWidth(for: item, imageWidth: width, imageHeight: height)
            context.setLineWidth(lineWidth)

            switch item.tool {
            case .rectangle:
                context.stroke(renderedRect(item.bounds, width: width, height: height))

            case .filledRectangle:
                context.fill(renderedRect(item.bounds, width: width, height: height))

            case .ellipse:
                context.strokeEllipse(in: renderedRect(item.bounds, width: width, height: height))

            case .pixelate:
                applyPixelation(
                    in: renderedRect(item.bounds, width: width, height: height),
                    context: context,
                    canvasSize: CGSize(width: width, height: height),
                    colorSpace: colorSpace,
                    density: item.redactionDensity
                )

            case .blur:
                applyBlur(
                    in: renderedRect(item.bounds, width: width, height: height),
                    context: context,
                    canvasSize: CGSize(width: width, height: height),
                    density: item.redactionDensity
                )

            case .line:
                guard let first = item.points.first,
                      let last = item.points.last else {
                    continue
                }

                let start = renderedPoint(first, width: width, height: height)
                let end = renderedPoint(last, width: width, height: height)
                context.beginPath()
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()

            case .arrow:
                guard let first = item.points.first,
                      let control = item.controlPoint,
                      let last = item.points.last,
                      let geometry = AnnotationArrowGeometry(
                        start: renderedPoint(first, width: width, height: height),
                        control: renderedPoint(control, width: width, height: height),
                        end: renderedPoint(last, width: width, height: height),
                        lineWidth: lineWidth
                      ) else {
                    continue
                }

                context.beginPath()
                context.move(to: renderedPoint(first, width: width, height: height))
                context.addQuadCurve(to: geometry.tip, control: geometry.shaftControl)
                context.strokePath()
                drawArrowHead(geometry, context: context)
            }
        }

        guard let renderedImage = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            contentType.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var options: CFDictionary?
        if contentType == .jpeg {
            options = [
                kCGImageDestinationLossyCompressionQuality: OpenShotPreferences.compressionQuality
            ] as CFDictionary
        }

        CGImageDestinationAddImage(destination, renderedImage, options)

        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func renderedRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: rect.minX * CGFloat(width),
            y: (1 - rect.maxY) * CGFloat(height),
            width: rect.width * CGFloat(width),
            height: rect.height * CGFloat(height)
        )
    }

    private static func renderedPoint(_ point: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: point.x * CGFloat(width),
            y: (1 - point.y) * CGFloat(height)
        )
    }

    private static func drawArrowHead(_ geometry: AnnotationArrowGeometry, context: CGContext) {
        context.beginPath()
        context.move(to: geometry.firstWing)
        context.addLine(to: geometry.tip)
        context.addLine(to: geometry.secondWing)
        context.strokePath()
    }

    private static func applyPixelation(
        in rect: CGRect,
        context: CGContext,
        canvasSize: CGSize,
        colorSpace: CGColorSpace,
        density: CGFloat
    ) {
        let targetRect = rect.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard targetRect.width >= 1,
              targetRect.height >= 1,
              let currentImage = context.makeImage(),
              let croppedImage = currentImage.cropping(to: targetRect) else {
            return
        }

        let pixelSize = RedactionImageProcessor.pixelBlockSize(for: density)
        let lowWidth = max(1, Int(targetRect.width / pixelSize))
        let lowHeight = max(1, Int(targetRect.height / pixelSize))

        guard let lowContext = CGContext(
            data: nil,
            width: lowWidth,
            height: lowHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }

        lowContext.interpolationQuality = .low
        lowContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight))

        guard let pixelatedImage = lowContext.makeImage() else { return }

        context.saveGState()
        context.clip(to: targetRect)
        context.interpolationQuality = .none
        context.draw(pixelatedImage, in: targetRect)
        context.restoreGState()
    }

    private static func applyBlur(
        in rect: CGRect,
        context: CGContext,
        canvasSize: CGSize,
        density: CGFloat
    ) {
        let targetRect = rect.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard targetRect.width >= 1,
              targetRect.height >= 1,
              let currentImage = context.makeImage(),
              let croppedImage = currentImage.cropping(to: targetRect) else {
            return
        }

        let inputImage = CIImage(cgImage: croppedImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = inputImage.clampedToExtent()
        filter.radius = Float(RedactionImageProcessor.blurRadius(for: density))

        let ciContext = CIContext()
        guard let outputImage = filter.outputImage,
              let blurredImage = ciContext.createCGImage(outputImage, from: inputImage.extent) else {
            return
        }

        context.saveGState()
        context.clip(to: targetRect)
        context.draw(blurredImage, in: targetRect)
        context.restoreGState()
    }

    private static func renderedLineWidth(for item: AnnotationItem, imageWidth: Int, imageHeight: Int) -> CGFloat {
        max(1.5, item.strokeWidth * max(CGFloat(imageWidth), CGFloat(imageHeight)) / 900)
    }
}
