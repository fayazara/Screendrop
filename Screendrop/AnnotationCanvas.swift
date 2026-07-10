//
//  AnnotationCanvas.swift
//  Screendrop
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
    let onEditorInteraction: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var hasActiveInteraction = false
    @State private var hoveredLocation: CGPoint?
    @State private var currentCursor: AnnotationCanvasCursor = .arrow
    @State private var progressivelyBlurredImage: NSImage?
    @State private var progressivelyBlurredSourceID: ObjectIdentifier?

    var body: some View {
        GeometryReader { proxy in
            let backgroundLayout = AnnotationBackgroundLayout.make(
                contentSize: model.imageSize,
                settings: model.backgroundSettings
            )
            let canvasFrame = model.displayCanvasFrame(in: proxy.size)
            let displayLayout = backgroundLayout.scaled(to: canvasFrame)
            let imageFrame = displayLayout.imageFrame
            let boundaryFrame = model.backgroundSettings.usesCanvasLayout ? displayLayout.canvasFrame : imageFrame
            let allowedBounds = model.annotationBounds(for: imageFrame, boundaryFrame: boundaryFrame)
            let cornerRadii = screenshotCornerRadii(for: imageFrame)
            let clipCorners = RectangleCornerRadii(
                topLeading: cornerRadii.topLeft,
                bottomLeading: cornerRadii.bottomLeft,
                bottomTrailing: cornerRadii.bottomRight,
                topTrailing: cornerRadii.topRight
            )
            let effectiveCamera = model.isCropping || model.editingTextItemID != nil
                ? AnnotationCameraSettings()
                : model.backgroundSettings.camera
            let projection = AnnotationCameraGeometry.projection(
                sourceRect: CGRect(origin: .zero, size: proxy.size),
                imageRect: imageFrame,
                canvasSize: displayLayout.canvasFrame.size,
                settings: effectiveCamera
            )
            let blurPreviewKey = AnnotationProgressiveBlurPreviewKey(
                image: image,
                settings: model.backgroundSettings.progressiveBlur
            )
            let usesSceneBlur = model.backgroundSettings.progressiveBlur.isActive
                && model.backgroundSettings.progressiveBlur.edgeMode == .bleed
                && !model.isCropping
                && model.editingTextItemID == nil
            let displayedImage = model.backgroundSettings.progressiveBlur.isActive
                && model.backgroundSettings.progressiveBlur.edgeMode == .clipped
                && !model.isCropping
                && progressivelyBlurredSourceID == ObjectIdentifier(image)
                ? progressivelyBlurredImage ?? image
                : image

            ZStack(alignment: .topLeading) {
                sceneStage(
                    viewportSize: proxy.size,
                    canvasFrame: displayLayout.canvasFrame,
                    backgroundStyle: model.backgroundSettings.style,
                    showsBackground: model.backgroundSettings.isEnabled,
                    imageFrame: imageFrame,
                    allowedBounds: allowedBounds,
                    clipCorners: clipCorners,
                    displayedImage: displayedImage,
                    projection: projection,
                    clipsForegroundToCanvas: effectiveCamera.hasEffect || usesSceneBlur,
                    sceneBlurSettings: usesSceneBlur
                        ? model.backgroundSettings.progressiveBlur
                        : nil
                )

                if model.backgroundSettings.watermark.isVisible {
                    AnnotationWatermarkOverlay(
                        settings: model.backgroundSettings.watermark,
                        fontScale: displayLayout.scale
                    )
                    .frame(width: boundaryFrame.width, height: boundaryFrame.height)
                    .position(x: boundaryFrame.midX, y: boundaryFrame.midY)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named(AnnotationCanvasCoordinateSpace.name))
            .contentShape(Rectangle())
            .background(
                AnnotationCanvasInputHandler(
                    onPan: { dx, dy in model.panBy(dx: dx, dy: dy) },
                    onZoom: { factor in model.zoomBy(factor) }
                )
            )
            .gesture(interactionGesture(
                imageFrame: imageFrame,
                boundaryFrame: boundaryFrame,
                projection: projection,
                visibleCanvasFrame: effectiveCamera.hasEffect ? displayLayout.canvasFrame : nil
            ))
            .onAppear {
                model.viewportSize = proxy.size
                model.displayScale = displayScale
            }
            .onChange(of: proxy.size) { _, newValue in
                model.viewportSize = newValue
            }
            .onChange(of: displayScale) { _, newValue in
                model.displayScale = newValue
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if effectiveCamera.hasEffect && !displayLayout.canvasFrame.contains(location) {
                        hoveredLocation = nil
                        setCursor(.arrow)
                        return
                    }
                    let mappedLocation = projection.unproject(location)
                    hoveredLocation = mappedLocation
                    updateCursor(at: mappedLocation, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
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
            .task(id: blurPreviewKey) {
                await updateProgressiveBlurPreview(
                    for: image,
                    settings: model.backgroundSettings.progressiveBlur
                )
            }
        }
    }

    @ViewBuilder
    private func sceneStage(
        viewportSize: CGSize,
        canvasFrame: CGRect,
        backgroundStyle: AnnotationBackgroundStyle,
        showsBackground: Bool,
        imageFrame: CGRect,
        allowedBounds: CGRect,
        clipCorners: RectangleCornerRadii,
        displayedImage: NSImage,
        projection: AnnotationCameraProjection,
        clipsForegroundToCanvas: Bool,
        sceneBlurSettings: AnnotationProgressiveBlurSettings?
    ) -> some View {
        if let sceneBlurSettings {
            let blurRadius = max(
                0.5,
                sceneBlurSettings.strength * min(canvasFrame.width, canvasFrame.height) / 1000
            )

            ZStack(alignment: .topLeading) {
                sceneContent(
                    viewportSize: viewportSize,
                    canvasFrame: canvasFrame,
                    backgroundStyle: backgroundStyle,
                    showsBackground: showsBackground,
                    imageFrame: imageFrame,
                    allowedBounds: allowedBounds,
                    clipCorners: clipCorners,
                    displayedImage: displayedImage,
                    projection: projection,
                    clipsForegroundToCanvas: true
                )

                ForEach(0..<3, id: \.self) { level in
                    sceneContent(
                        viewportSize: viewportSize,
                        canvasFrame: canvasFrame,
                        backgroundStyle: backgroundStyle,
                        showsBackground: showsBackground,
                        imageFrame: imageFrame,
                        allowedBounds: allowedBounds,
                        clipCorners: clipCorners,
                        displayedImage: displayedImage,
                        projection: projection,
                        clipsForegroundToCanvas: true
                    )
                    .compositingGroup()
                    .blur(radius: blurRadius * CGFloat(level + 1) / 3)
                    .mask {
                        progressiveBlurBlendMask(
                            settings: sceneBlurSettings,
                            canvasFrame: canvasFrame,
                            level: level,
                            levelCount: 3
                        )
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask {
                Rectangle()
                    .frame(width: canvasFrame.width, height: canvasFrame.height)
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
            }
        } else {
            sceneContent(
                viewportSize: viewportSize,
                canvasFrame: canvasFrame,
                backgroundStyle: backgroundStyle,
                showsBackground: showsBackground,
                imageFrame: imageFrame,
                allowedBounds: allowedBounds,
                clipCorners: clipCorners,
                displayedImage: displayedImage,
                projection: projection,
                clipsForegroundToCanvas: clipsForegroundToCanvas
            )
        }
    }

    private func sceneContent(
        viewportSize: CGSize,
        canvasFrame: CGRect,
        backgroundStyle: AnnotationBackgroundStyle,
        showsBackground: Bool,
        imageFrame: CGRect,
        allowedBounds: CGRect,
        clipCorners: RectangleCornerRadii,
        displayedImage: NSImage,
        projection: AnnotationCameraProjection,
        clipsForegroundToCanvas: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if showsBackground {
                AnnotationBackgroundStageFill(style: backgroundStyle)
                    .frame(width: canvasFrame.width, height: canvasFrame.height)
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
            }

            transformedCameraForeground(
                viewportSize: viewportSize,
                imageFrame: imageFrame,
                allowedBounds: allowedBounds,
                clipCorners: clipCorners,
                displayedImage: displayedImage,
                projection: projection,
                canvasFrame: canvasFrame,
                clipsToCanvas: clipsForegroundToCanvas
            )
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
    }

    private func transformedCameraForeground(
        viewportSize: CGSize,
        imageFrame: CGRect,
        allowedBounds: CGRect,
        clipCorners: RectangleCornerRadii,
        displayedImage: NSImage,
        projection: AnnotationCameraProjection,
        canvasFrame: CGRect,
        clipsToCanvas: Bool
    ) -> some View {
        cameraForeground(
            viewportSize: viewportSize,
            imageFrame: imageFrame,
            allowedBounds: allowedBounds,
            clipCorners: clipCorners,
            displayedImage: displayedImage
        )
        .projectionEffect(projection.swiftUITransform)
        .mask {
            if clipsToCanvas {
                Rectangle()
                    .frame(width: canvasFrame.width, height: canvasFrame.height)
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
            } else {
                Rectangle()
            }
        }
    }

    private func progressiveBlurBlendMask(
        settings: AnnotationProgressiveBlurSettings,
        canvasFrame: CGRect,
        level: Int,
        levelCount: Int
    ) -> some View {
        AnnotationProgressiveBlurBlendMask(
            settings: settings,
            level: level,
            levelCount: levelCount
        )
        .frame(width: canvasFrame.width, height: canvasFrame.height)
        .position(x: canvasFrame.midX, y: canvasFrame.midY)
    }

    private func cameraForeground(
        viewportSize: CGSize,
        imageFrame: CGRect,
        allowedBounds: CGRect,
        clipCorners: RectangleCornerRadii,
        displayedImage: NSImage
    ) -> some View {
        ZStack(alignment: .topLeading) {
            screenshotShadow(imageFrame: imageFrame, cornerRadii: clipCorners)

            screenshot(
                displayedImage,
                imageFrame: imageFrame,
                clipCorners: clipCorners
            )

            ForEach(model.items) { item in
                AnnotationItemView(
                    item: item,
                    image: displayedImage,
                    originalImageSize: model.imageSize,
                    imageFrame: imageFrame,
                    isSelected: model.selectedItemIDs.contains(item.id),
                    showsResizeHandles: model.selectionCount == 1,
                    isEditingText: item.id == model.editingTextItemID,
                    allowsRedactionPreviewCaching: !(model.isTransformingExistingAnnotation && model.selectedItemIDs.contains(item.id)),
                    text: Binding(
                        get: { item.text },
                        set: { model.setText($0, for: item.id) }
                    ),
                    onCommitText: model.commitTextEditing,
                    onTextSizeChange: { size in
                        model.setTextViewContentSize(
                            size,
                            for: item.id,
                            imageFrame: imageFrame,
                            allowedBounds: allowedBounds
                        )
                    }
                )
            }

            if let draftItem = model.draftItem {
                AnnotationItemView(
                    item: draftItem,
                    image: displayedImage,
                    originalImageSize: model.imageSize,
                    imageFrame: imageFrame,
                    isSelected: false,
                    showsResizeHandles: false,
                    isEditingText: false,
                    allowsRedactionPreviewCaching: false,
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

            if model.isCropping {
                AnnotationCropOverlay(model: model, imageFrame: imageFrame)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
    }

    private func screenshot(
        _ displayedImage: NSImage,
        imageFrame: CGRect,
        clipCorners: RectangleCornerRadii
    ) -> some View {
        Image(nsImage: displayedImage)
            .resizable()
            .frame(width: imageFrame.width, height: imageFrame.height)
            .clipShape(UnevenRoundedRectangle(cornerRadii: clipCorners, style: .continuous))
            .position(x: imageFrame.midX, y: imageFrame.midY)
    }

    @MainActor
    private func updateProgressiveBlurPreview(
        for sourceImage: NSImage,
        settings: AnnotationProgressiveBlurSettings
    ) async {
        guard settings.isActive, settings.edgeMode == .clipped else {
            progressivelyBlurredImage = nil
            progressivelyBlurredSourceID = nil
            return
        }

        // Coalesce high-frequency focus-pad and slider updates before entering
        // the serialized Core Image worker.
        do {
            try await Task.sleep(for: .milliseconds(12))
        } catch {
            return
        }
        guard !Task.isCancelled,
              let source = sourceImage.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
              ) else {
            return
        }

        let colorSpace = source.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let output = await AnnotationProgressiveBlurPreviewWorker.shared.render(
            source: source,
            settings: settings,
            colorSpace: colorSpace
        ) else {
            if !Task.isCancelled {
                progressivelyBlurredImage = nil
                progressivelyBlurredSourceID = nil
            }
            return
        }
        guard !Task.isCancelled else {
            return
        }

        progressivelyBlurredImage = NSImage(cgImage: output, size: sourceImage.size)
        progressivelyBlurredSourceID = ObjectIdentifier(sourceImage)
    }

    @ViewBuilder
    private func screenshotShadow(imageFrame: CGRect, cornerRadii: RectangleCornerRadii) -> some View {
        let settings = model.backgroundSettings
        let opacity = settings.usesCanvasLayout ? Double(settings.shadow) * 0.50 : 0.26
        if (settings.isEnabled || settings.camera.hasEffect) && opacity > 0 {
            UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .shadow(
                    color: .black.opacity(opacity),
                    radius: settings.usesCanvasLayout ? 16 + settings.shadow * 40 : 18,
                    x: 0,
                    y: settings.usesCanvasLayout ? 8 + settings.shadow * 26 : 8
                )
        }
    }

    private func screenshotCornerRadii(for imageFrame: CGRect) -> (topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        guard model.backgroundSettings.usesCanvasLayout else { return (0, 0, 0, 0) }
        let base = model.backgroundSettings.cornerRadius * min(imageFrame.width, imageFrame.height)
        let m = model.backgroundSettings.effectiveCanvasAlignment.cornerRadiusMultipliers
        return (base * m.topLeft, base * m.topRight, base * m.bottomLeft, base * m.bottomRight)
    }

    private func interactionGesture(
        imageFrame: CGRect,
        boundaryFrame: CGRect,
        projection: AnnotationCameraProjection,
        visibleCanvasFrame: CGRect?
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard hasActiveInteraction || visibleCanvasFrame?.contains(value.startLocation) != false else {
                    return
                }
                let startLocation = projection.unproject(value.startLocation)
                let location = projection.unproject(value.location)
                if !hasActiveInteraction {
                    hasActiveInteraction = true
                    onEditorInteraction()
                    model.beginInteraction(at: startLocation, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                }

                model.updateInteraction(to: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                updateCursor(at: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
            }
            .onEnded { value in
                guard hasActiveInteraction else { return }
                let location = projection.unproject(value.location)
                model.endInteraction(at: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
                hasActiveInteraction = false
                updateCursor(at: location, imageFrame: imageFrame, boundaryFrame: boundaryFrame)
            }
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
        guard !model.isCropping else {
            setCursor(.arrow)
            return
        }
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

/// Captures scroll-wheel and pinch-magnify events over the canvas region to
/// drive panning and zooming, without interfering with SwiftUI drawing gestures.
private struct AnnotationCanvasInputHandler: NSViewRepresentable {
    let onPan: (CGFloat, CGFloat) -> Void
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.onPan = onPan
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: InputView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
    }

    final class InputView: NSView {
        var onPan: ((CGFloat, CGFloat) -> Void)?
        var onZoom: ((CGFloat) -> Void)?

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitor()
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        private func installMonitor() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self,
                      let window = self.window,
                      window.isKeyWindow,
                      event.window == window else {
                    return event
                }

                if window.firstResponder is NSTextView {
                    return event
                }

                let pointInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(pointInView) else {
                    return event
                }

                switch event.type {
                case .magnify:
                    self.onZoom?(1 + event.magnification)
                    return nil
                case .scrollWheel:
                    if event.modifierFlags.intersection([.command, .option]).isEmpty {
                        self.onPan?(event.scrollingDeltaX, event.scrollingDeltaY)
                    } else {
                        self.onZoom?(1 + event.scrollingDeltaY * 0.0025)
                    }
                    return nil
                default:
                    return event
                }
            }
        }
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

private struct AnnotationProgressiveBlurBlendMask: View {
    let settings: AnnotationProgressiveBlurSettings
    let level: Int
    let levelCount: Int

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let focus = CGPoint(
                x: min(max(settings.focusPosition.x, 0), 1) * size.width,
                y: min(max(settings.focusPosition.y, 0), 1) * size.height
            )

            switch settings.mode {
            case .radial:
                radialMask(focus: focus, size: size)
            case .directional:
                directionalMask(focus: focus, size: size)
            }
        }
    }

    private func radialMask(focus: CGPoint, size: CGSize) -> some View {
        let shortestEdge = min(size.width, size.height)
        let minimumRadius = shortestEdge * 0.04
        let maximumRadius = corners(in: size).map { corner in
            hypot(corner.x - focus.x, corner.y - focus.y)
        }.max() ?? minimumRadius
        let focusRadius = minimumRadius
            + min(max(settings.focusSize, 0), 1) * max(0, maximumRadius - minimumRadius)
        let transitionWidth = shortestEdge * (0.10 + min(max(settings.falloff, 0), 1) * 0.48)
        let transitionStart = focusRadius + transitionWidth * levelStart
        let transitionEnd = focusRadius + transitionWidth * levelEnd

        return RadialGradient(
            colors: [sharpMaskColor, blurMaskColor],
            center: UnitPoint(
                x: focus.x / max(size.width, 1),
                y: focus.y / max(size.height, 1)
            ),
            startRadius: transitionStart,
            endRadius: transitionEnd
        )
    }

    private func directionalMask(focus: CGPoint, size: CGSize) -> some View {
        let radians = settings.directionDegrees * .pi / 180
        let normal = CGVector(dx: -sin(radians), dy: cos(radians))
        let distances = corners(in: size).map { corner in
            (corner.x - focus.x) * normal.dx + (corner.y - focus.y) * normal.dy
        }
        let minimumDistance = distances.min() ?? -1
        let maximumDistance = distances.max() ?? 1
        let distanceRange = max(maximumDistance - minimumDistance, 1)
        let shortestEdge = min(size.width, size.height)
        let minimumHalfWidth = shortestEdge * 0.025
        let maximumHalfWidth = distances.map(abs).max() ?? minimumHalfWidth
        let focusHalfWidth = minimumHalfWidth
            + min(max(settings.focusSize, 0), 1) * max(0, maximumHalfWidth - minimumHalfWidth)
        let transitionWidth = shortestEdge * (0.10 + min(max(settings.falloff, 0), 1) * 0.48)
        let transitionStart = transitionWidth * levelStart
        let transitionEnd = transitionWidth * levelEnd

        func location(for distance: CGFloat) -> CGFloat {
            min(max((distance - minimumDistance) / distanceRange, 0), 1)
        }

        let start = CGPoint(
            x: focus.x + normal.dx * minimumDistance,
            y: focus.y + normal.dy * minimumDistance
        )
        let end = CGPoint(
            x: focus.x + normal.dx * maximumDistance,
            y: focus.y + normal.dy * maximumDistance
        )
        let stops = [
            Gradient.Stop(color: blurMaskColor, location: 0),
            Gradient.Stop(
                color: blurMaskColor,
                location: location(for: -focusHalfWidth - transitionEnd)
            ),
            Gradient.Stop(
                color: sharpMaskColor,
                location: location(for: -focusHalfWidth - transitionStart)
            ),
            Gradient.Stop(
                color: sharpMaskColor,
                location: location(for: focusHalfWidth + transitionStart)
            ),
            Gradient.Stop(
                color: blurMaskColor,
                location: location(for: focusHalfWidth + transitionEnd)
            ),
            Gradient.Stop(color: blurMaskColor, location: 1)
        ]

        return LinearGradient(
            gradient: Gradient(stops: stops),
            startPoint: UnitPoint(
                x: start.x / max(size.width, 1),
                y: start.y / max(size.height, 1)
            ),
            endPoint: UnitPoint(
                x: end.x / max(size.width, 1),
                y: end.y / max(size.height, 1)
            )
        )
    }

    private var sharpMaskColor: Color {
        .clear
    }

    private var blurMaskColor: Color {
        .white
    }

    private var levelStart: CGFloat {
        CGFloat(min(max(level, 0), max(levelCount - 1, 0))) / CGFloat(max(levelCount, 1))
    }

    private var levelEnd: CGFloat {
        CGFloat(min(max(level + 1, 1), max(levelCount, 1))) / CGFloat(max(levelCount, 1))
    }

    private func corners(in size: CGSize) -> [CGPoint] {
        [
            .zero,
            CGPoint(x: size.width, y: 0),
            CGPoint(x: size.width, y: size.height),
            CGPoint(x: 0, y: size.height)
        ]
    }
}

private struct AnnotationProgressiveBlurPreviewKey: Hashable {
    let sourceID: ObjectIdentifier
    let isEnabled: Bool
    let edgeMode: AnnotationProgressiveBlurEdgeMode
    let mode: AnnotationProgressiveBlurMode
    let strength: CGFloat
    let falloff: CGFloat
    let focusSize: CGFloat
    let focusX: CGFloat
    let focusY: CGFloat
    let directionDegrees: CGFloat

    init(image: NSImage, settings: AnnotationProgressiveBlurSettings) {
        sourceID = ObjectIdentifier(image)
        isEnabled = settings.isEnabled
        edgeMode = settings.edgeMode
        mode = settings.mode
        strength = settings.strength
        falloff = settings.falloff
        focusSize = settings.focusSize
        focusX = settings.focusPosition.x
        focusY = settings.focusPosition.y
        directionDegrees = settings.directionDegrees
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
            AnnotationCustomWallpaperPreview(wallpaper: wallpaper, maxPixelSize: 2048)
        }
    }
}

private struct AnnotationWatermarkOverlay: View {
    let settings: AnnotationWatermarkSettings
    let fontScale: CGFloat

    var body: some View {
        Canvas { context, size in
            let rows = max(2, Int(round(settings.density)))
            let spacingY = size.height / CGFloat(rows)
            let spacingX = max(1, spacingY * 2.2)
            let diagonal = hypot(size.width, size.height)
            let columnCount = max(2, Int(ceil(diagonal / spacingX)))
            let rowCount = max(2, Int(ceil(diagonal / spacingY)))
            let originX = size.width / 2 - CGFloat(columnCount) * spacingX / 2
            let originY = size.height / 2 - CGFloat(rowCount) * spacingY / 2
            let label = Text(settings.text)
                .font(AnnotationWatermarkTypography.font(size: settings.fontSize * fontScale))
                .foregroundStyle(settings.color.color.opacity(min(0.75, max(0, settings.opacity))))

            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: .degrees(Double(settings.rotationDegrees)))
            context.translateBy(x: -size.width / 2, y: -size.height / 2)

            for row in 0...rowCount {
                for column in 0...columnCount {
                    context.draw(
                        label,
                        at: CGPoint(
                            x: originX + CGFloat(column) * spacingX,
                            y: originY + CGFloat(row) * spacingY
                        ),
                        anchor: .center
                    )
                }
            }
        }
    }
}

struct AnnotationCustomWallpaperPreview: View {
    let wallpaper: AnnotationCustomWallpaper
    var maxPixelSize: CGFloat = 900

    @State private var image: CGImage?
    @State private var isLoading = true
    @State private var didFail = false

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else if didFail {
                Color.black
                    .overlay {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
            } else {
                Color(nsColor: .controlBackgroundColor)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        .task(id: cacheID) {
            await loadImage()
        }
    }

    private var cacheID: String {
        AnnotationWallpaperPreviewCache.cacheID(for: wallpaper.url, maxPixelSize: maxPixelSize)
    }

    @MainActor
    private func loadImage() async {
        image = nil
        isLoading = true
        didFail = false

        let loadedImage = await AnnotationWallpaperPreviewCache.shared.image(
            for: wallpaper.url,
            maxPixelSize: maxPixelSize
        )

        guard !Task.isCancelled else { return }
        image = loadedImage
        didFail = loadedImage == nil
        isLoading = false
    }
}
