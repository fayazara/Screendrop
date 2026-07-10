//
//  AnnotationCameraInspector.swift
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
