//
//  RecordingStudioLayoutInspector.swift
//  Screendrop
//
//  The camera layout picker: six layouts as quiet, neutral miniatures in two
//  rows of three, and below them only the options the picked layout has. Used for the
//  default layout in the Camera section and for a layout cue selected on
//  the timeline.
//

import SwiftUI

struct StudioCameraLayoutPicker: View {
    @Bindable var model: RecordingStudioModel
    let layout: RecordingCameraLayout
    /// `isContinuous` is true while a slider is being dragged.
    let onChange: (RecordingCameraLayout, _ isContinuous: Bool) -> Void

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10, alignment: .top),
        count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(RecordingCameraLayout.presets, id: \.self) { preset in
                    StudioCameraLayoutTile(preset: preset, current: layout, aspectRatio: tileAspect) {
                        let candidate = layout.adopting(preset)
                        guard candidate != layout else { return }
                        onChange(candidate, false)
                    }
                }
            }

            options
        }
    }

    /// Tiles share the canvas's shape, so a portrait export shows portrait
    /// miniatures.
    private var tileAspect: CGFloat {
        let size = model.basePreviewCanvasSize
        guard size.width > 0, size.height > 0 else { return 16 / 10 }
        return min(max(size.width / size.height, 0.75), 1.9)
    }

    @ViewBuilder
    private var options: some View {
        switch layout.kind {
        case .pictureInPicture:
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                if layout.shape == .circle {
                    cornerPicker
                } else {
                    InspectorFieldPair {
                        cornerPicker
                    } trailing: {
                        group("Shape") {
                            InspectorSegmented(
                                options: [RecordingCameraLayout.Shape.square, .portrait],
                                isSelected: { $0 == layout.shape },
                                onTap: { shape in edit { $0.shape = shape } },
                                label: { shape in
                                    Image(systemName: shape.systemImage)
                                        .font(.system(size: 11, weight: .medium))
                                        .accessibilityLabel(shape.title)
                                }
                            )
                        }
                    }
                }

                InspectorFieldPair {
                    slider("Size", \.size, range: RecordingCameraLayout.sizeRange)
                } trailing: {
                    InspectorSlider(
                        "Rounding",
                        value: $model.style.camera.roundness,
                        range: 0.05...0.5,
                        format: .percent()
                    )
                    .disabled(layout.shape == .circle)
                    .opacity(layout.shape == .circle ? 0.4 : 1)
                }

                InspectorHalfField {
                    zoomShrinkSlider
                }
            }
        case .cutout:
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                group("Position") {
                    InspectorSegmented(
                        options: RecordingCameraLayout.Placement.allCases,
                        isSelected: { $0 == layout.placement },
                        onTap: { placement in edit { $0.placement = placement } },
                        label: { Text($0.title).font(.inspectorSegment) }
                    )
                }

                InspectorFieldPair {
                    slider("Size", \.cutoutSize, range: RecordingCameraLayout.cutoutSizeRange)
                        .help("How tall the camera's picture stands, measured on the canvas's shorter side")
                } trailing: {
                    zoomShrinkSlider
                }
            }
        case .split:
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorFieldPair {
                    group("Camera") {
                        InspectorSegmented(
                            options: RecordingCameraLayout.Side.allCases,
                            isSelected: { $0 == layout.side },
                            onTap: { side in edit { $0.side = side } },
                            label: { Text($0.title(isPortrait: isPortraitCanvas)).font(.inspectorSegment) }
                        )
                    }
                } trailing: {
                    group("Screen") {
                        InspectorSegmented(
                            options: RecordingCameraLayout.ScreenFit.allCases,
                            isSelected: { $0 == layout.screenFit },
                            onTap: { fit in edit { $0.screenFit = fit } },
                            label: { Text($0.title).font(.inspectorSegment) }
                        )
                    }
                }

                InspectorFieldPair {
                    slider("Width", \.splitRatio, range: RecordingCameraLayout.splitRatioRange)
                } trailing: {
                    slider("Spacing", \.spacing, range: RecordingCameraLayout.spacingRange)
                        .help("The gap around the frame and between the screen and camera")
                }
            }
        case .screen, .camera:
            EmptyView()
        }
    }

    private var cornerPicker: some View {
        group("Corner") {
            InspectorSegmented(
                options: RecordingCameraLayout.Corner.allCases,
                isSelected: { $0 == layout.corner },
                onTap: { corner in edit { $0.corner = corner } },
                label: { corner in
                    Image(systemName: corner.systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                        .accessibilityLabel(corner.title)
                }
            )
        }
    }

    /// A camera over the screen steps back for zooms: by how much, where
    /// 0% leaves it where it is. One field rather than a switch and a field.
    private var zoomShrinkSlider: some View {
        InspectorSlider(
            "Shrink",
            value: Binding(
                get: { model.style.camera.shrinksDuringZoom ? model.style.camera.zoomShrinkAmount : 0 },
                set: { amount in
                    if amount < 0.01 {
                        model.style.camera.shrinksDuringZoom = false
                    } else {
                        model.style.camera.shrinksDuringZoom = true
                        model.style.camera.zoomShrinkAmount = max(
                            RecordingCameraBubbleSettings.zoomShrinkAmountRange.lowerBound,
                            amount
                        )
                    }
                }
            ),
            range: 0...RecordingCameraBubbleSettings.zoomShrinkAmountRange.upperBound,
            format: .percent()
        )
        .help("How much smaller the camera gets while the screen is zoomed in. 0% keeps it full size.")
    }

    private var isPortraitCanvas: Bool {
        let size = model.basePreviewCanvasSize
        return size.height > size.width
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
            InspectorGroupLabel(title)
            content()
        }
    }

    private func edit(_ change: (inout RecordingCameraLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        onChange(next, false)
    }

    private func slider(
        _ title: String,
        _ keyPath: WritableKeyPath<RecordingCameraLayout, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        InspectorSlider(
            title,
            value: Binding(
                get: { CGFloat(layout[keyPath: keyPath]) },
                set: { value in
                    var next = layout
                    next[keyPath: keyPath] = Double(value)
                    onChange(next, true)
                }
            ),
            range: CGFloat(range.lowerBound)...CGFloat(range.upperBound),
            format: .percent()
        )
    }
}

