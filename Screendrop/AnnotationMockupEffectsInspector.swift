//
//  AnnotationMockupEffectsInspector.swift
//  Screendrop
//

import SwiftUI

struct AnnotationCameraInspector: View {
    @Binding var settings: AnnotationCameraSettings
    let onEditorAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Quick views")

                InspectorSegmented(
                    options: AnnotationCameraViewPreset.allCases,
                    isSelected: { $0.matches(settings) },
                    onTap: applyPreset,
                    label: { preset in
                        Text(preset.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                InspectorGroupLabel("Camera angle")

                pairedSliders(
                    leftTitle: "Tilt X",
                    leftValue: binding(\.tiltXDegrees),
                    leftRange: -45...45,
                    rightTitle: "Tilt Y",
                    rightValue: binding(\.tiltYDegrees),
                    rightRange: -45...45,
                    formatter: degrees
                )

                InspectorSlider(
                    "Roll",
                    value: binding(\.rollDegrees),
                    range: -45...45,
                    formatted: degrees
                )
            }
            .help("Orbit the camera around the card center, then roll the view")

            VStack(alignment: .leading, spacing: 10) {
                InspectorGroupLabel("Framing")

                HStack(alignment: .top, spacing: 14) {
                    InspectorSlider(
                        "FOV",
                        value: binding(\.fieldOfViewDegrees),
                        range: 18...80,
                        formatted: { "\(Int($0.rounded()))°" }
                    )

                    InspectorSlider(
                        "Zoom",
                        value: binding(\.zoom),
                        range: 0.4...2.5,
                        formatted: { String(format: "%.2f×", Double($0)) }
                    )
                }

                pairedSliders(
                    leftTitle: "Pan X",
                    leftValue: binding(\.panX),
                    leftRange: -0.5...0.5,
                    rightTitle: "Pan Y",
                    rightValue: binding(\.panY),
                    rightRange: -0.5...0.5,
                    formatter: signedPercent
                )
            }
            .help("Use a lower FOV for a calmer lens, then frame with Zoom and Pan")

            VStack(alignment: .leading, spacing: 10) {
                InspectorGroupLabel("Card rotation")

                pairedSliders(
                    leftTitle: "Rotate X",
                    leftValue: binding(\.rotationXDegrees),
                    leftRange: -60...60,
                    rightTitle: "Rotate Y",
                    rightValue: binding(\.rotationYDegrees),
                    rightRange: -60...60,
                    formatter: degrees
                )
            }
            .help("Rotate the card around its own horizontal and vertical center axes")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AnnotationCameraSettings, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                var updatedSettings = settings
                updatedSettings.upgradeProjectionIfNeeded()
                updatedSettings[keyPath: keyPath] = value
                settings = updatedSettings
            }
        )
    }

    private func applyPreset(_ preset: AnnotationCameraViewPreset) {
        onEditorAction()
        withAnimation(.snappy(duration: 0.2)) {
            settings = preset.settings
        }
    }

    private func signedPercent(_ value: CGFloat) -> String {
        let percent = Int((value * 100).rounded())
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    private func degrees(_ value: CGFloat) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)°" : "\(rounded)°"
    }

    private func pairedSliders(
        leftTitle: String,
        leftValue: Binding<CGFloat>,
        leftRange: ClosedRange<CGFloat>,
        rightTitle: String,
        rightValue: Binding<CGFloat>,
        rightRange: ClosedRange<CGFloat>,
        formatter: @escaping (CGFloat) -> String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            InspectorSlider(
                leftTitle,
                value: leftValue,
                range: leftRange,
                formatted: formatter
            )

            InspectorSlider(
                rightTitle,
                value: rightValue,
                range: rightRange,
                formatted: formatter
            )
        }
    }
}

private enum AnnotationCameraViewPreset: String, CaseIterable, Identifiable {
    case flat
    case left
    case right
    case hero

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Front"
        case .left: "Left"
        case .right: "Right"
        case .hero: "Hero"
        }
    }

    var settings: AnnotationCameraSettings {
        switch self {
        case .flat:
            AnnotationCameraSettings()
        case .left:
            AnnotationCameraSettings(
                rotationXDegrees: 4,
                rotationYDegrees: -28,
                rollDegrees: -2,
                fieldOfViewDegrees: 30,
                zoom: 1.05
            )
        case .right:
            AnnotationCameraSettings(
                rotationXDegrees: 4,
                rotationYDegrees: 28,
                rollDegrees: 2,
                fieldOfViewDegrees: 30,
                zoom: 1.05
            )
        case .hero:
            AnnotationCameraSettings(
                panY: -0.03,
                tiltXDegrees: -6,
                tiltYDegrees: 5,
                rotationXDegrees: -10,
                rotationYDegrees: -18,
                rollDegrees: -3,
                fieldOfViewDegrees: 28,
                zoom: 1.12
            )
        }
    }

    func matches(_ candidate: AnnotationCameraSettings) -> Bool {
        self == .flat ? candidate.isDefault : settings == candidate
    }
}

struct AnnotationProgressiveBlurInspector: View {
    @Binding var settings: AnnotationProgressiveBlurSettings
    let onEditorAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Mode")

