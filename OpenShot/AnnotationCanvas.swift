//
//  AnnotationCanvas.swift
//  OpenShot
//

import AppKit
import SwiftUI

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

struct AnnotationCanvas: View {
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
            let boundaryFrame = model.backgroundSettings.isEnabled ? displayLayout.canvasFrame : imageFrame
            let allowedBounds = model.annotationBounds(for: imageFrame, boundaryFrame: boundaryFrame)
            let cornerRadii = screenshotCornerRadii(for: imageFrame)
            let clipCorners = RectangleCornerRadii(
                topLeading: cornerRadii.topLeft,
                bottomLeading: cornerRadii.bottomLeft,
                bottomTrailing: cornerRadii.bottomRight,
                topTrailing: cornerRadii.topRight
            )

            ZStack(alignment: .topLeading) {
                if model.backgroundSettings.isEnabled {
                    AnnotationBackgroundStageFill(style: model.backgroundSettings.style)
                        .frame(width: displayLayout.canvasFrame.width, height: displayLayout.canvasFrame.height)
                        .position(x: displayLayout.canvasFrame.midX, y: displayLayout.canvasFrame.midY)
                }

                screenshotShadow(imageFrame: imageFrame, cornerRadii: clipCorners)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .clipShape(UnevenRoundedRectangle(cornerRadii: clipCorners, style: .continuous))
                    .position(x: imageFrame.midX, y: imageFrame.midY)

                ForEach(model.items) { item in
                    AnnotationItemView(
                        item: item,
                        image: image,
                        originalImageSize: model.imageSize,
                        imageFrame: imageFrame,
                        isSelected: model.selectedItemIDs.contains(item.id),
                        showsResizeHandles: model.selectionCount == 1,
                        isEditingText: item.id == model.editingTextItemID,
                        text: Binding(
                            get: { item.text },
                            set: { model.setText($0, for: item.id) }
                        ),
                        onCommitText: model.commitTextEditing,
                        onTextSizeChange: { size in
                            model.setTextViewContentSize(size, for: item.id, imageFrame: imageFrame, allowedBounds: allowedBounds)
                        }
                    )
                }

                if let draftItem = model.draftItem {
                    AnnotationItemView(
                        item: draftItem,
                        image: image,
                        originalImageSize: model.imageSize,
                        imageFrame: imageFrame,
                        isSelected: false,
                        showsResizeHandles: false,
                        isEditingText: false,
                        text: .constant(draftItem.text),
                        onCommitText: {},
                        onTextSizeChange: { _ in }
                    )
                }

                if let selectionRect = model.selectionRect {
                    AnnotationMarqueeSelectionView()
                        .frame(
                            width: max(viewRect(selectionRect, in: imageFrame).width, 1),
                            height: max(viewRect(selectionRect, in: imageFrame).height, 1)
                        )
                        .position(
                            x: viewRect(selectionRect, in: imageFrame).midX,
                            y: viewRect(selectionRect, in: imageFrame).midY
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(interactionGesture(imageFrame: imageFrame, boundaryFrame: boundaryFrame))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoveredLocation = location
                    updateCursor(at: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                case .ended:
                    hoveredLocation = nil
                    setCursor(.arrow)
                }
            }
            .onChange(of: model.selectedTool) { _, _ in
                refreshCursor(imageFrame: imageFrame, boundaryFrame: boundaryFrame)
            }
            .onChange(of: model.itemIDs) { _, _ in
                refreshCursor(imageFrame: imageFrame, boundaryFrame: boundaryFrame)
            }
            .onChange(of: model.selectedItemIDs) { _, _ in
                refreshCursor(imageFrame: imageFrame, boundaryFrame: boundaryFrame)
            }
            .onDisappear {
                setCursor(.arrow)
            }
        }
    }

    @ViewBuilder
    private func screenshotShadow(imageFrame: CGRect, cornerRadii: RectangleCornerRadii) -> some View {
        let settings = model.backgroundSettings
        let opacity = settings.isEnabled ? Double(settings.shadow) * 0.50 : 0.26
        if opacity > 0 {
            UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
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

    private func screenshotCornerRadii(for imageFrame: CGRect) -> (topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        guard model.backgroundSettings.isEnabled else { return (0, 0, 0, 0) }
        let base = model.backgroundSettings.cornerRadius * min(imageFrame.width, imageFrame.height)
        let m = model.backgroundSettings.alignment.cornerRadiusMultipliers
        return (base * m.topLeft, base * m.topRight, base * m.bottomLeft, base * m.bottomRight)
    }

    private func interactionGesture(imageFrame: CGRect, boundaryFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !hasActiveInteraction {
                    hasActiveInteraction = true
                    model.beginInteraction(at: value.startLocation, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                }

                model.updateInteraction(to: value.location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                updateCursor(at: value.location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
            }
            .onEnded { value in
                model.endInteraction(at: value.location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                hasActiveInteraction = false
                updateCursor(at: value.location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
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

    private func viewRect(_ rect: CGRect, in imageFrame: CGRect) -> CGRect {
        CGRect(
            x: imageFrame.minX + rect.minX * imageFrame.width,
            y: imageFrame.minY + rect.minY * imageFrame.height,
            width: rect.width * imageFrame.width,
            height: rect.height * imageFrame.height
        )
    }

    private func refreshCursor(imageFrame: CGRect, boundaryFrame: CGRect) {
        guard let hoveredLocation else { return }
        updateCursor(at: hoveredLocation, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
    }

    private func updateCursor(at location: CGPoint, imageFrame: CGRect, boundaryFrame: CGRect) {
        guard model.containsInteractionPoint(location, imageFrame: imageFrame, boundaryFrame: boundaryFrame) else {
            setCursor(.arrow)
            return
        }

        if hasActiveInteraction {
            setCursor(model.isTransformingExistingAnnotation ? .closedHand : .placement)
        } else if model.hoveredAnnotation(at: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame) != nil {
            setCursor(.openHand)
        } else if model.selectedTool == .select {
            setCursor(.arrow)
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

private struct AnnotationMarqueeSelectionView: View {
    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.08))
            .overlay {
                Rectangle()
                    .stroke(
                        Color.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
            }
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

struct AnnotationCustomWallpaperPreview: View {
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