/// One layout in the picker: its miniature above its name. The miniature
/// is the whole tile, with no card around it, and the ring that marks the
/// picked one sits a hair outside it, like every other picker tile in the
/// inspector.
///
/// When a choice it shows changes, such as the corner, the tile morphs
/// from what it showed on the video's own curve.
private struct StudioCameraLayoutTile: View {
    let preset: RecordingCameraLayout
    /// The layout in use, which the tile is either showing or not.
    let current: RecordingCameraLayout
    let aspectRatio: CGFloat
    let action: () -> Void

    @State private var isHovering = false
    /// The morph runs as `phase` animates up by one from `morphStart`.
    @State private var phase: CGFloat = 0
    @State private var morphStart: CGFloat = 0
    @State private var morphSource: RecordingCameraLayout?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let radius = Radius.thumbnail
    private static let ringGap: CGFloat = 2.5

    private var isSelected: Bool { current.matches(preset: preset) }
    private var shown: RecordingCameraLayout { current.adopting(preset).miniature }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MiniatureScene(
                    layout: shown,
                    source: morphSource,
                    morphStart: morphStart,
                    phase: phase,
                    isSelected: isSelected,
                    outerRadius: Self.radius
                )
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering && !isSelected ? 0.16 : 0.07), lineWidth: 0.5)
                }
                .padding(Self.ringGap)
                .overlay {
                    RoundedRectangle(cornerRadius: Self.radius + Self.ringGap, style: .continuous)
                        .strokeBorder(InspectorControlPalette.selectionRing, lineWidth: 2)
                        .opacity(isSelected ? 1 : 0)
                }

                Text(preset.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioCameraLayoutTileButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.fade, value: isHovering)
        .animation(.fade, value: isSelected)
        .onChange(of: current) { old, _ in
            // Only from what the tile showed itself, so a new corner slides
            // every corner camera over and a slider moves nothing. A newly
            // picked tile keeps its picture: replaying the move from the
            // layout before would first snap it to that layout's picture.
            morph(from: old.adopting(preset).miniature)
        }
        .help(preset.detailedTitle)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func morph(from source: RecordingCameraLayout) {
        guard source != shown, !reduceMotion else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            morphSource = source
            morphStart = phase
        }
        withAnimation(.linear(duration: 0.55)) { phase += 1 }
    }
}

