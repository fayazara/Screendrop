//
//  AnnotationEditorModel.swift
//  Screendrop
//

import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AnnotationEditorModel {
    /// The display/history image being edited. Used to match the preview item
    /// and to locate the sidecar document.
    var sourceURL: URL?
    /// The untouched image the annotations are rendered on top of. When
    /// re-editing an existing document this is the preserved base image;
    /// otherwise it is the same as `sourceURL`.
    var baseImageURL: URL?
    var previewImage: NSImage?
    /// Whether the currently displayed `previewImage` is a downscaled copy of
    /// the source (low-resolution preview preference). Exports are unaffected.
    var isPreviewDownscaled = false
    var imageSize: CGSize = .zero
    var items: [AnnotationItem] = []
    var draftItem: AnnotationItem?
    var selectedItemIDs: Set<AnnotationItem.ID> = []
    var selectedItemID: AnnotationItem.ID? {
        get {
            selectedItemIDs.count == 1 ? selectedItemIDs.first : nil
        }
        set {
            if let newValue {
                selectedItemIDs = [newValue]
            } else {
                selectedItemIDs = []
            }
        }
    }
    var editingTextItemID: AnnotationItem.ID?
    var isTextPlacementArmed = false
    var selectionRect: CGRect?
    var selectedTool: AnnotationTool = .rectangle
    var selectedSwatch: AnnotationSwatch = .red
    var strokeWidth: CGFloat = 4
    var redactionDensity: CGFloat = 0.55
    var backgroundSettings = AnnotationBackgroundSettings()
    var errorMessage: String?
    var isSmartRedacting = false
    var smartRedactionMessage: String?

    // MARK: Crop
    /// Whether the modal crop overlay is currently active.
    var isCropping = false
    /// The working crop rectangle, normalized to the image (0...1, top-left
    /// origin). Only meaningful while `isCropping` is true.
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The aspect-ratio constraint applied while cropping.
    var cropAspect: CropAspectRatio = .freeform

    // MARK: Zoom & pan
    /// When `true` the canvas is scaled to fit the available viewport (default).
    var zoomToFit = true
    /// Absolute display scale used when `zoomToFit` is false. Maps a canvas
    /// pixel to a view point, i.e. `imageFrame.width = canvasPixelSize.width * manualZoomScale`.
    var manualZoomScale: CGFloat = 1
    /// Pan offset (in view points) applied when the zoomed content overflows the viewport.
    var panOffset: CGSize = .zero
    /// The live viewport size, published by `AnnotationCanvas`.
    var viewportSize: CGSize = .zero
    /// The backing scale factor of the canvas, published by `AnnotationCanvas`.
    var displayScale: CGFloat = 2

    static let minZoomPercent = 10
    static let maxZoomPercent = 400

    private var nextNumberedCircleValue = 1
    private(set) var statePath = AnnotationToolState.idle.path(for: .rectangle)

    var itemIDs: [AnnotationItem.ID] {
        items.map(\.id)
    }

    var selectionCount: Int {
        selectedItemIDs.count
    }

    var isTransformingExistingAnnotation: Bool {
        switch interaction {
        case .moving, .movingSelection, .resizing:
            true
        case .drawing, .selecting, .none:
            false
        }
    }

    var inspectedTool: AnnotationTool? {
        selectedItem?.tool ?? selectedItems.first?.tool ?? (selectedTool.createsAnnotation ? selectedTool : nil)
    }

    var isStrokeStyleAvailable: Bool {
        if selectedItems.isEmpty {
            return inspectedTool != .numberedCircle
        }

        return selectedItems.contains { $0.tool != .numberedCircle }
    }

    var isRedactionStyleAvailable: Bool {
        if selectedItems.isEmpty {
            return inspectedTool?.isRedactionTool == true
        }

        return selectedItems.contains { $0.tool.isRedactionTool }
    }

    // Text style defaults (applied to new text items, updated when selecting existing text)
    var textFontName: String = AnnotationTextMetrics.defaultFontName
    var textFontSize: CGFloat = 48
    var textIsBold: Bool = true
    var textIsItalic: Bool = false
    var textIsUnderline: Bool = false
    var textAlignment: NSTextAlignment = .left

    private var interaction: AnnotationInteraction?
    var history = AnnotationHistory()
    private let minimumItemSize: CGFloat = 0.006

    /// A full snapshot of the editor's image state, captured before a crop so
    /// the operation can be undone/redone.
    private struct CropSnapshot {
        var baseImageURL: URL?
        var previewImage: NSImage?
        var isPreviewDownscaled: Bool
        var imageSize: CGSize
        var items: [AnnotationItem]
    }

    private var cropUndoStack: [CropSnapshot] = []
    private var cropRedoStack: [CropSnapshot] = []

    /// Smallest crop dimension, in normalized units, derived from a pixel floor.
    private let minimumCropPixels: CGFloat = 24

    /// Longest-edge cap (in pixels) for the downscaled editing preview when the
    /// low-resolution preview preference is enabled. Kept high enough that the
    /// preview stays crisp even when zoomed, while still bounding memory use on
    /// very large (multi-monitor / Retina) captures.
    private let previewImageMaxPixelSize: CGFloat = 2880

    func load(url: URL?, dismiss: DismissAction) {
        guard let url else {
            dismiss()
            return
        }

        applyAnnotationPreset()
        resetZoom()
        sourceURL = url

        // Restore an existing editable document if one exists, rendering the
        // canvas from the untouched base image so annotations remain editable.
        let document = ScreenshotHistoryStore.shared.loadEditDocument(for: url)
        let candidateBaseURL = ScreenshotHistoryStore.baseImageURL(for: url)
        let renderSourceURL: URL
        if let document, FileManager.default.fileExists(atPath: candidateBaseURL.path) {
            renderSourceURL = candidateBaseURL
            items = document.annotationItems
            backgroundSettings = document.backgroundSettings
        } else {
            renderSourceURL = url
            items = []
            backgroundSettings = AnnotationBackgroundSettings()
        }

        baseImageURL = renderSourceURL
        imageSize = ScreenshotImageLoader.imageSize(at: renderSourceURL) ?? .zero
        // The editing preview is only ever used for on-screen display; exports
        // always re-read the full-resolution source via AnnotationRenderer.
        previewImage = makePreviewImage(from: renderSourceURL)
        isCropping = false
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropAspect = .freeform
        cropUndoStack = []
        cropRedoStack = []
        draftItem = nil
        selectedItemIDs = []
        editingTextItemID = nil
        isTextPlacementArmed = selectedTool == .text
        selectionRect = nil
        interaction = nil
        nextNumberedCircleValue = 1
        syncNextNumberedCircleValue()
        history.reset()
        RedactionImageProcessor.removeAllCachedPreviewImages()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
        errorMessage = nil
        smartRedactionMessage = nil

        if previewImage == nil || imageSize == .zero {
            errorMessage = "Unable to load screenshot."
        }
    }

    /// Loads an editing preview for the image at `url`. When the low-resolution
    /// preview preference is enabled the longest edge is capped to bound memory;
    /// otherwise the image is decoded at full resolution. Updates
    /// `isPreviewDownscaled` as a side effect. Requires `imageSize` to be set.
    private func makePreviewImage(from url: URL) -> NSImage? {
        if ScreendropPreferences.lowResolutionEditorPreview {
            isPreviewDownscaled = max(imageSize.width, imageSize.height) > previewImageMaxPixelSize
            return ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: previewImageMaxPixelSize)
        } else {
            isPreviewDownscaled = false
            return ScreenshotImageLoader.fullResolutionImage(at: url)
        }
    }

    func releaseEditorResources() {
        sourceURL = nil
        baseImageURL = nil
        previewImage = nil
        isPreviewDownscaled = false
        imageSize = .zero
        items = []
        draftItem = nil
        selectedItemIDs = []
        editingTextItemID = nil
        isTextPlacementArmed = false
        selectionRect = nil
        backgroundSettings = AnnotationBackgroundSettings()
        interaction = nil
        history.reset()
        isCropping = false
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        cropAspect = .freeform
        cropUndoStack = []
        cropRedoStack = []
        errorMessage = nil
        isSmartRedacting = false
        smartRedactionMessage = nil
        RedactionImageProcessor.removeAllCachedPreviewImages()
    }

    func beginInteraction(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard !isCropping else { return }
        let isExtendingSelection = isMultiSelectionModifierPressed

        guard let point = normalizedPoint(location, in: imageFrame, boundedBy: boundaryFrame, clamped: false) else {
            if !isExtendingSelection {
                clearSelection()
            }
            return
        }

        if selectedTool == .select {
            if beginSelectionInteraction(
                at: point,
                in: imageFrame,
                preservingSelectedTool: true,
                extendingSelection: isExtendingSelection
            ) {
                return
            }

            beginMarqueeSelection(at: point, extendingSelection: isExtendingSelection)
            return
        }

        if beginSelectionInteraction(
            at: point,
            in: imageFrame,
            preservingSelectedTool: false,
            extendingSelection: isExtendingSelection
        ) {
            return
        }

        selectedItemIDs = []
        editingTextItemID = nil
        selectionRect = nil
        guard selectedTool != .text || isTextPlacementArmed else {
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return
        }

        beginDraftItem(at: point, within: annotationBounds(for: imageFrame, boundaryFrame: boundaryFrame))
    }

    func updateInteraction(to location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard !isCropping else { return }
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

        case .movingSelection(let ids, let startPoint, let originalItems):
            let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
            let clampedDelta = clampedDelta(delta, for: groupBounds(for: originalItems), within: allowedBounds)

            for item in originalItems where ids.contains(item.id) {
                updateItem(id: item.id, item: item.offsetBy(clampedDelta))
            }

        case .resizing(let id, let handle, let originalItem):
            updateItem(id: id, item: resizedItem(
                originalItem,
                handle: handle,
                to: point,
                lockAspectRatio: isAspectRatioLocked
            ))

        case .selecting(let startPoint, let originalSelection, let extendsSelection):
            updateMarqueeSelection(
                from: startPoint,
                to: point,
                originalSelection: originalSelection,
                extendsSelection: extendsSelection
            )
        }
    }

    func endInteraction(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard !isCropping else { return }
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

            registerItemEdit()
            items.append(item)
            selectedItemID = item.id
            editingTextItemID = item.tool == .text ? item.id : nil
            if item.tool == .text {
                isTextPlacementArmed = false
            } else if item.tool == .numberedCircle {
                nextNumberedCircleValue += 1
            }
            draftItem = nil

        case .moving, .movingSelection, .resizing:
            break

        case .selecting(let startPoint, let originalSelection, let extendsSelection):
            updateMarqueeSelection(
                from: startPoint,
                to: point,
                originalSelection: originalSelection,
                extendsSelection: extendsSelection
            )
            selectionRect = nil
        }

        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    private func beginSelectionInteraction(
        at point: CGPoint,
        in imageFrame: CGRect,
        preservingSelectedTool: Bool,
        extendingSelection: Bool
    ) -> Bool {
        // Text items don't have resize handles -- skip resize hit-test for them.
        if !extendingSelection,
           let selectedItem,
           selectedItem.tool != .text,
           let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: selectedItem) {
            applyStyleFromItem(selectedItem, updateSelectedTool: !preservingSelectedTool)
            draftItem = nil
            registerItemEdit()
            interaction = .resizing(id: selectedItem.id, handle: resizeHandle, originalItem: selectedItem)
            statePath = AnnotationToolState.resizing.path(for: selectedTool)
            return true
        }

        guard let item = hitTest(point) else { return false }

        if extendingSelection {
            toggleSelection(of: item, preservingSelectedTool: preservingSelectedTool)
            draftItem = nil
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return true
        }

        let shouldPreserveMultipleSelection = selectedItemIDs.count > 1 && selectedItemIDs.contains(item.id)

        // For text items: first click selects, second click on same item enters editing.
        let shouldBeginTextEditing = item.tool == .text
            && selectedItemID == item.id
            && editingTextItemID != item.id

        if !shouldPreserveMultipleSelection {
            selectedItemID = item.id
        }

        applyStyleFromItem(item, updateSelectedTool: !preservingSelectedTool)
        draftItem = nil
        registerItemEdit()

        if shouldBeginTextEditing {
            editingTextItemID = item.id
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return true
        }

        editingTextItemID = nil

        if shouldPreserveMultipleSelection {
            interaction = .movingSelection(
                ids: selectedItemIDs,
                startPoint: point,
                originalItems: selectedItems
            )
            statePath = AnnotationToolState.translating.path(for: selectedTool)
        } else if item.tool != .text,
           let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: item) {
            interaction = .resizing(id: item.id, handle: resizeHandle, originalItem: item)
            statePath = AnnotationToolState.resizing.path(for: selectedTool)
        } else {
            interaction = .moving(id: item.id, startPoint: point, originalItem: item)
            statePath = AnnotationToolState.translating.path(for: selectedTool)
        }

        return true
    }

    private func beginMarqueeSelection(at point: CGPoint, extendingSelection: Bool) {
        editingTextItemID = nil
        isTextPlacementArmed = false
        draftItem = nil
        selectionRect = CGRect(origin: point, size: .zero)
        interaction = .selecting(
            startPoint: point,
            originalSelection: extendingSelection ? selectedItemIDs : [],
            extendsSelection: extendingSelection
        )
        statePath = AnnotationToolState.drawing.path(for: selectedTool)
    }

    private func clearSelection() {
        selectedItemIDs = []
        editingTextItemID = nil
        isTextPlacementArmed = false
        interaction = nil
        draftItem = nil
        selectionRect = nil
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
        saveAnnotationPreset()

        if !selectedItemIDs.isEmpty {
            registerItemEdit()
            updateSelectedItems { item in
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
        saveAnnotationPreset()

        if !selectedItemIDs.isEmpty {
            registerItemEdit()
            updateSelectedItems { item in
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
        saveAnnotationPreset()

        if !selectedItemIDs.isEmpty {
            registerItemEdit()
            updateSelectedItems { item in
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
        saveAnnotationPreset()
    }

    func deleteSelectedAnnotation() {
        guard !selectedItemIDs.isEmpty else { return }

        registerItemEdit()
        items.removeAll { selectedItemIDs.contains($0.id) }
        selectedItemIDs = []
        editingTextItemID = nil
        isTextPlacementArmed = false
        interaction = nil
        draftItem = nil
        selectionRect = nil
        syncNextNumberedCircleValue()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func selectAllAnnotations() {
        guard !items.isEmpty else { return }

        selectedItemIDs = Set(items.map(\.id))
        editingTextItemID = nil
        isTextPlacementArmed = false
        interaction = nil
        draftItem = nil
        selectionRect = nil
        selectedTool = .select
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func smartRedact(using tool: AnnotationTool) {
        guard tool.isRedactionTool,
              !isSmartRedacting,
              let recognitionURL = baseImageURL ?? sourceURL else {
            return
        }

        let loadedSourceURL = sourceURL
        isSmartRedacting = true
        smartRedactionMessage = nil

        Task { @MainActor in
            let regions = await SmartRedactionRecognizer.sensitiveRegions(at: recognitionURL)

            guard sourceURL == loadedSourceURL,
                  baseImageURL == recognitionURL || sourceURL == recognitionURL else {
                isSmartRedacting = false
                return
            }

            applySmartRedactionRegions(regions, tool: tool)
            isSmartRedacting = false
        }
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

    /// Records the current annotation state for undo before an item mutation.
    /// Also invalidates any pending crop-redo, since a fresh edit diverges the
    /// timeline (you can no longer redo an undone crop after editing).
    func registerItemEdit() {
        history.push(items)
        cropRedoStack.removeAll()
    }

    func undo() {
        guard !isCropping else { return }

        if let restoredItems = history.undo(current: items) {
            applyRestoredItems(restoredItems)
            return
        }

        // No finer-grained annotation edits remain; fall back to undoing the
        // most recent crop, if any.
        undoCrop()
    }

    func redo() {
        guard !isCropping else { return }

        if let restoredItems = history.redo(current: items) {
            applyRestoredItems(restoredItems)
            return
        }

        redoCrop()
    }

    private func applyRestoredItems(_ restoredItems: [AnnotationItem]) {
        items = restoredItems
        selectedItemIDs = []
        editingTextItemID = nil
        draftItem = nil
        interaction = nil
        selectionRect = nil
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

    private var selectedItems: [AnnotationItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    private func toggleSelection(of item: AnnotationItem, preservingSelectedTool: Bool) {
        editingTextItemID = nil
        isTextPlacementArmed = false
        selectionRect = nil

        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }

        if let selectedItem {
            applyStyleFromItem(selectedItem, updateSelectedTool: !preservingSelectedTool)
        } else if !selectedItemIDs.isEmpty {
            selectedSwatch = item.swatch
            strokeWidth = item.strokeWidth
            redactionDensity = item.redactionDensity
        }
    }

    private func updateMarqueeSelection(
        from startPoint: CGPoint,
        to point: CGPoint,
        originalSelection: Set<AnnotationItem.ID>,
        extendsSelection: Bool
    ) {
        let rect = rect(from: startPoint, to: point).standardized
        selectionRect = rect

        let selectedByMarquee = Set(items.compactMap { item in
            item.bounds.intersects(rect) ? item.id : nil
        })

        selectedItemIDs = extendsSelection
            ? originalSelection.union(selectedByMarquee)
            : selectedByMarquee

        if let selectedItem {
            applyStyleFromItem(selectedItem, updateSelectedTool: false)
        }
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

    private func applySmartRedactionRegions(_ regions: [SmartRedactionRegion], tool: AnnotationTool) {
        let renderableRegions = regions.filter {
            $0.bounds.width >= minimumItemSize && $0.bounds.height >= minimumItemSize
        }

        guard !renderableRegions.isEmpty else {
            smartRedactionMessage = "No sensitive text found."
            return
        }

        registerItemEdit()
        let newItems = renderableRegions.map { region in
            AnnotationItem(
                tool: tool,
                rect: region.bounds,
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                redactionDensity: redactionDensity
            )
        }

        items.append(contentsOf: newItems)
        selectedItemIDs = Set(newItems.map(\.id))
        editingTextItemID = nil
        isTextPlacementArmed = false
        selectionRect = nil
        interaction = nil
        draftItem = nil
        selectedTool = tool
        statePath = AnnotationToolState.idle.path(for: tool)
        smartRedactionMessage = "Added \(newItems.count) redaction\(newItems.count == 1 ? "" : "s")."
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

    private var isMultiSelectionModifierPressed: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.shift) || flags.contains(.command)
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
            if originalItem.tool == .arrow, handle == .control {
                return arrowItem(originalItem, draggingCurveHandleTo: point)
            }
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

    /// Bend an arrow by dragging its curve handle. The dragged location is the
    /// desired apex of the curve, which maps directly onto the visible bend.
    /// When the bend gets close to straight, the apex snaps back onto the
    /// start→end line so releasing near the centre produces a clean line.
    private func arrowItem(_ item: AnnotationItem, draggingCurveHandleTo apex: CGPoint) -> AnnotationItem {
        guard let start = item.points.first, let end = item.points.last else {
            return item
        }

        let snappedApex = snappedArrowApex(apex, start: start, end: end)
        let control = AnnotationItem.arrowControlPoint(forApex: snappedApex, start: start, end: end)
        return item.withEndpoint(.control, movedTo: control)
    }

    /// Snap the apex onto the start→end line when its perpendicular offset is a
    /// small fraction of the arrow's length, keeping the handle under the
    /// cursor while flattening the curve to a straight line.
    private func snappedArrowApex(_ apex: CGPoint, start: CGPoint, end: CGPoint) -> CGPoint {
        // Work in pixel space so the snap distance is aspect-correct.
        let sx = max(imageSize.width, 1)
        let sy = max(imageSize.height, 1)
        let ax = apex.x * sx
        let ay = apex.y * sy
        let startX = start.x * sx
        let startY = start.y * sy
        let dx = end.x * sx - startX
        let dy = end.y * sy - startY
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return apex }

        let projection = ((ax - startX) * dx + (ay - startY) * dy) / lengthSquared
        let projX = startX + projection * dx
        let projY = startY + projection * dy
        let perpendicular = hypot(ax - projX, ay - projY)
        let snapThreshold = max(sqrt(lengthSquared) * 0.06, 6)

        guard perpendicular <= snapThreshold else { return apex }
        return CGPoint(x: projX / sx, y: projY / sy)
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

    private func groupBounds(for items: [AnnotationItem]) -> CGRect {
        guard let first = items.first else { return .zero }

        return items.dropFirst().reduce(first.bounds) { bounds, item in
            bounds.union(item.bounds)
        }
    }

    func updateItem(id: AnnotationItem.ID, item: AnnotationItem) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = item
    }

    func updateItem(id: AnnotationItem.ID, mutate: (inout AnnotationItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        mutate(&item)
        items[index] = item
    }

    private func updateSelectedItems(mutate: (inout AnnotationItem) -> Void) {
        for index in items.indices where selectedItemIDs.contains(items[index].id) {
            mutate(&items[index])
        }
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

    private func applyAnnotationPreset() {
        let preset = AnnotationPresetStore.load()
        selectedTool = preset.selectedTool
        selectedSwatch = preset.swatch
        strokeWidth = CGFloat(preset.strokeWidth)
        redactionDensity = CGFloat(preset.redactionDensity)
        textFontName = preset.textFontName
        textFontSize = CGFloat(preset.textFontSize)
        textIsBold = preset.textIsBold
        textIsItalic = preset.textIsItalic
        textIsUnderline = preset.textIsUnderline
        textAlignment = preset.textAlignment
    }

    func saveAnnotationPreset() {
        let customSwatch = AnnotationSwatch.allCases.contains(selectedSwatch) ? nil : CodableSwatch(swatch: selectedSwatch)
        let preset = AnnotationStylePreset(
            selectedToolRawValue: selectedTool.rawValue,
            swatchID: selectedSwatch.id,
            customSwatch: customSwatch,
            strokeWidth: Double(strokeWidth),
            redactionDensity: Double(redactionDensity),
            textFontName: textFontName,
            textFontSize: Double(textFontSize),
            textIsBold: textIsBold,
            textIsItalic: textIsItalic,
            textIsUnderline: textIsUnderline,
            textAlignmentRawValue: textAlignment.rawValue
        )
        AnnotationPresetStore.save(preset)
    }

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

}

// MARK: - Zoom & pan

extension AnnotationEditorModel {
    /// The full canvas size (image + optional background padding) in image pixels.
    var canvasPixelSize: CGSize {
        AnnotationBackgroundLayout.make(contentSize: imageSize, settings: backgroundSettings).canvasSize
    }

    /// Scale at which the canvas is shown at its "actual" (100%) size: 1 image
    /// pixel maps to 1 logical point divided by the backing scale factor.
    var pixelToPointScale: CGFloat {
        displayScale > 0 ? 1 / displayScale : 1
    }

    /// Scale that fits the whole canvas inside the current viewport.
    var fitZoomScale: CGFloat {
        let canvas = canvasPixelSize
        guard canvas.width > 0, canvas.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return pixelToPointScale
        }
        return min(viewportSize.width / canvas.width, viewportSize.height / canvas.height)
    }

    /// The scale currently applied to the canvas.
    var resolvedZoomScale: CGFloat {
        zoomToFit ? fitZoomScale : manualZoomScale
    }

    /// The displayed zoom percentage (relative to actual size).
    var zoomPercent: Int {
        guard pixelToPointScale > 0 else { return 100 }
        return max(1, Int((resolvedZoomScale / pixelToPointScale * 100).rounded()))
    }

    /// `true` when the zoomed content is larger than the viewport in either axis.
    var canPan: Bool {
        let scaled = scaledCanvasSize
        return scaled.width > viewportSize.width + 0.5 || scaled.height > viewportSize.height + 0.5
    }

    private var scaledCanvasSize: CGSize {
        let canvas = canvasPixelSize
        return CGSize(width: canvas.width * resolvedZoomScale, height: canvas.height * resolvedZoomScale)
    }

    private var minZoomScale: CGFloat { pixelToPointScale * CGFloat(Self.minZoomPercent) / 100 }
    private var maxZoomScale: CGFloat { pixelToPointScale * CGFloat(Self.maxZoomPercent) / 100 }

    /// The on-screen rect of the canvas for the given viewport, accounting for
    /// the current zoom scale and (clamped) pan offset.
    func displayCanvasFrame(in container: CGSize) -> CGRect {
        let canvas = canvasPixelSize
        guard canvas.width > 0, canvas.height > 0,
              container.width > 0, container.height > 0 else { return .zero }

        let fit = min(container.width / canvas.width, container.height / canvas.height)
        let scale = zoomToFit ? fit : manualZoomScale
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        let pan = clampedPan(panOffset, scaledSize: size, container: container)
        return CGRect(
            x: (container.width - size.width) / 2 + pan.width,
            y: (container.height - size.height) / 2 + pan.height,
            width: size.width,
            height: size.height
        )
    }

    func resetZoom() {
        zoomToFit = true
        manualZoomScale = 1
        panOffset = .zero
    }

    func fitCanvas() {
        zoomToFit = true
        panOffset = .zero
    }

    func setZoomPercent(_ percent: Int) {
        manualZoomScale = clampScale(pixelToPointScale * CGFloat(percent) / 100)
        zoomToFit = false
        panOffset = .zero
    }

    /// Set an absolute display scale (used for continuous pinch/scroll zoom).
    func setZoomScale(_ scale: CGFloat) {
        manualZoomScale = clampScale(scale)
        zoomToFit = false
        clampPanToBounds()
    }

    func zoomIn() { applyZoomFactor(1.25) }

    func zoomOut() { applyZoomFactor(0.8) }

    func zoomBy(_ factor: CGFloat) {
        setZoomScale(resolvedZoomScale * factor)
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        panOffset = clampedPan(
            CGSize(width: panOffset.width + dx, height: panOffset.height + dy),
            scaledSize: scaledCanvasSize,
            container: viewportSize
        )
    }

    private func applyZoomFactor(_ factor: CGFloat) {
        manualZoomScale = clampScale(resolvedZoomScale * factor)
        zoomToFit = false
        clampPanToBounds()
    }

    private func clampScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minZoomScale), maxZoomScale)
    }

    private func clampPanToBounds() {
        panOffset = clampedPan(panOffset, scaledSize: scaledCanvasSize, container: viewportSize)
    }

    private func clampedPan(_ pan: CGSize, scaledSize: CGSize, container: CGSize) -> CGSize {
        let maxX = max(0, (scaledSize.width - container.width) / 2)
        let maxY = max(0, (scaledSize.height - container.height) / 2)
        return CGSize(
            width: min(max(pan.width, -maxX), maxX),
            height: min(max(pan.height, -maxY), maxY)
        )
    }
}

// MARK: - Crop

extension AnnotationEditorModel {
    /// Whether the image has been cropped in this editing session (and can be
    /// undone). Used to decide whether there is committable content.
    var isCropped: Bool {
        !cropUndoStack.isEmpty
    }

    /// Pixel dimensions of the current crop selection.
    var cropPixelSize: CGSize {
        CGSize(
            width: (cropRect.width * imageSize.width).rounded(),
            height: (cropRect.height * imageSize.height).rounded()
        )
    }

    /// Enter the modal crop mode, resetting the selection to the whole image.
    func beginCropping() {
        guard imageSize != .zero, !isCropping else { return }

        commitTextEditing()
        selectedItemIDs = []
        editingTextItemID = nil
        isTextPlacementArmed = false
        draftItem = nil
        interaction = nil
        selectionRect = nil
        cropAspect = .freeform
        cropRect = CropRectEditor.unit
        fitCanvas()
        isCropping = true
    }

    /// Leave crop mode without applying.
    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        cropRect = CropRectEditor.unit
        cropAspect = .freeform
    }

    func toggleCropping() {
        isCropping ? cancelCrop() : beginCropping()
    }

    /// Reset the crop selection back to the whole image (respecting the aspect).
    func resetCrop() {
        guard isCropping else { return }
        if let ratio = cropAspect.normalizedRatio(imageSize: imageSize) {
            cropRect = CropRectEditor.applyAspect(to: CropRectEditor.unit, aspect: ratio)
        } else {
            cropRect = CropRectEditor.unit
        }
    }

    func setCropAspect(_ aspect: CropAspectRatio) {
        cropAspect = aspect
        guard isCropping else { return }
        if let ratio = aspect.normalizedRatio(imageSize: imageSize) {
            cropRect = CropRectEditor.applyAspect(to: cropRect, aspect: ratio)
        }
    }

    /// Resize the crop selection by dragging a handle to a normalized point.
    func updateCrop(handle: CropHandle, toNormalized point: CGPoint) {
        guard isCropping else { return }
        // Edge handles ignore the aspect lock; corner handles enforce it.
        let aspect = handle.isCorner ? cropAspect.normalizedRatio(imageSize: imageSize) : nil
        cropRect = CropRectEditor.resize(
            cropRect,
            handle: handle,
            to: point,
            aspect: aspect,
            minWidth: minimumCropWidth,
            minHeight: minimumCropHeight,
            fromCenter: isCropCenterResizeModifierPressed
        )
    }

    /// Whether the "resize from center" modifier is held. Honors Cmd+Shift as
    /// well as Option (the macOS-standard for symmetric resize).
    private var isCropCenterResizeModifierPressed: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.option) || (flags.contains(.command) && flags.contains(.shift))
    }

    /// Translate the whole crop selection by a normalized delta.
    func moveCrop(byNormalized delta: CGSize) {
        guard isCropping else { return }
        cropRect = CropRectEditor.move(cropRect, by: delta)
    }

    /// Bake the crop into a new full-resolution base image, remap annotations,
    /// and exit crop mode. Quality is preserved (the crop runs on the native
    /// pixels). The operation is undoable via `undo()`.
    func applyCrop() {
        guard isCropping else { return }

        let crop = cropRect.standardized.intersection(CropRectEditor.unit)
        defer {
            isCropping = false
            cropRect = CropRectEditor.unit
            cropAspect = .freeform
        }

        guard crop.width > 0.0001, crop.height > 0.0001 else { return }

        // No-op when the selection still covers (essentially) the whole image.
        if crop.minX < 0.0005, crop.minY < 0.0005, crop.width > 0.999, crop.height > 0.999 {
            return
        }

        guard let baseURL = baseImageURL,
              let result = AnnotationImageCropper.crop(url: baseURL, normalizedRect: crop) else {
            errorMessage = "Unable to crop the image."
            return
        }

        let snapshot = currentCropSnapshot()
        let oldImageSize = imageSize
        let usedCrop = result.normalizedRect
        let newImageSize = result.pixelSize

        let remappedItems = items.compactMap {
            $0.remappedForCrop(crop: usedCrop, oldImageSize: oldImageSize, newImageSize: newImageSize)
        }

        baseImageURL = result.url
        imageSize = newImageSize
        items = remappedItems
        previewImage = makePreviewImage(from: result.url)

        selectedItemIDs = []
        editingTextItemID = nil
        draftItem = nil
        interaction = nil
        selectionRect = nil
        syncNextNumberedCircleValue()

        // A crop invalidates the fine-grained annotation history (those
        // snapshots live in the pre-crop coordinate space), so reset it. The
        // crop snapshot itself preserves the items for undo.
        history.reset()
        cropUndoStack.append(snapshot)
        cropRedoStack.removeAll()

        resetZoom()
        errorMessage = nil
    }

    private func undoCrop() {
        guard let previous = cropUndoStack.popLast() else { return }
        cropRedoStack.append(currentCropSnapshot())
        restore(previous)
    }

    private func redoCrop() {
        guard let next = cropRedoStack.popLast() else { return }
        cropUndoStack.append(currentCropSnapshot())
        restore(next)
    }

    private func currentCropSnapshot() -> CropSnapshot {
        CropSnapshot(
            baseImageURL: baseImageURL,
            previewImage: previewImage,
            isPreviewDownscaled: isPreviewDownscaled,
            imageSize: imageSize,
            items: items
        )
    }

    private func restore(_ snapshot: CropSnapshot) {
        baseImageURL = snapshot.baseImageURL
        previewImage = snapshot.previewImage
        isPreviewDownscaled = snapshot.isPreviewDownscaled
        imageSize = snapshot.imageSize
        items = snapshot.items
        selectedItemIDs = []
        editingTextItemID = nil
        draftItem = nil
        interaction = nil
        selectionRect = nil
        // Annotation history was reset at crop time; keep it clean.
        history.reset()
        syncNextNumberedCircleValue()
        statePath = AnnotationToolState.idle.path(for: selectedTool)
        resetZoom()
    }

    private var minimumCropWidth: CGFloat {
        guard imageSize.width > 0 else { return 0.05 }
        return min(0.5, max(0.01, minimumCropPixels / imageSize.width))
    }

    private var minimumCropHeight: CGFloat {
        guard imageSize.height > 0 else { return 0.05 }
        return min(0.5, max(0.01, minimumCropPixels / imageSize.height))
    }
}
