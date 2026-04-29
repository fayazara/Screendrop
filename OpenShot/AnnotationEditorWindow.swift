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
    @State private var isInspectorPresented = true
    @State private var isFinishing = false
    @Environment(\.dismiss) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        mainContent
            .navigationTitle("OpenShot Annotate")
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                }
            }
            .task(id: url) {
                model.load(url: url, dismiss: dismissWindow)
            }
            .onAppear {
                AnnotationEditorActivationPolicy.enter()
            }
            .onDisappear {
                AnnotationEditorActivationPolicy.leave()
            }
            .onDeleteCommand {
                model.deleteSelectedAnnotation()
            }
            .background(AnnotationKeyCommandHandler(
                onDelete: model.deleteSelectedAnnotation,
                onUndo: model.undo,
                onRedo: model.redo
            ))
            .inspector(isPresented: $isInspectorPresented) {
                AnnotationEditorInspector(
                    model: model,
                    onPickWallpaper: pickCustomWallpaper,
                    onSaveAs: saveAs,
                    onDone: finishEditing
                )
            }
    }

    private var mainContent: some View {
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
        .frame(minWidth: 760, minHeight: 580)
        .overlay(alignment: .bottomLeading) {
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
                    backgroundSettings: model.backgroundSettings,
                    destinationURL: destinationURL,
                    contentType: ScreenshotFileActions.exportContentType
                )
            } catch {
                model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
            }
        }
    }

    private func pickCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Background Wallpaper"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let wallpaper = AnnotationCustomWallpaper(url: url)
            model.backgroundSettings.customWallpaper = wallpaper
            model.backgroundSettings.style = .customWallpaper(wallpaper)
        }
    }

    private func finishEditing() {
        guard let sourceURL = model.sourceURL else {
            dismissWindow()
            return
        }

        guard !isFinishing else { return }

        guard !model.items.isEmpty || model.backgroundSettings.isEnabled else {
            dismissWindow()
            return
        }

        isFinishing = true
        do {
            let annotatedURL = try AnnotationRenderer.renderToTemporaryFile(
                sourceURL: sourceURL,
                items: model.items,
                backgroundSettings: model.backgroundSettings
            )
            let updatedExistingPreview = ScreenshotPreviewStack.shared.replace(originalURL: sourceURL, with: annotatedURL)
            if !updatedExistingPreview {
                openWindow(id: "PREVIEWWINDOW")
            }
            dismissWindow()
        } catch {
            isFinishing = false
            model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
        }
    }
}

@MainActor
private enum AnnotationEditorActivationPolicy {
    private static var activeWindowCount = 0