private struct StudioCameraLayoutTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.hover, value: configuration.isPressed)
    }
}

extension RecordingCameraLayout {
    /// What a tile draws: the arrangement and the choices that change its
    /// shape (corner, side, placement, a bubble's shape), at the ideal
    /// proportions rather than the slider values, so a narrow split or a
    /// tiny bubble never makes a miniature look wrong.
    fileprivate var miniature: RecordingCameraLayout {
        RecordingCameraLayout(kind: kind, corner: corner, shape: shape, side: side, placement: placement)
    }
}

// MARK: - Miniature

/// Where everything sits in a miniature. Kept in the resolver's frame so a
/// morph blends exactly like the video's, plus how much the camera floats
/// over the screen rather than sitting beside it.
private struct MiniatureFrame {
    var base: RecordingCameraLayoutFrame
    var floats: CGFloat

    static func interpolate(_ from: MiniatureFrame, _ to: MiniatureFrame, progress: CGFloat) -> MiniatureFrame {
        MiniatureFrame(
            base: .interpolate(from.base, to.base, progress: progress),
            floats: from.floats + (to.floats - from.floats) * progress
        )
    }
}

/// One idealized frame for every tile, drawn to a grid rather than by the
/// resolver: one padding around the stage, one margin for a camera inside
/// the window, one camera size, and radii that run concentric with the
/// tile's own corners.
private struct MiniatureGeometry {
    let size: CGSize
    let outerRadius: CGFloat

    /// Everything is measured in this, so text, lights and people come out
    /// the same size in every tile.
    var unit: CGFloat { min(size.width, size.height) }
    var padding: CGFloat { min(max((unit * 0.13).rounded(), 4), 8) }
    var stage: CGRect { CGRect(origin: .zero, size: size).insetBy(dx: padding, dy: padding) }
    private var margin: CGFloat { max(2, (unit * 0.07).rounded()) }

    /// Outer radius = inner radius + padding.
    func concentricRadius(for rect: CGRect) -> CGFloat {
        let inset = min(rect.minX, rect.minY, size.width - rect.maxX, size.height - rect.maxY)
        return max(2, outerRadius - max(0, inset))
    }

    func frame(for layout: RecordingCameraLayout) -> MiniatureFrame {
        switch layout.kind {
        case .screen:
            var hidden = layout
            hidden.shape = .square
            let ghost = cornerCamera(for: hidden)
            return MiniatureFrame(
                base: RecordingCameraLayoutFrame(
                    screenRect: stage,
                    screenOpacity: 1,
                    cameraRect: ghost.rect,
                    cameraCornerRadius: ghost.radius,
                    cameraOpacity: 0
                ),
                floats: 1
            )
        case .camera:
            return MiniatureFrame(
                base: RecordingCameraLayoutFrame(
                    screenRect: stage,
                    screenOpacity: 0,
                    cameraRect: stage,
                    cameraCornerRadius: concentricRadius(for: stage),
                    cameraOpacity: 1
                ),
                floats: 0
            )
        case .pictureInPicture:
            let camera = cornerCamera(for: layout)
            return MiniatureFrame(
                base: RecordingCameraLayoutFrame(
                    screenRect: stage,
                    screenOpacity: 1,
                    cameraRect: camera.rect,
                    cameraCornerRadius: camera.radius,
                    cameraOpacity: 1
                ),
                floats: 1
            )
        case .split:
            let split = splitRects(for: layout)
            return MiniatureFrame(
                base: RecordingCameraLayoutFrame(
                    screenRect: split.screen,
                    screenOpacity: 1,
                    cameraRect: split.camera,
                    cameraCornerRadius: concentricRadius(for: split.camera),
                    cameraOpacity: 1
                ),
                floats: 0
            )
        case .cutout:
            return MiniatureFrame(
                base: RecordingCameraLayoutFrame(
                    screenRect: stage,
                    screenOpacity: 1,
                    cameraRect: cutoutBust(for: layout),
                    cameraCornerRadius: 0,
                    cameraOpacity: 1,
                    cameraCutout: 1
                ),
                floats: 0
            )
        }
    }