                InspectorSegmented(
                    options: AnnotationProgressiveBlurMode.allCases,
                    isSelected: { $0 == settings.mode },
                    onTap: { mode in
                        onEditorAction()
                        settings.mode = mode
                    },
                    label: { mode in
                        Label(mode.title, systemImage: mode == .radial ? "scope" : "line.diagonal")
                            .font(.system(size: 10.5, weight: .medium))
                            .labelStyle(.titleAndIcon)
                    }
                )
            }

            HStack(alignment: .top, spacing: 14) {
                InspectorSlider(
                    "Strength",
                    value: binding(\.strength),
                    range: 0...40,
                    formatted: { "\(Int($0.rounded()))" }
                )

                InspectorSlider(
                    "Falloff",
                    value: binding(\.falloff),
                    range: 0...1,
                    formatted: { String(format: "%.2f", Double($0)) }
                )
            }

            InspectorSlider(
                "Focus Size",
                value: binding(\.focusSize),
                range: 0...1,
                formatted: { "\(Int(($0 * 100).rounded()))%" }
            )
            .help("Choose how much of the screenshot stays sharp")

            if settings.mode == .directional {
                InspectorSlider(
                    "Direction",
                    value: binding(\.directionDegrees),
                    range: 0...180,
                    formatted: { "\(Int($0.rounded()))°" }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            InspectorRow("Bokeh") {
                Toggle(
                    "Bokeh highlights",
                    isOn: Binding(
                        get: { settings.isBokehEnabled },
                        set: { value in
                            onEditorAction()
                            settings.isBokehEnabled = value
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Use a softer lens-style blur with brighter highlight rings")
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                HStack(spacing: 8) {
                    InspectorGroupLabel("Focus position")
                    Spacer(minLength: 0)
                    Text(focusPositionText)
                        .font(.inspectorNumeric)
                        .foregroundStyle(.tertiary)
                }

                AnnotationFocusPositionPad(
                    position: $settings.focusPosition,
                    mode: settings.mode,
                    focusSize: settings.focusSize,
                    directionDegrees: settings.directionDegrees,
                    onInteractionBegan: onEditorAction
                )
            }
        }
        .animation(.snappy(duration: 0.18), value: settings.mode)
    }

    private var focusPositionText: String {
        let x = Int((settings.focusPosition.x * 100).rounded())
        let y = Int((settings.focusPosition.y * 100).rounded())
        return "\(x), \(y)"
    }

    private func binding(_ keyPath: WritableKeyPath<AnnotationProgressiveBlurSettings, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                settings[keyPath: keyPath] = value
            }
        )
    }
}

private struct AnnotationFocusPositionPad: View {
    @Binding var position: CGPoint
    let mode: AnnotationProgressiveBlurMode
    let focusSize: CGFloat
    let directionDegrees: CGFloat
    let onInteractionBegan: () -> Void

    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            let point = CGPoint(
                x: min(max(position.x, 0), 1) * proxy.size.width,
                y: min(max(position.y, 0), 1) * proxy.size.height
            )
            let radialRadius = radialFocusRadius(at: point, in: proxy.size)
            let directionalHalfWidth = directionalFocusHalfWidth(at: point, in: proxy.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.055 : 0.035))

                FocusPadGrid()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)

                if mode == .radial {
                    Circle()
                        .fill(Color.accentColor.opacity(0.055))
                        .overlay {
                            Circle()
                                .stroke(Color.accentColor.opacity(0.34), lineWidth: 1)
                        }
                        .frame(width: radialRadius * 2, height: radialRadius * 2)
                        .position(point)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.055))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
                        }
                        .frame(
                            width: hypot(proxy.size.width, proxy.size.height) * 2,
                            height: max(2, directionalHalfWidth * 2)
                        )
                        .rotationEffect(.degrees(Double(directionDegrees)))
                        .position(point)
                }

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: isDragging ? 12 : 10, height: isDragging ? 12 : 10)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: Color.black.opacity(0.22), radius: 3, y: 1)
                    .position(point)
                    .animation(.snappy(duration: 0.12), value: isDragging)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onInteractionBegan()
                        }
                        position = CGPoint(
                            x: min(max(value.location.x / max(proxy.size.width, 1), 0), 1),
                            y: min(max(value.location.y / max(proxy.size.height, 1), 0), 1)
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        onInteractionBegan()
                        withAnimation(.snappy(duration: 0.18)) {
                            position = CGPoint(x: 0.5, y: 0.5)
                        }
                    }
            )
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Blur focus position")
            .accessibilityValue(
                "X \(Int(position.x * 100)), Y \(Int(position.y * 100)), size \(Int(focusSize * 100)) percent"
            )
        }
        .frame(height: 118)
        .help("Drag to move the sharp focal area. Double-click to center.")
    }

    private func radialFocusRadius(at point: CGPoint, in size: CGSize) -> CGFloat {
        let minimumRadius = min(size.width, size.height) * 0.04
        let maximumRadius = corners(in: size).map { corner in
            hypot(corner.x - point.x, corner.y - point.y)
        }.max() ?? minimumRadius
        return minimumRadius
            + min(max(focusSize, 0), 1) * max(0, maximumRadius - minimumRadius)
    }

    private func directionalFocusHalfWidth(at point: CGPoint, in size: CGSize) -> CGFloat {
        let radians = directionDegrees * .pi / 180
        let normal = CGVector(dx: -sin(radians), dy: cos(radians))
        let minimumHalfWidth = min(size.width, size.height) * 0.025
        let maximumHalfWidth = corners(in: size).map { corner in
            abs((corner.x - point.x) * normal.dx + (corner.y - point.y) * normal.dy)
        }.max() ?? minimumHalfWidth
        return minimumHalfWidth
            + min(max(focusSize, 0), 1) * max(0, maximumHalfWidth - minimumHalfWidth)
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

private struct FocusPadGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
