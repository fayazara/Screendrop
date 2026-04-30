//
//  AnnotationEditorModel.swift
//  OpenShot
//

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AnnotationEditorModel {
    var sourceURL: URL?
    var previewImage: NSImage?
    var imageSize: CGSize = .zero
    var items: [AnnotationItem] = []
    var draftItem: AnnotationItem?
    var selectedItemID: AnnotationItem.ID?
    var editingTextItemID: AnnotationItem.ID?
    var isTextPlacementArmed = false
    var selectedTool: AnnotationTool = .rectangle
    var selectedSwatch: AnnotationSwatch = .red
    var strokeWidth: CGFloat = 4
    var redactionDensity: CGFloat = 0.55
    var backgroundSettings = AnnotationBackgroundSettings()
    var errorMessage: String?
    private var nextNumberedCircleValue = 1
    private(set) var statePath = AnnotationToolState.idle.path(for: .rectangle)

    var itemIDs: [AnnotationItem.ID] {
        items.map(\.id)
    }

    var isTransformingExistingAnnotation: Bool {
        switch interaction {
        case .moving, .resizing:
            true
        case .drawing, .none:
            false
        }
    }

    var inspectedTool: AnnotationTool? {
        selectedItem?.tool ?? (selectedTool.createsAnnotation ? selectedTool : nil)
    }

    // Text style defaults (applied to new text items, updated when selecting existing text)
    var textFontName: String = AnnotationTextMetrics.defaultFontName
    var textFontSize: CGFloat = 48
    var textIsBold: Bool = true
    var textIsItalic: Bool = false
    var textIsUnderline: Bool = false
    var textAlignment: NSTextAlignment = .left

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
        editingTextItemID = nil
        isTextPlacementArmed = selectedTool == .text
        backgroundSettings = AnnotationBackgroundSettings()
        interaction = nil
        nextNumberedCircleValue = 1
        history.reset()
        RedactionImageProcessor.removeAllCachedPreviewImages()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
        errorMessage = nil

        if previewImage == nil || imageSize == .zero {
            errorMessage = "Unable to load screenshot."
        }
    }

    func beginInteraction(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard let point = normalizedPoint(location, in: imageFrame, boundedBy: boundaryFrame, clamped: false) else {
            selectedItemID = nil
            editingTextItemID = nil
            isTextPlacementArmed = false
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return
        }

        if selectedTool == .select {
            if beginSelectionInteraction(at: point, in: imageFrame, preservingSelectedTool: true) {
                return
            }

            clearSelection()
            return
        }

        if beginSelectionInteraction(at: point, in: imageFrame, preservingSelectedTool: false) {
            return
        }

        selectedItemID = nil
        editingTextItemID = nil
        guard selectedTool != .text || isTextPlacementArmed else {
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return
        }

        beginDraftItem(at: point, within: annotationBounds(for: imageFrame, boundaryFrame: boundaryFrame))
    }

    func updateInteraction(to location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard let interaction,
              let point = normalizedPoint(location, in: imageFrame, boundedBy: boundaryFrame, clamped: true) else {
            return
        }
        let allowedBounds = annotationBounds(for: imageFrame, boundaryFrame: boundaryFrame)

        switch interaction {
        case .drawing(let startPoint):
            updateDraftItem(
                from: startPoint,
                to: point,
                within: allowedBounds,
                lockAspectRatio: isAspectRatioLocked
            )

        case .moving(let id, let startPoint, let originalItem):
            let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            updateItem(id: id, item: originalItem.offsetBy(clampedDelta(delta, for: originalItem.bounds, within: allowedBounds)))

        case .resizing(let id, let handle, let originalItem):
            updateItem(id: id, item: resizedItem(
                originalItem,
                handle: handle,
                to: point,
                lockAspectRatio: isAspectRatioLocked
            ))
        }
    }

    func endInteraction(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        defer { interaction = nil }

        guard let interaction,
              let point = normalizedPoint(location, in: imageFrame, boundedBy: boundaryFrame, clamped: true) else {
            draftItem = nil
            return
        }
        let allowedBounds = annotationBounds(for: imageFrame, boundaryFrame: boundaryFrame)

        switch interaction {
        case .drawing(let startPoint):
            updateDraftItem(
                from: startPoint,
                to: point,
                within: allowedBounds,
                lockAspectRatio: isAspectRatioLocked
            )

            guard let item = draftItem,
                  item.isRenderable(minimumSize: minimumItemSize, allowEmptyText: item.tool == .text) else {
                draftItem = nil
                statePath = AnnotationToolState.idle.path(for: selectedTool)
                return
            }

            history.push(items)
            items.append(item)
            selectedItemID = item.id
            editingTextItemID = item.tool == .text ? item.id : nil
            if item.tool == .text {
                isTextPlacementArmed = false
            } else if item.tool == .numberedCircle {
                nextNumberedCircleValue += 1
            }
            draftItem = nil

        case .moving, .resizing:
            break
        }

        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    private func beginSelectionInteraction(
        at point: CGPoint,
        in imageFrame: CGRect,
        preservingSelectedTool: Bool
    ) -> Bool {
        // Text items don't have resize handles -- skip resize hit-test for them.
        if let selectedItem, selectedItem.tool != .text,
           let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: selectedItem) {
            applyStyleFromItem(selectedItem, updateSelectedTool: !preservingSelectedTool)
            draftItem = nil
            history.push(items)
            interaction = .resizing(id: selectedItem.id, handle: resizeHandle, originalItem: selectedItem)
            statePath = AnnotationToolState.resizing.path(for: selectedTool)
            return true
        }

        guard let item = hitTest(point) else { return false }

        // For text items: first click selects, second click on same item enters editing.
        let shouldBeginTextEditing = item.tool == .text
            && selectedItemID == item.id
            && editingTextItemID != item.id
        selectedItemID = item.id
        applyStyleFromItem(item, updateSelectedTool: !preservingSelectedTool)
        draftItem = nil
        history.push(items)

        if shouldBeginTextEditing {
            editingTextItemID = item.id
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return true
        }

        editingTextItemID = nil

        if item.tool != .text,
           let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: item) {
            interaction = .resizing(id: item.id, handle: resizeHandle, originalItem: item)
            statePath = AnnotationToolState.resizing.path(for: selectedTool)
        } else {
            interaction = .moving(id: item.id, startPoint: point, originalItem: item)
            statePath = AnnotationToolState.translating.path(for: selectedTool)
        }

        return true
    }

    private func clearSelection() {
        selectedItemID = nil
        editingTextItemID = nil
        isTextPlacementArmed = false
        interaction = nil
        draftItem = nil
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    private func beginDraftItem(at point: CGPoint, within allowedBounds: CGRect) {
        let textLineHeight: CGFloat = imageSize.height > 0
            ? textFontSize / (imageSize.height * AnnotationTextMetrics.fontScale)
            : AnnotationTextMetrics.defaultNormalizedLineHeight
        let itemRect: CGRect
        switch selectedTool {
        case .select:
            return
        case .text:
            itemRect = defaultTextRect(at: point, lineHeight: textLineHeight, within: allowedBounds)
        case .numberedCircle:
            itemRect = AnnotationNumberedCircleMetrics.defaultRect(centeredAt: point, imageSize: imageSize, within: allowedBounds)
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .pixelate, .blur:
            itemRect = CGRect(origin: point, size: .zero)
        }
        let itemText = selectedTool == .numberedCircle ? "\(nextNumberedCircleValue)" : ""

        draftItem = AnnotationItem(
            tool: selectedTool,
            rect: itemRect,
            points: initialPoints(for: selectedTool, at: point),
            swatch: selectedSwatch,
            strokeWidth: strokeWidth,
            redactionDensity: redactionDensity,
            text: itemText,
            textLineHeight: textLineHeight,
            fontName: textFontName,
            isBold: textIsBold,
            isItalic: textIsItalic,
            isUnderline: textIsUnderline,
            textAlignment: textAlignment
        )
        interaction = .drawing(startPoint: point)
        statePath = AnnotationToolState.drawing.path(for: selectedTool)
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

    func selectTool(_ tool: AnnotationTool) {
        selectedTool = tool
        editingTextItemID = nil
        isTextPlacementArmed = tool == .text
        statePath = AnnotationToolState.idle.path(for: tool)
    }

    func deleteSelectedAnnotation() {
        guard let selectedItemID else { return }

        history.push(items)
        items.removeAll { $0.id == selectedItemID }
        self.selectedItemID = nil
        editingTextItemID = nil
        isTextPlacementArmed = false
        interaction = nil
        draftItem = nil
        syncNextNumberedCircleValue()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func hoveredAnnotation(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) -> AnnotationItem? {
        guard let point = normalizedPoint(location, in: imageFrame, boundedBy: boundaryFrame, clamped: false) else {
            return nil
        }

        return hitTest(point)
    }

    func containsInteractionPoint(_ location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) -> Bool {
        normalizedPoint(location, in: imageFrame, boundedBy: boundaryFrame, clamped: false) != nil
    }

    func setText(_ text: String, for id: AnnotationItem.ID) {
        updateItem(id: id) { item in
            item.text = text
        }
    }

    func setTextViewContentSize(_ size: CGSize, for id: AnnotationItem.ID, imageFrame: CGRect, allowedBounds: CGRect) {
        // Don't fight with active move/resize drags.
        guard interaction == nil else { return }
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        let normalizedWidth = size.width / imageFrame.width
        let normalizedHeight = size.height / imageFrame.height
        let minW = AnnotationTextMetrics.minimumNormalizedWidth(lineHeight: items.first(where: { $0.id == id })?.textLineHeight ?? AnnotationTextMetrics.defaultNormalizedLineHeight, imageSize: imageSize)
        updateItem(id: id) { item in
            let newWidth = min(max(normalizedWidth, minW), allowedBounds.width)
            let newHeight = min(max(normalizedHeight, item.textLineHeight), allowedBounds.height)
            let maxX = max(allowedBounds.minX, allowedBounds.maxX - newWidth)
            let maxY = max(allowedBounds.minY, allowedBounds.maxY - newHeight)
            item.rect = CGRect(
                x: min(max(item.rect.origin.x, allowedBounds.minX), maxX),
                y: min(max(item.rect.origin.y, allowedBounds.minY), maxY),
                width: newWidth,
                height: newHeight
            )
        }
    }

    // MARK: - Text style methods

    /// The effective font size in points for the selected text item (for display in the popover).
    var selectedTextFontSize: CGFloat {
        get {
            guard let item = selectedTextItem else { return textFontSize }
            return AnnotationTextMetrics.renderedFontSize(
                lineHeight: item.textLineHeight,
                imagePixelHeight: imageSize.height
            ).rounded()
        }
        set {
            setTextFontSize(newValue)
        }
    }

    var selectedTextFontName: String {
        get { selectedTextItem?.fontName ?? textFontName }
        set { setTextFontName(newValue) }
    }

    var selectedTextIsBold: Bool {
        get { selectedTextItem?.isBold ?? textIsBold }
        set { setTextBold(newValue) }
    }

    var selectedTextIsItalic: Bool {
        get { selectedTextItem?.isItalic ?? textIsItalic }
        set { setTextItalic(newValue) }
    }

    var selectedTextIsUnderline: Bool {
        get { selectedTextItem?.isUnderline ?? textIsUnderline }
        set { setTextUnderline(newValue) }
    }

    var selectedTextAlignment: NSTextAlignment {
        get { selectedTextItem?.textAlignment ?? textAlignment }
        set { setTextAlignment(newValue) }
    }

    /// Whether the text style popover should be available.
    var isTextStyleAvailable: Bool {
        selectedTool == .text || selectedTextItem != nil
    }

    private var selectedTextItem: AnnotationItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID && $0.tool == .text }
    }

    func setTextFontSize(_ pointSize: CGFloat) {
        let clamped = max(pointSize, AnnotationTextMetrics.minimumFontSize)
        textFontSize = clamped

        guard let selectedItemID, selectedTextItem != nil else { return }
        guard imageSize.height > 0 else { return }
        let newLineHeight = clamped / (imageSize.height * AnnotationTextMetrics.fontScale)
        history.push(items)
        updateItem(id: selectedItemID) { item in
            item.textLineHeight = newLineHeight
        }
    }

    func setTextFontName(_ name: String) {
        textFontName = name
        guard let selectedItemID, selectedTextItem != nil else { return }
        history.push(items)
        updateItem(id: selectedItemID) { item in
            item.fontName = name
        }
    }

    func setTextBold(_ bold: Bool) {
        textIsBold = bold
        guard let selectedItemID, selectedTextItem != nil else { return }
        history.push(items)
        updateItem(id: selectedItemID) { item in
            item.isBold = bold
        }
    }

    func setTextItalic(_ italic: Bool) {
        textIsItalic = italic
        guard let selectedItemID, selectedTextItem != nil else { return }
        history.push(items)
        updateItem(id: selectedItemID) { item in
            item.isItalic = italic
        }
    }

    func setTextUnderline(_ underline: Bool) {
        textIsUnderline = underline
        guard let selectedItemID, selectedTextItem != nil else { return }
        history.push(items)
        updateItem(id: selectedItemID) { item in
            item.isUnderline = underline
        }
    }

    func setTextAlignment(_ alignment: NSTextAlignment) {
        textAlignment = alignment
        guard let selectedItemID, selectedTextItem != nil else { return }
        history.push(items)
        updateItem(id: selectedItemID) { item in
            item.textAlignment = alignment
        }
    }

    func commitTextEditing() {
        guard let editingTextItemID else { return }

        if let item = items.first(where: { $0.id == editingTextItemID }),
           item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.removeAll { $0.id == editingTextItemID }
            selectedItemID = nil
        }

        self.editingTextItemID = nil
    }

    func undo() {
        guard let restoredItems = history.undo(current: items) else { return }

        items = restoredItems
        selectedItemID = nil
        editingTextItemID = nil
        draftItem = nil
        interaction = nil
        syncNextNumberedCircleValue()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func redo() {
        guard let restoredItems = history.redo(current: items) else { return }

        items = restoredItems
        selectedItemID = nil
        editingTextItemID = nil
        draftItem = nil
        interaction = nil
        syncNextNumberedCircleValue()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    private func updateDraftItem(
        from startPoint: CGPoint,
        to point: CGPoint,
        within allowedBounds: CGRect,
        lockAspectRatio: Bool
    ) {
        guard var draftItem else { return }

        switch selectedTool {
        case .select:
            break
        case .line:
            draftItem.points = [startPoint, point]
            draftItem.rect = boundingRect(for: draftItem.points)
        case .arrow:
            draftItem.points = [startPoint, midpoint(startPoint, point), point]
            draftItem.rect = boundingRect(for: draftItem.points)
        case .freehand:
            draftItem.points = freehandPoints(adding: point, to: draftItem.points)
            draftItem.rect = boundingRect(for: draftItem.points)
        case .numberedCircle:
            draftItem.rect = AnnotationNumberedCircleMetrics.defaultRect(centeredAt: startPoint, imageSize: imageSize, within: allowedBounds)
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
            let aspectRatio = selectedTool.supportsAspectLock && lockAspectRatio ? squareAspectRatio : nil
            draftItem.rect = rect(from: startPoint, to: point, aspectRatio: aspectRatio)
        case .text:
            draftItem.rect = defaultTextRect(at: startPoint, lineHeight: draftItem.textLineHeight, within: allowedBounds)
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

    private func applyStyleFromItem(_ item: AnnotationItem, updateSelectedTool: Bool = true) {
        if updateSelectedTool {
            selectedTool = item.tool
        }
        selectedSwatch = item.swatch
        strokeWidth = item.strokeWidth
        redactionDensity = item.redactionDensity
        if item.tool == .text {
            textFontName = item.fontName
            textFontSize = AnnotationTextMetrics.renderedFontSize(
                lineHeight: item.textLineHeight,
                imagePixelHeight: imageSize.height
            ).rounded()
            textIsBold = item.isBold
            textIsItalic = item.isItalic
            textIsUnderline = item.isUnderline
            textAlignment = item.textAlignment
        }
    }

    private func normalizedPoint(
        _ location: CGPoint,
        in imageFrame: CGRect,
        boundedBy boundaryFrame: CGRect,
        clamped: Bool
    ) -> CGPoint? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        guard boundaryFrame.width > 0, boundaryFrame.height > 0 else { return nil }

        let point: CGPoint
        if clamped {
            point = CGPoint(
                x: min(max(location.x, boundaryFrame.minX), boundaryFrame.maxX),
                y: min(max(location.y, boundaryFrame.minY), boundaryFrame.maxY)
            )
        } else {
            guard boundaryFrame.contains(location) else { return nil }
            point = location
        }

        return CGPoint(
            x: (point.x - imageFrame.minX) / imageFrame.width,
            y: (point.y - imageFrame.minY) / imageFrame.height
        )
    }

    func annotationBounds(for imageFrame: CGRect, boundaryFrame: CGRect) -> CGRect {
        guard imageFrame.width > 0, imageFrame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return CGRect(
            x: (boundaryFrame.minX - imageFrame.minX) / imageFrame.width,
            y: (boundaryFrame.minY - imageFrame.minY) / imageFrame.height,
            width: boundaryFrame.width / imageFrame.width,
            height: boundaryFrame.height / imageFrame.height
        )
    }

    private var isAspectRatioLocked: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private var squareAspectRatio: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return imageSize.height / imageSize.width
    }

    private func rect(from startPoint: CGPoint, to endPoint: CGPoint, aspectRatio: CGFloat? = nil) -> CGRect {
        let adjustedEndPoint: CGPoint
        if let aspectRatio, aspectRatio > 0 {
            adjustedEndPoint = aspectLockedPoint(from: startPoint, to: endPoint, aspectRatio: aspectRatio)
        } else {
            adjustedEndPoint = endPoint
        }

        return CGRect(
            x: min(startPoint.x, adjustedEndPoint.x),
            y: min(startPoint.y, adjustedEndPoint.y),
            width: abs(adjustedEndPoint.x - startPoint.x),
            height: abs(adjustedEndPoint.y - startPoint.y)
        ).standardized
    }

    private func aspectLockedPoint(from anchor: CGPoint, to point: CGPoint, aspectRatio: CGFloat) -> CGPoint {
        let deltaX = point.x - anchor.x
        let deltaY = point.y - anchor.y
        let proposedWidth = abs(deltaX)
        let proposedHeight = abs(deltaY)

        guard proposedWidth > 0, proposedHeight > 0 else { return point }

        let width: CGFloat
        let height: CGFloat
        if proposedWidth / aspectRatio <= proposedHeight {
            width = proposedWidth
            height = proposedWidth / aspectRatio
        } else {
            height = proposedHeight
            width = proposedHeight * aspectRatio
        }

        return CGPoint(
            x: anchor.x + width * (deltaX < 0 ? -1 : 1),
            y: anchor.y + height * (deltaY < 0 ? -1 : 1)
        )
    }

    private func resizedItem(
        _ originalItem: AnnotationItem,
        handle: AnnotationResizeHandle,
        to point: CGPoint,
        lockAspectRatio: Bool
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
        let aspectRatio: CGFloat? = originalItem.tool.supportsAspectLock && lockAspectRatio && originalRect.height > 0
            ? originalRect.width / originalRect.height
            : nil

        return originalItem.resized(to: rect(from: anchor, to: constrainedPoint, aspectRatio: aspectRatio))
    }

    private func initialPoints(for tool: AnnotationTool, at point: CGPoint) -> [CGPoint] {
        switch tool {
        case .select:
            []
        case .line:
            [point, point]
        case .arrow:
            [point, point, point]
        case .freehand:
            [point]
        case .rectangle, .filledRectangle, .ellipse, .numberedCircle, .pixelate, .blur, .text:
            []
        }
    }

    private func defaultTextRect(
        at point: CGPoint,
        lineHeight: CGFloat = AnnotationTextMetrics.defaultNormalizedLineHeight,
        within allowedBounds: CGRect
    ) -> CGRect {
        let height = lineHeight
        let width = AnnotationTextMetrics.minimumNormalizedWidth(lineHeight: height, imageSize: imageSize)
        let maxX = max(allowedBounds.minX, allowedBounds.maxX - width)
        let maxY = max(allowedBounds.minY, allowedBounds.maxY - height)

        return CGRect(
            x: min(max(point.x, allowedBounds.minX), maxX),
            y: min(max(point.y, allowedBounds.minY), maxY),
            width: width,
            height: height
        )
    }

    private func clampedDelta(_ delta: CGPoint, for bounds: CGRect, within allowedBounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(delta.x, allowedBounds.minX - bounds.minX), allowedBounds.maxX - bounds.maxX),
            y: min(max(delta.y, allowedBounds.minY - bounds.minY), allowedBounds.maxY - bounds.maxY)
        )
    }

    private func updateItem(id: AnnotationItem.ID, item: AnnotationItem) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = item
    }

    private func updateItem(id: AnnotationItem.ID, mutate: (inout AnnotationItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        mutate(&item)
        items[index] = item
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }

        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private func freehandPoints(adding point: CGPoint, to points: [CGPoint]) -> [CGPoint] {
        guard let last = points.last else { return [point] }

        let minimumSpacing: CGFloat = 0.0015
        guard hypot(point.x - last.x, point.y - last.y) >= minimumSpacing else {
            return points
        }

        var updatedPoints = points
        updatedPoints.append(point)
        return updatedPoints
    }

    private func syncNextNumberedCircleValue() {
        let currentMaximum = items
            .filter { $0.tool == .numberedCircle }
            .compactMap { Int($0.text) }
            .max() ?? 0
        nextNumberedCircleValue = currentMaximum + 1
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

    mutating func reset() {
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