    /// A webcam-sized square (or 3:4) in the window's corner.
    private func cornerCamera(for layout: RecordingCameraLayout) -> (rect: CGRect, radius: CGFloat) {
        let size: CGSize = if layout.shape == .portrait {
            CGSize(width: (unit * 0.32).rounded(), height: (unit * 0.32 * 4 / 3).rounded())
        } else {
            CGSize(width: (unit * 0.4).rounded(), height: (unit * 0.4).rounded())
        }
        let x: CGFloat = switch layout.corner {
        case .topLeading, .bottomLeading: stage.minX + margin
        case .topTrailing, .bottomTrailing: stage.maxX - margin - size.width
        }
        let y: CGFloat = switch layout.corner {
        case .topLeading, .topTrailing: stage.minY + margin
        case .bottomLeading, .bottomTrailing: stage.maxY - margin - size.height
        }
        let short = min(size.width, size.height)
        let radius = layout.shape == .circle ? short / 2 : (short * 0.3).rounded()
        return (CGRect(origin: CGPoint(x: x, y: y), size: size), radius)
    }

    /// Two cards filling the stage, the padding between them: a camera a
    /// little taller than wide, and the screen in the rest. Stacked, camera
    /// below by default, on a portrait canvas.
    private func splitRects(for layout: RecordingCameraLayout) -> (screen: CGRect, camera: CGRect) {
        let cameraFirst = layout.side == .leading
        if size.width >= size.height {
            let cameraWidth = (stage.height * 0.68).rounded()
            let screenWidth = stage.width - padding - cameraWidth
            let cameraX = cameraFirst ? stage.minX : stage.maxX - cameraWidth
            let screenX = cameraFirst ? stage.maxX - screenWidth : stage.minX
            return (
                CGRect(x: screenX, y: stage.minY, width: screenWidth, height: stage.height),
                CGRect(x: cameraX, y: stage.minY, width: cameraWidth, height: stage.height)
            )
        }
        let cameraHeight = (stage.width * 0.68).rounded()
        let screenHeight = stage.height - padding - cameraHeight
        let cameraY = cameraFirst ? stage.minY : stage.maxY - cameraHeight
        let screenY = cameraFirst ? stage.maxY - screenHeight : stage.minY
        return (
            CGRect(x: stage.minX, y: screenY, width: stage.width, height: screenHeight),
            CGRect(x: stage.minX, y: cameraY, width: stage.width, height: cameraHeight)
        )
    }

    /// Just the person: head and shoulders standing on the tile's bottom
    /// edge, in front of the window, which the edge crops.
    private func cutoutBust(for layout: RecordingCameraLayout) -> CGRect {
        let head = (unit * 0.27).rounded()
        let width = (head * 1.9).rounded()
        let height = (head * 2.2).rounded()
        let midX: CGFloat = switch layout.placement {
        case .leading: stage.minX + margin + width / 2
        case .center: size.width / 2
        case .trailing: stage.maxX - margin - width / 2
        }
        return CGRect(x: (midX - width / 2).rounded(), y: size.height - height, width: width, height: height)
    }
}