    static func enter() {
        activeWindowCount += 1
        PreviewWindowCaptureExclusion.shared.hideForAnnotation()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        activeWindowCount = max(0, activeWindowCount - 1)
        PreviewWindowCaptureExclusion.shared.restoreAfterAnnotation()
        guard activeWindowCount == 0 else { return }

        Task { @MainActor in
            guard activeWindowCount == 0 else { return }
            NSApp.setActivationPolicy(.accessory)
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
    var editingTextItemID: AnnotationItem.ID?
    var isTextPlacementArmed = false
    var selectedTool: AnnotationTool = .rectangle
    var selectedSwatch: AnnotationSwatch = .red
    var strokeWidth: CGFloat = 4
    var redactionDensity: CGFloat = 0.55
    var backgroundSettings = AnnotationBackgroundSettings()
    var errorMessage: String?
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

    // Text style defaults (applied to new text items, updated when selecting existing text)
    var textFontName: String = AnnotationTextMetrics.defaultFontName
    var textFontSize: CGFloat = 24
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
            editingTextItemID = nil
            isTextPlacementArmed = false
            interaction = nil
            statePath = AnnotationToolState.idle.path(for: selectedTool)
            return
        }

        // Text items don't have resize handles -- skip resize hit-test for them.
        if let selectedItem, selectedItem.tool != .text,
           let resizeHandle = hitTestResizeHandle(point, in: imageFrame, item: selectedItem) {
            applyStyleFromItem(selectedItem)
            draftItem = nil
            history.push(items)
            interaction = .resizing(id: selectedItem.id, handle: resizeHandle, originalItem: selectedItem)
            statePath = AnnotationToolState.resizing.path(for: selectedTool)
            return
        }

        if let item = hitTest(point) {
            // For text items: first click selects, second click on same item enters editing.
            let shouldBeginTextEditing = item.tool == .text
                && selectedItemID == item.id
                && editingTextItemID != item.id
            selectedItemID = item.id
            applyStyleFromItem(item)
            draftItem = nil
            history.push(items)

            if shouldBeginTextEditing {
                editingTextItemID = item.id
                interaction = nil
                statePath = AnnotationToolState.idle.path(for: selectedTool)
                return
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
        } else {
            selectedItemID = nil
            editingTextItemID = nil
            guard selectedTool != .text || isTextPlacementArmed else {
                interaction = nil
                statePath = AnnotationToolState.idle.path(for: selectedTool)
                return
            }

            let textLineHeight: CGFloat = imageSize.height > 0
                ? textFontSize / (imageSize.height * AnnotationTextMetrics.fontScale)
                : AnnotationTextMetrics.defaultNormalizedLineHeight

            draftItem = AnnotationItem(
                tool: selectedTool,
                rect: selectedTool == .text ? defaultTextRect(at: point, lineHeight: textLineHeight) : CGRect(origin: point, size: .zero),
                points: initialPoints(for: selectedTool, at: point),
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                redactionDensity: redactionDensity,
                text: "",
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
            }
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
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func hoveredAnnotation(at location: CGPoint, in imageFrame: CGRect) -> AnnotationItem? {
        guard let point = normalizedPoint(location, in: imageFrame, clamped: false) else {
            return nil
        }

        return hitTest(point)
    }

    func containsImagePoint(_ location: CGPoint, in imageFrame: CGRect) -> Bool {
        normalizedPoint(location, in: imageFrame, clamped: false) != nil
    }

    func setText(_ text: String, for id: AnnotationItem.ID) {
        updateItem(id: id) { item in
            item.text = text
        }
    }

    func setTextViewContentSize(_ size: CGSize, for id: AnnotationItem.ID, imageFrame: CGRect) {
        // Don't fight with active move/resize drags.
        guard interaction == nil else { return }
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        let normalizedWidth = size.width / imageFrame.width
        let normalizedHeight = size.height / imageFrame.height
        let minW = AnnotationTextMetrics.minimumNormalizedWidth(lineHeight: items.first(where: { $0.id == id })?.textLineHeight ?? AnnotationTextMetrics.defaultNormalizedLineHeight, imageSize: imageSize)
        updateItem(id: id) { item in
            let newWidth = min(max(normalizedWidth, minW), 1)
            let newHeight = min(max(normalizedHeight, item.textLineHeight), 1)
            let maxX = max(0, 1 - newWidth)
            let maxY = max(0, 1 - newHeight)
            item.rect = CGRect(
                x: min(max(item.rect.origin.x, 0), maxX),
                y: min(max(item.rect.origin.y, 0), maxY),
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
        statePath = AnnotationToolState.idle.path(for: selectedTool)
    }

    func redo() {
        guard let restoredItems = history.redo(current: items) else { return }

        items = restoredItems
        selectedItemID = nil
        editingTextItemID = nil
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
        case .text:
            draftItem.rect = defaultTextRect(at: startPoint, lineHeight: draftItem.textLineHeight)
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
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur, .text:
            []
        }
    }

    private func defaultTextRect(at point: CGPoint, lineHeight: CGFloat = AnnotationTextMetrics.defaultNormalizedLineHeight) -> CGRect {
        let height = lineHeight
        let width = AnnotationTextMetrics.minimumNormalizedWidth(lineHeight: height, imageSize: imageSize)

        return CGRect(
            x: min(point.x, 1 - width),
            y: min(point.y, 1 - height),
            width: width,
            height: height
        )
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

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

}

private enum AnnotationInteraction {
    case drawing(startPoint: CGPoint)
    case moving(id: AnnotationItem.ID, startPoint: CGPoint, originalItem: AnnotationItem)
    case resizing(id: AnnotationItem.ID, handle: AnnotationResizeHandle, originalItem: AnnotationItem)
}

private enum AnnotationCanvasCursor: Equatable {
    case arrow
    case placement
    case openHand
    case closedHand

    var nsCursor: NSCursor {
        switch self {
        case .arrow:
            .arrow
        case .placement:
            .annotationPlus
        case .openHand:
            .openHand
        case .closedHand:
            .closedHand
        }
    }
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
    @State private var hoveredLocation: CGPoint?
    @State private var currentCursor: AnnotationCanvasCursor = .arrow

    var body: some View {
        GeometryReader { proxy in
            let backgroundLayout = AnnotationBackgroundLayout.make(
                contentSize: model.imageSize,
                settings: model.backgroundSettings
            )
            let canvasFrame = aspectFitRect(imageSize: backgroundLayout.canvasSize, in: proxy.size)
            let displayLayout = backgroundLayout.scaled(to: canvasFrame)
            let imageFrame = displayLayout.imageFrame
            let localImageFrame = CGRect(origin: .zero, size: imageFrame.size)
            let cornerRadius = screenshotCornerRadius(for: imageFrame)

            ZStack(alignment: .topLeading) {
                if model.backgroundSettings.isEnabled {
                    AnnotationBackgroundStageFill(style: model.backgroundSettings.style)
                        .frame(width: displayLayout.canvasFrame.width, height: displayLayout.canvasFrame.height)
                        .position(x: displayLayout.canvasFrame.midX, y: displayLayout.canvasFrame.midY)
                }

                screenshotShadow(imageFrame: imageFrame, cornerRadius: cornerRadius)

                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: localImageFrame.midX, y: localImageFrame.midY)

                    ForEach(model.items) { item in
                        AnnotationItemView(
                            item: item,
                            image: image,
                            imageFrame: localImageFrame,
                            isSelected: item.id == model.selectedItemID,
                            isEditingText: item.id == model.editingTextItemID,
                            text: Binding(
                                get: { item.text },
                                set: { model.setText($0, for: item.id) }
                            ),
                            onCommitText: model.commitTextEditing,
                            onTextSizeChange: { size in
                                model.setTextViewContentSize(size, for: item.id, imageFrame: localImageFrame)
                            }
                        )
                    }

                    if let draftItem = model.draftItem {
                        AnnotationItemView(
                            item: draftItem,
                            image: image,
                            imageFrame: localImageFrame,
                            isSelected: false,
                            isEditingText: false,
                            text: .constant(draftItem.text),
                            onCommitText: {},
                            onTextSizeChange: { _ in }
                        )
                    }
                }
                .frame(width: imageFrame.width, height: imageFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(Rectangle())
                .position(x: imageFrame.midX, y: imageFrame.midY)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(interactionGesture(imageFrame: imageFrame))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredLocation = location
                    updateCursor(at: location, in: imageFrame)
                case .ended:
                    hoveredLocation = nil
                    setCursor(.arrow)
                }
            }
            .onChange(of: model.selectedTool) { _, _ in
                refreshCursor(in: imageFrame)
            }
            .onChange(of: model.itemIDs) { _, _ in
                refreshCursor(in: imageFrame)
            }
            .onChange(of: model.selectedItemID) { _, _ in
                refreshCursor(in: imageFrame)
            }
            .onDisappear {
                setCursor(.arrow)
            }
        }
    }

    @ViewBuilder
    private func screenshotShadow(imageFrame: CGRect, cornerRadius: CGFloat) -> some View {
        let settings = model.backgroundSettings
        let opacity = settings.isEnabled ? Double(settings.shadow) * 0.50 : 0.26
        if opacity > 0 {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .shadow(
                    color: .black.opacity(opacity),
                    radius: settings.isEnabled ? 16 + settings.shadow * 40 : 18,
                    x: 0,
                    y: settings.isEnabled ? 8 + settings.shadow * 26 : 8
                )
        }
    }

    private func screenshotCornerRadius(for imageFrame: CGRect) -> CGFloat {
        guard model.backgroundSettings.isEnabled else { return 0 }
        return model.backgroundSettings.cornerRadius * min(imageFrame.width, imageFrame.height)
    }

    private func interactionGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !hasActiveInteraction {
                    hasActiveInteraction = true
                    model.beginInteraction(at: value.startLocation, in: imageFrame)
                }

                model.updateInteraction(to: value.location, in: imageFrame)
                updateCursor(at: value.location, in: imageFrame)
            }
            .onEnded { value in
                model.endInteraction(at: value.location, in: imageFrame)
                hasActiveInteraction = false
                updateCursor(at: value.location, in: imageFrame)
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

    private func refreshCursor(in imageFrame: CGRect) {
        guard let hoveredLocation else { return }
        updateCursor(at: hoveredLocation, in: imageFrame)
    }

    private func updateCursor(at location: CGPoint, in imageFrame: CGRect) {
        guard model.containsImagePoint(location, in: imageFrame) else {
            setCursor(.arrow)
            return
        }

        if hasActiveInteraction {
            setCursor(model.isTransformingExistingAnnotation ? .closedHand : .placement)
        } else if model.hoveredAnnotation(at: location, in: imageFrame) != nil {
            setCursor(.openHand)
        } else {
            setCursor(.placement)
        }
    }

    private func setCursor(_ cursor: AnnotationCanvasCursor) {
        guard currentCursor != cursor else { return }
        currentCursor = cursor
        cursor.nsCursor.set()
    }
}

private struct AnnotationBackgroundStageFill: View {
    let style: AnnotationBackgroundStyle

    var body: some View {
        switch style {
        case .none:
            Color.clear

        case .solid(let color):
            color.color

        case .gradient(let gradient):
            LinearGradient(
                colors: gradient.colors.map(\.color),
                startPoint: gradient.startPoint,
                endPoint: gradient.endPoint
            )

        case .customWallpaper(let wallpaper):
            AnnotationCustomWallpaperPreview(wallpaper: wallpaper)
        }
    }
}

private struct AnnotationCustomWallpaperPreview: View {
    let wallpaper: AnnotationCustomWallpaper

    var body: some View {
        GeometryReader { proxy in
            if let image = ScreenshotImageLoader.downsampledImage(at: wallpaper.url, maxPixelSize: 900) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                Color.black
                    .overlay {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}

private struct AnnotationItemView: View {
    let item: AnnotationItem
    let image: NSImage
    let imageFrame: CGRect
    let isSelected: Bool
    let isEditingText: Bool
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
                    imageFrame: imageFrame,
                    viewBounds: viewBounds
                )
            } else if item.tool.isFilledShape {
                itemPath
                    .fill(fillStyle)
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
        case .rectangle, .filledRectangle:
            return Path(rect)

        case .pixelate, .blur:
            return Path(rect)

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

private struct AnnotationTextItemView: View {
    let item: AnnotationItem
    let text: Binding<String>
    let viewBounds: CGRect
    let imageFrameHeight: CGFloat
    let isEditing: Bool
    let onCommit: () -> Void
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        AnnotationTextBoxView(
            text: text,
            font: item.resolvedFont(size: fontSize),
            textColor: item.swatch.nsColor,
            shadow: AnnotationTextMetrics.textShadow,
            isUnderline: item.isUnderline,
            alignment: item.textAlignment,
            isEditing: isEditing,
            onCommit: onCommit,
            onSizeChange: onSizeChange
        )
        .frame(width: max(viewBounds.width, 1), height: max(viewBounds.height, 1))
        .position(x: viewBounds.midX, y: viewBounds.midY)
    }

    private var fontSize: CGFloat {
        AnnotationTextMetrics.viewFontSize(lineHeight: item.textLineHeight, imageFrameHeight: imageFrameHeight)
    }
}

private struct AnnotationTextBoxView: NSViewRepresentable {
    @Binding var text: String

    let font: NSFont
    let textColor: NSColor
    let shadow: NSShadow
    let isUnderline: Bool
    let alignment: NSTextAlignment
    let isEditing: Bool
    let onCommit: () -> Void
    let onSizeChange: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onSizeChange: onSizeChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isEditing
        textView.isSelectable = isEditing
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineBreakMode = .byClipping
        textView.autoresizingMask = [.width, .height]
        textView.insertionPointColor = NSColor.systemBlue
        textView.backgroundColor = .clear
        textView.string = text
        applyStyle(to: textView)

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.autoresizesSubviews = true

        context.coordinator.textView = textView

        if isEditing {
            DispatchQueue.main.async {
                self.updateTextViewFrame(textView, in: scrollView)
                textView.window?.makeFirstResponder(textView)
                self.reportSize(textView)
            }
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onSizeChange = onSizeChange

        textView.isEditable = isEditing
        textView.isSelectable = isEditing
        updateTextViewFrame(textView, in: scrollView)

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }

        applyStyle(to: textView)

        if isEditing && textView.window?.firstResponder !== textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        } else if !isEditing && textView.window?.firstResponder === textView {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(nil)
            }
        }

        DispatchQueue.main.async {
            self.reportSize(textView)
        }
    }

    private func reportSize(_ textView: NSTextView) {
        onSizeChange(Self.measuredTextSize(for: textView))
    }

    private func updateTextViewFrame(_ textView: NSTextView, in scrollView: NSScrollView) {
        let size = CGSize(
            width: max(scrollView.bounds.width, 1),
            height: max(scrollView.bounds.height, 1)
        )
        if textView.frame.size != size {
            textView.frame = CGRect(origin: .zero, size: size)
        }
        textView.textContainer?.containerSize = CGSize(
            width: size.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private static func measuredTextSize(for textView: NSTextView) -> CGSize {
        let font = textView.font ?? NSFont.systemFont(ofSize: AnnotationTextMetrics.minimumFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lineCount = CGFloat(AnnotationTextMetrics.lineCount(for: textView.string))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byClipping

        var attributes = textView.typingAttributes
        attributes[.font] = font
        attributes[.paragraphStyle] = paragraphStyle

        let measuredString = textView.string.isEmpty ? " " : textView.string
        let rect = NSAttributedString(string: measuredString, attributes: attributes).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(
            width: ceil(rect.width) + 2,
            height: max(ceil(rect.height), lineHeight * lineCount)
        )
    }

    private func applyStyle(to textView: NSTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .shadow: shadow
        ]
        if isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        textView.font = font
        textView.textColor = textColor
        textView.alignment = alignment
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = attributes
        textView.textContainer?.lineBreakMode = .byClipping

        guard textView.string.isEmpty == false else { return }

        let selectedRanges = textView.selectedRanges
        textView.textStorage?.setAttributes(
            attributes,
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        textView.selectedRanges = selectedRanges
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onSizeChange: (CGSize) -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onCommit: @escaping () -> Void, onSizeChange: @escaping (CGSize) -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onSizeChange = onSizeChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            reportSize(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            onCommit()
        }

        private func reportSize(_ textView: NSTextView) {
            onSizeChange(AnnotationTextBoxView.measuredTextSize(for: textView))
        }
    }
}

private extension NSCursor {
    static let annotationPlus: NSCursor = {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outline = NSBezierPath()
        outline.move(to: CGPoint(x: center.x - 6, y: center.y))
        outline.line(to: CGPoint(x: center.x + 6, y: center.y))
        outline.move(to: CGPoint(x: center.x, y: center.y - 6))
        outline.line(to: CGPoint(x: center.x, y: center.y + 6))
        NSColor.white.setStroke()
        outline.lineWidth = 5
        outline.lineCapStyle = .round
        outline.stroke()

        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: center.x - 6, y: center.y))
        plus.line(to: CGPoint(x: center.x + 6, y: center.y))
        plus.move(to: CGPoint(x: center.x, y: center.y - 6))
        plus.line(to: CGPoint(x: center.x, y: center.y + 6))
        NSColor.black.setStroke()
        plus.lineWidth = 2
        plus.lineCapStyle = .round
        plus.stroke()

        image.unlockFocus()
        return NSCursor(image: image, hotSpot: center)
    }()
}

private enum AnnotationTextMetrics {
    static let minimumFontSize: CGFloat = 9
    static let defaultNormalizedLineHeight: CGFloat = 0.06
    static let defaultFontName: String = "SF Pro"
    /// Maps normalized lineHeight to a screen font size given imageFrame height.
    static let fontScale: CGFloat = 0.72

    static var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 1.4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    /// Font size for the on-screen text view.
    static func viewFontSize(lineHeight: CGFloat, imageFrameHeight: CGFloat) -> CGFloat {
        max(lineHeight * imageFrameHeight * fontScale, minimumFontSize)
    }

    /// Font size for the final image render (uses pixel height).
    static func renderedFontSize(lineHeight: CGFloat, imagePixelHeight: CGFloat) -> CGFloat {
        max(lineHeight * imagePixelHeight * fontScale, minimumFontSize)
    }

    static func lineCount(for text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        return max(lines.count, 1)
    }

    /// Minimum normalized width for an empty text annotation (caret placeholder).
    static func minimumNormalizedWidth(lineHeight: CGFloat, imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 0.02 }
        let fontSize = renderedFontSize(lineHeight: lineHeight, imagePixelHeight: imageSize.height)
        return max(0.02, (fontSize * 0.5 + 4) / imageSize.width)
    }

    /// Resolve an NSFont from annotation properties.
    static func resolvedFont(name: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        // Try the family name first, fall back to system font.
        var descriptor: NSFontDescriptor
        if let family = NSFontManager.shared.availableMembers(ofFontFamily: name), !family.isEmpty {
            descriptor = NSFontDescriptor(fontAttributes: [.family: name]).withSize(size)
        } else {
            descriptor = NSFont.systemFont(ofSize: size).fontDescriptor
        }

        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            descriptor = descriptor.withSymbolicTraits(traits)
        }

        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
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

private struct TextSelectionFrame: View {
    var body: some View {
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 1.5)
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
            HStack(spacing: 6) {
                Circle()
                    .fill(selectedSwatch.color)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))

                Text(selectedSwatch.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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
                    .frame(width: 18, height: 12)

                Text("\(Int(strokeWidth))px")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
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

// MARK: - Inspector

private struct AnnotationEditorInspector: View {
    @Bindable var model: AnnotationEditorModel
    let onPickWallpaper: () -> Void
    let onSaveAs: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: Tools
                    VStack(alignment: .leading, spacing: 10) {
                        AnnotationInspectorSectionHeader("TOOLS")
                        AnnotationInspectorToolGrid(selectedTool: model.selectedTool) { tool in
                            model.selectTool(tool)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                    AnnotationInspectorDivider()

                    // MARK: Style
                    VStack(alignment: .leading, spacing: 10) {
                        AnnotationInspectorSectionHeader("STYLE")

                        AnnotationInspectorRow(title: "Color") {
                            AnnotationColorMenu(selectedSwatch: model.selectedSwatch) { swatch in
                                model.setSwatch(swatch)
                            }
                        }

                        AnnotationInspectorRow(title: "Stroke") {
                            AnnotationStrokeMenu(strokeWidth: model.strokeWidth) { strokeWidth in
                                model.setStrokeWidth(strokeWidth)
                            }
                        }

                        if model.selectedTool.isRedactionTool {
                            AnnotationBackgroundSlider(
                                title: "Density",
                                value: Binding(
                                    get: { model.redactionDensity },
                                    set: { model.setRedactionDensity($0) }
                                ),
                                range: 0.15...1
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)

                    if model.isTextStyleAvailable {
                        AnnotationInspectorDivider()

                        // MARK: Text
                        VStack(alignment: .leading, spacing: 10) {
                            AnnotationInspectorSectionHeader("TEXT")
                            AnnotationTextStyleControls(model: model)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }

                    AnnotationInspectorDivider()

                    // MARK: Background
                    AnnotationBackgroundInspector(
                        settings: Binding(
                            get: { model.backgroundSettings },
                            set: { model.backgroundSettings = $0 }
                        ),
                        onPickWallpaper: onPickWallpaper
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                Button(action: onSaveAs) {
                    Text("Save as...")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .controlSize(.large)

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .inspectorColumnWidth(280)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AnnotationInspectorSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}

private struct AnnotationInspectorDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
    }
}

private struct AnnotationInspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 2), count: 5
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTool == tool ? Color.accentColor : .primary.opacity(0.7))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedTool == tool ? Color.accentColor.opacity(0.15) : .clear)
                )
                .help(tool.title)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}

private struct AnnotationBackgroundInspector: View {
    @Binding var settings: AnnotationBackgroundSettings
    let onPickWallpaper: () -> Void

    private let gradientColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let wallpaperColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    private let alignmentColumns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // None button
            Button {
                settings.style = .none
            } label: {
                Text("None")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(settings.style == .none ? .white : .primary.opacity(0.7))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(settings.style == .none ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            )
            .padding(.bottom, 16)

            // Gradients
            backgroundSectionTitle("Gradients")
                .padding(.bottom, 8)
            LazyVGrid(columns: gradientColumns, spacing: 8) {
                ForEach(AnnotationBackgroundGradient.presets) { gradient in
                    Button {
                        settings.style = .gradient(gradient)
                    } label: {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(
                                colors: gradient.colors.map(\.color),
                                startPoint: gradient.startPoint,
                                endPoint: gradient.endPoint
                            ))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(settings.style == .gradient(gradient) ? Color.white.opacity(0.8) : Color.white.opacity(0.08), lineWidth: settings.style == .gradient(gradient) ? 2 : 0.5)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(gradient.title)
                }
            }
            .padding(.bottom, 16)

            // Wallpapers
            backgroundSectionTitle("Wallpapers")
                .padding(.bottom, 8)
            LazyVGrid(columns: wallpaperColumns, spacing: 8) {
                if let customWallpaper {
                    wallpaperButton(
                        style: .customWallpaper(AnnotationCustomWallpaper(url: customWallpaper.url)),
                        title: customWallpaper.title
                    ) {
                        AnnotationCustomWallpaperPreview(wallpaper: AnnotationCustomWallpaper(url: customWallpaper.url))
                    }
                }

                Button(action: onPickWallpaper) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Choose wallpaper")
            }
            .padding(.bottom, 16)

            // Plain color
            backgroundSectionTitle("Plain color")
                .padding(.bottom, 8)
            LazyVGrid(columns: colorColumns, spacing: 8) {
                ForEach(AnnotationBackgroundColor.plainPresets) { color in
                    Button {
                        settings.style = .solid(color)
                    } label: {
                        Circle()
                            .fill(color.color)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                Circle()
                                    .stroke(settings.style == .solid(color) ? Color.white.opacity(0.9) : Color.white.opacity(0.1), lineWidth: settings.style == .solid(color) ? 2 : 0.5)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                }
            }
            .padding(.bottom, 18)

            // Padding - full width
            AnnotationBackgroundSlider(
                title: "Padding",
                value: $settings.padding,
                range: 0.04...0.45
            )
            .padding(.bottom, 14)

            // Shadow + Corners side by side
            HStack(spacing: 12) {
                AnnotationBackgroundSlider(
                    title: "Shadow",
                    value: $settings.shadow,
                    range: 0...1,
                    compact: true
                )

                AnnotationBackgroundSlider(
                    title: "Corners",
                    value: $settings.cornerRadius,
                    range: 0...0.12,
                    compact: true
                )
            }
            .padding(.bottom, 14)

            // Alignment + Ratio side by side
            HStack(alignment: .top, spacing: 12) {
                // Alignment
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alignment")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: alignmentColumns, spacing: 4) {
                        ForEach(AnnotationBackgroundAlignment.allCases) { alignment in
                            Button {
                                settings.alignment = alignment
                            } label: {
                                AlignmentGlyph(alignment: alignment, isSelected: settings.alignment == alignment)
                            }
                            .buttonStyle(.plain)
                            .help(alignment.title)
                        }
                    }
                }

                Spacer()

                // Ratio
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ratio")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $settings.aspectRatio) {
                        ForEach(AnnotationBackgroundAspectRatio.allCases) { ratio in
                            Text(ratio.title).tag(ratio)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    private var customWallpaper: AnnotationCustomWallpaper? {
        settings.customWallpaper
    }

    private func wallpaperButton<Content: View>(
        style: AnnotationBackgroundStyle,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            if case .customWallpaper(let wallpaper) = style {
                settings.customWallpaper = wallpaper
            }
            settings.style = style
        } label: {
            content()
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(settings.style == style ? Color.white.opacity(0.8) : Color.white.opacity(0.08), lineWidth: settings.style == style ? 2 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func backgroundSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct AnnotationBackgroundSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var compact: Bool = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(value: $value, in: range)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Slider(value: $value, in: range)
                    .controlSize(.small)
                    .tint(.accentColor)
            }
        }
    }
}

private struct AlignmentGlyph: View {
    let alignment: AnnotationBackgroundAlignment
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                )

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                .frame(width: 10, height: 7)
                .position(markerPosition)
        }
        .frame(width: 28, height: 22)
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var markerPosition: CGPoint {
        CGPoint(
            x: 6 + alignment.xFactor * 16,
            y: 5 + alignment.yFactor * 12
        )
    }
}

// MARK: - Text Style Controls

private struct AnnotationTextStyleControls: View {
    @Bindable var model: AnnotationEditorModel
    @State private var fontSizeText = ""
    @FocusState private var isFontSizeFieldFocused: Bool

    private let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted()
    }()

    var body: some View {
        VStack(spacing: 10) {
            // Font family + color swatch
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { model.selectedTextFontName },
                    set: { model.selectedTextFontName = $0 }
                )) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Menu {
                    ForEach(AnnotationSwatch.allCases) { swatch in
                        Button {
                            model.setSwatch(swatch)
                        } label: {
                            Label(swatch.title, systemImage: model.selectedSwatch == swatch ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(model.selectedSwatch.color)
                        .frame(width: 28, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }

            // Font size + style toggles
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Button {
                        adjustFontSize(by: -1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Divider().frame(height: 14)

                    TextField("", text: $fontSizeText)
                        .focused($isFontSizeFieldFocused)
                        .onSubmit(commitFontSizeText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 32)

                    Divider().frame(height: 14)

                    Button {
                        adjustFontSize(by: 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 22, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )

                Spacer()

                HStack(spacing: 0) {
                    styleToggle(
                        label: "B",
                        font: .system(size: 12, weight: .bold),
                        isActive: model.selectedTextIsBold
                    ) {
                        model.selectedTextIsBold.toggle()
                    }

                    Divider().frame(height: 14)

                    styleToggle(
                        label: "I",
                        font: .system(size: 12, weight: .regular, design: .serif).italic(),
                        isActive: model.selectedTextIsItalic
                    ) {
                        model.selectedTextIsItalic.toggle()
                    }

                    Divider().frame(height: 14)

                    styleToggle(
                        label: "U",
                        font: .system(size: 12, weight: .regular),
                        isActive: model.selectedTextIsUnderline,
                        underline: true
                    ) {
                        model.selectedTextIsUnderline.toggle()
                    }
                }
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                )
            }

            // Text alignment
            HStack(spacing: 0) {
                alignmentButton(.left, icon: "text.alignleft")
                alignmentButton(.center, icon: "text.aligncenter")
                alignmentButton(.right, icon: "text.alignright")
                alignmentButton(.justified, icon: "text.justify.leading")
            }
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncFontSizeText)
        .onDisappear(perform: commitFontSizeText)
        .onChange(of: model.selectedTextFontSize) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: model.selectedItemID) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: isFontSizeFieldFocused) { _, isFocused in
            if isFocused {
                syncFontSizeText()
            } else {
                commitFontSizeText()
            }
        }
    }

    private func syncFontSizeText() {
        fontSizeText = String(Int(model.selectedTextFontSize.rounded()))
    }

    private func commitFontSizeText() {
        let trimmedText = fontSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmedText) else {
            syncFontSizeText()
            return
        }

        let clampedSize = max(size.rounded(), Double(AnnotationTextMetrics.minimumFontSize))
        model.selectedTextFontSize = CGFloat(clampedSize)
        fontSizeText = String(Int(clampedSize))
    }

    private func adjustFontSize(by delta: CGFloat) {
        commitFontSizeText()
        let size = max(model.selectedTextFontSize + delta, AnnotationTextMetrics.minimumFontSize)
        model.selectedTextFontSize = size
        syncFontSizeText()
    }

    private func styleToggle(
        label: String,
        font: Font,
        isActive: Bool,
        underline: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .underline(underline)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary.opacity(0.7))
        .background(isActive ? Color.accentColor.opacity(0.12) : .clear)
    }

    private func alignmentButton(_ alignment: NSTextAlignment, icon: String) -> some View {
        Button {
            model.selectedTextAlignment = alignment
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.selectedTextAlignment == alignment ? Color.accentColor : .primary.opacity(0.5))
        .background(model.selectedTextAlignment == alignment ? Color.accentColor.opacity(0.12) : .clear)
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

            if Self.isEditingText(in: self.window) {
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

    private static func isEditingText(in window: NSWindow?) -> Bool {
        window?.firstResponder is NSTextView
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
    var text: String
    var textLineHeight: CGFloat
    var fontName: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var textAlignment: NSTextAlignment

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        rect: CGRect,
        points: [CGPoint] = [],
        swatch: AnnotationSwatch,
        strokeWidth: CGFloat,
        redactionDensity: CGFloat = 0.55,
        text: String = "",
        textLineHeight: CGFloat = AnnotationTextMetrics.defaultNormalizedLineHeight,
        fontName: String = AnnotationTextMetrics.defaultFontName,
        isBold: Bool = true,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        textAlignment: NSTextAlignment = .left
    ) {
        self.id = id
        self.tool = tool
        self.rect = rect
        self.points = points
        self.swatch = swatch
        self.strokeWidth = strokeWidth
        self.redactionDensity = redactionDensity
        self.text = text
        self.textLineHeight = textLineHeight
        self.fontName = fontName
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.textAlignment = textAlignment
    }

    /// Build the NSFont for this text annotation at the given point size.
    func resolvedFont(size: CGFloat) -> NSFont {
        AnnotationTextMetrics.resolvedFont(
            name: fontName, size: size, bold: isBold, italic: isItalic
        )
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
        case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur, .text:
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

    func isRenderable(minimumSize: CGFloat, allowEmptyText: Bool = false) -> Bool {
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
        case .text:
            return bounds.width >= minimumSize
                && bounds.height >= minimumSize
                && (allowEmptyText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

        case .rectangle, .filledRectangle, .pixelate, .blur, .text:
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
    case text

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
        case .text:
            "Text"
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
    static func renderToTemporaryFile(
        sourceURL: URL,
        items: [AnnotationItem],
        backgroundSettings: AnnotationBackgroundSettings = AnnotationBackgroundSettings()
    ) throws -> URL {
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenShot_Annotated_\(UUID().uuidString.prefix(6)).png")
        try render(
            sourceURL: sourceURL,
            items: items,
            backgroundSettings: backgroundSettings,
            destinationURL: destinationURL,
            contentType: .png
        )
        return destinationURL
    }

    static func render(
        sourceURL: URL,
        items: [AnnotationItem],
        backgroundSettings: AnnotationBackgroundSettings = AnnotationBackgroundSettings(),
        destinationURL: URL,
        contentType: UTType
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let annotatedImage = try renderAnnotatedImage(sourceURL: sourceURL, items: items, colorSpace: colorSpace)
        let renderedImage = try AnnotationBackgroundRenderer.compose(
            annotatedImage: annotatedImage,
            settings: backgroundSettings,
            colorSpace: colorSpace
        )

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

    private static func renderAnnotatedImage(
        sourceURL: URL,
        items: [AnnotationItem],
        colorSpace: CGColorSpace
    ) throws -> CGImage {
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

            case .text:
                drawText(
                    item,
                    in: renderedRect(item.bounds, width: width, height: height),
                    canvasSize: CGSize(width: width, height: height),
                    context: context
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

        return renderedImage
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

    private static func drawText(
        _ item: AnnotationItem,
        in rect: CGRect,
        canvasSize: CGSize,
        context: CGContext
    ) {
        let text = item.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty,
              rect.width > 1,
              rect.height > 1 else {
            return
        }

        let fontSize = AnnotationTextMetrics.renderedFontSize(
            lineHeight: item.textLineHeight,
            imagePixelHeight: canvasSize.height
        )
        let font = item.resolvedFont(size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = item.textAlignment
        paragraphStyle.lineBreakMode = .byClipping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.swatch.nsColor,
            .paragraphStyle: paragraphStyle,
            .shadow: AnnotationTextMetrics.textShadow
        ]
        if item.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let attributedText = NSAttributedString(string: text, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributedText.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        NSGraphicsContext.restoreGraphicsState()
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