/// The stage, the window and the camera at one moment of a morph. `phase`
/// is the only animated value: SwiftUI runs it up by one from `morphStart`,
/// and every frame between is resolved and blended here.
private struct MiniatureScene: View, Animatable {
    let layout: RecordingCameraLayout
    let source: RecordingCameraLayout?
    let morphStart: CGFloat
    var phase: CGFloat
    let isSelected: Bool
    let outerRadius: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            stage(in: proxy.size)
        }
        .accessibilityHidden(true)
    }

    private func stage(in size: CGSize) -> some View {
        let geometry = MiniatureGeometry(size: size, outerRadius: outerRadius)
        let target = geometry.frame(for: layout)
        let progress = min(max(phase - morphStart, 0), 1)
        let isMorphing = source != nil && progress < 1
        let frame: MiniatureFrame = if isMorphing, let source {
            .interpolate(
                geometry.frame(for: source),
                target,
                progress: CGFloat(RecordingCameraLayoutTimeline.ease(Double(progress)))
            )
        } else {
            target
        }
        let base = frame.base
        let window = isMorphing ? base.screenRect : snapped(base.screenRect)
        let camera = isMorphing ? base.cameraRect : snapped(base.cameraRect)
        // A camera standing over the window hides what's under it, so the
        // text steps around it.
        let standsOver = base.cameraOpacity > 0.5 && max(frame.floats, base.cameraCutout) > 0.5

        return ZStack(alignment: .topLeading) {
            isDark ? Color(white: 0.15) : Color(white: 0.935)

            if base.screenOpacity > 0.001 {
                MiniatureWindow(
                    size: window.size,
                    unit: geometry.unit,
                    radius: geometry.concentricRadius(for: window),
                    isDark: isDark,
                    isSelected: isSelected,
                    obstruction: standsOver ? camera.offsetBy(dx: -window.minX, dy: -window.minY) : nil
                )
                .opacity(base.screenOpacity)
                .offset(x: window.minX, y: window.minY)
            }

            if base.cameraOpacity > 0.001, camera.width > 0, camera.height > 0 {
                MiniatureCamera(
                    size: camera.size,
                    radius: base.cameraCornerRadius,
                    cutout: base.cameraCutout,
                    floats: frame.floats,
                    isDark: isDark
                )
                .opacity(base.cameraOpacity)
                .offset(x: camera.minX, y: camera.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var isDark: Bool { colorScheme == .dark }

    /// On whole pixels at rest, so edges and hairlines land crisp.
    private func snapped(_ rect: CGRect) -> CGRect {
        let scale = max(displayScale, 1)
        func round(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = round(rect.minX), minY = round(rect.minY)
        return CGRect(x: minX, y: minY, width: round(rect.maxX) - minX, height: round(rect.maxY) - minY)
    }
}

/// A window reduced to what makes it one: the traffic lights, a heading
/// and two lines of text. Its lights are grey until its tile is picked.
private struct MiniatureWindow: View {
    let size: CGSize
    /// The tile's measure, so every window's text is the same size.
    let unit: CGFloat
    let radius: CGFloat
    let isDark: Bool
    let isSelected: Bool
    /// A camera standing over the window, in the window's coordinates.
    let obstruction: CGRect?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dot = max(2.5, unit * 0.062)
        let inset = max(dot * 1.1, (radius * 0.75).rounded(), (unit * 0.085).rounded())
        let line = max(1.5, unit * 0.042)
        let lights = CGRect(x: inset, y: inset, width: dot * 4.3, height: dot)
        let text = textBlock(inset: inset, top: inset + dot + line * 2.4, line: line)

        ZStack(alignment: .topLeading) {
            shape.fill(isDark ? Color(white: 0.25) : Color.white)

            // Lights a camera half covers would peek out from under it.
            if obstruction?.intersects(lights.insetBy(dx: -1, dy: -1)) != true {
                MiniatureTrafficLights(dot: dot, isLit: isSelected, isDark: isDark)
                    .offset(x: inset, y: inset)
            }

            // Lines the window has no room for are left out, not clipped.
            if let text, text.minY + line * 3.6 <= size.height - inset * 0.6 {
                VStack(alignment: .leading, spacing: line * 1.2) {
                    Capsule()
                        .fill(Color.primary.opacity(isDark ? 0.3 : 0.2))
                        .frame(width: text.width * 0.5, height: line * 1.4)
                    Capsule()
                        .fill(Color.primary.opacity(isDark ? 0.15 : 0.1))
                        .frame(width: text.width * 0.9, height: line)
                    if text.maxY <= size.height - inset * 0.6 {
                        Capsule()
                            .fill(Color.primary.opacity(isDark ? 0.15 : 0.1))
                            .frame(width: text.width * 0.64, height: line)
                    }
                }
                .offset(x: text.minX, y: text.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isDark ? 0.1 : 0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(isDark ? 0.22 : 0.05), radius: 1, y: 0.5)
    }

    /// Where the text runs: under the lights, beside a camera standing
    /// over it, or below the camera when the window is too narrow for
    /// that. None when too little is left to read as text.
    private func textBlock(inset: CGFloat, top: CGFloat, line: CGFloat) -> CGRect? {
        let height = line * 6.8
        let minimumWidth = line * 6
        let full = CGRect(x: inset, y: top, width: size.width - inset * 2, height: height)
        guard let obstruction, obstruction.intersects(full) else {
            return full.width >= minimumWidth ? full : nil
        }
        var beside = full
        if obstruction.midX > size.width / 2 {
            beside.size.width = obstruction.minX - inset * 0.8 - full.minX
        } else {
            beside.origin.x = obstruction.maxX + inset * 0.8
            beside.size.width = full.maxX - beside.minX
        }
        if beside.width >= max(minimumWidth, full.width * 0.45) { return beside }
        var below = full
        below.origin.y = obstruction.maxY + line * 2.4
        return below.maxY <= size.height - inset ? below : nil
    }
}

/// Close, minimize and zoom: macOS's colors on the picked tile, a quiet
/// grey on the rest.
private struct MiniatureTrafficLights: View {
    let dot: CGFloat
    let isLit: Bool
    let isDark: Bool

    private static let colors = [
        Color(red: 1, green: 0.373, blue: 0.341),
        Color(red: 0.996, green: 0.737, blue: 0.18),
        Color(red: 0.157, green: 0.784, blue: 0.251)
    ]

    var body: some View {
        HStack(spacing: dot * 0.62) {
            ForEach(Self.colors.indices, id: \.self) { index in
                Circle()
                    .fill(isLit ? Self.colors[index] : Color.primary.opacity(isDark ? 0.22 : 0.15))
                    .frame(width: dot, height: dot)
            }
        }
    }
}

/// The camera: a person against a flat wall, cropped by the camera's
/// shape. Floating over the window it gets a white rim and a lift; beside
/// the window it's a card like the window. Cut out, the wall melts away
/// and the person alone stands in front, as the video does it.
private struct MiniatureCamera: View {
    let size: CGSize
    let radius: CGFloat
    /// 0 is the whole camera picture, 1 the person alone.
    let cutout: CGFloat
    /// 0 beside the window, 1 over it.
    let floats: CGFloat
    let isDark: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let framed = 1 - cutout
        let person = isDark ? mix(0.62, 0.5) : mix(0.975, 0.72)
        let lift = max(floats * framed, cutout)

        ZStack {
            shape.fill(Color(white: isDark ? 0.34 : 0.8)).opacity(framed)
            MiniaturePerson(cutout: cutout).fill(Color(white: person))
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(isDark ? 0.22 : 0.95), lineWidth: 1)
                .opacity(floats * framed)
            shape.strokeBorder(Color.primary.opacity(isDark ? 0.1 : 0.06), lineWidth: 0.5)
                .opacity((1 - floats) * framed)
        }
        .shadow(
            color: .black.opacity((isDark ? 0.22 : 0.05) + (isDark ? 0.2 : 0.09) * lift),
            radius: 1 + lift,
            y: 0.5 + lift * 0.25
        )
    }

    private func mix(_ framedWhite: CGFloat, _ cutoutWhite: CGFloat) -> CGFloat {
        framedWhite + (cutoutWhite - framedWhite) * cutout
    }
}

/// Head and shoulders, drawn the way Apple's person glyph is: a round head
/// over domed shoulders, a hairline of space between. Framed by a camera,
/// the head sits a little above the middle and the frame's bottom crops
/// the shoulders, and the head is sized by whichever side is shorter, so
/// the person never grows tall in a narrow frame. Cut out, the bust fills
/// its frame's width with the head at the top.
private struct MiniaturePerson: Shape {
    var cutout: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let framedHead = min(rect.height * 0.4, rect.width * 0.46)
        let framedCenter = rect.minY + rect.height * 0.43
        let bustHead = min(rect.width / 1.9, rect.height * 0.5)
        let bustCenter = rect.minY + bustHead / 2
        let head = framedHead + (bustHead - framedHead) * cutout
        let centerY = framedCenter + (bustCenter - framedCenter) * cutout

        var path = Path(ellipseIn: CGRect(x: rect.midX - head / 2, y: centerY - head / 2, width: head, height: head))
        let shouldersTop = centerY + head * 0.62
        path.addPath(Path(
            roundedRect: CGRect(
                x: rect.midX - head * 0.95,
                y: shouldersTop,
                width: head * 1.9,
                height: max(head, rect.maxY - shouldersTop + head)
            ),
            cornerRadius: head * 0.8,
            style: .continuous
        ))
        return path
    }
}

/// Head and shoulders, drawn the way Apple's person glyph is: a round head
/// over domed shoulders. One scale everywhere - by the frame's height,
/// capped by its width - and anchored to the bottom, so a thin card shows
/// the same person with wall above rather than a stretched one, and the
/// frame's bottom edge always crops the shoulders.
struct StudioPersonSilhouette: Shape {
    /// The head's diameter as a share of the frame's height.
    var scale: CGFloat = 0.36

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let head = min(rect.height * scale, rect.width * 0.42)
        let center = CGPoint(
            x: rect.midX,
            y: min(rect.minY + rect.height * 0.41, rect.maxY - head * 1.6)
        )
        let shouldersTop = center.y + head * 0.63
        var path = Path(ellipseIn: CGRect(
            x: center.x - head / 2, y: center.y - head / 2, width: head, height: head
        ))
        path.addPath(Path(
            roundedRect: CGRect(
                x: center.x - head * 0.95, y: shouldersTop,
                width: head * 1.9, height: rect.maxY - shouldersTop + head
            ),
            cornerRadius: head * 0.82,
            style: .continuous
        ))
        return path.intersection(Path(rect))
    }
}

extension RecordingCameraLayout.Placement {
    var title: String {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }
}

extension RecordingCameraLayout.Corner {
    var title: String {
        switch self {
        case .topLeading: "Top left"
        case .topTrailing: "Top right"
        case .bottomLeading: "Bottom left"
        case .bottomTrailing: "Bottom right"
        }
    }

    var systemImage: String {
        switch self {
        case .topLeading: "arrow.up.left"
        case .topTrailing: "arrow.up.right"
        case .bottomLeading: "arrow.down.left"
        case .bottomTrailing: "arrow.down.right"
        }
    }
}

extension RecordingCameraLayout.Shape {
    var title: String {
        switch self {
        case .circle: "Circle"
        case .square: "Square"
        case .portrait: "Portrait"
        }
    }

    var systemImage: String {
        switch self {
        case .circle: "circle"
        case .square: "square"
        case .portrait: "rectangle.portrait"
        }
    }
}

extension RecordingCameraLayout.Side {
    func title(isPortrait: Bool) -> String {
        switch self {
        case .leading: isPortrait ? "Top" : "Left"
        case .trailing: isPortrait ? "Bottom" : "Right"
        }
    }
}

extension RecordingCameraLayout.ScreenFit {
    var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        }
    }
}
