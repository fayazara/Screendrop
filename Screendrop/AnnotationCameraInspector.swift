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

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Camera angle")

                InspectorSlider(
                    "Tilt X",
                    value: binding(\.tiltXDegrees),
                    range: -45...45,
                    format: .degrees(signed: true)
                )

                InspectorSlider(
                    "Tilt Y",
                    value: binding(\.tiltYDegrees),
                    range: -45...45,
                    format: .degrees(signed: true)
                )

                InspectorSlider(
                    "Roll",
                    value: binding(\.rollDegrees),
                    range: -45...45,
                    format: .degrees(signed: true)
                )
            }
            .help("Orbit the camera around the card center, then roll the view")

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Framing")

                InspectorSlider(
                    "FOV",
                    value: binding(\.fieldOfViewDegrees),
                    range: 18...80,
                    format: .degrees()
                )

                InspectorSlider(
                    "Zoom",
                    value: binding(\.zoom),
                    range: 0.4...2.5,
                    format: .magnification(fractionDigits: 2)
                )

                InspectorSlider(
                    "Pan X",
                    value: binding(\.panX),
                    range: -0.5...0.5,
                    format: .percent(signed: true)
                )

                InspectorSlider(
                    "Pan Y",
                    value: binding(\.panY),
                    range: -0.5...0.5,
                    format: .percent(signed: true)
                )
            }
            .help("Use a lower FOV for a calmer lens, then frame with Zoom and Pan")

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Card rotation")

                InspectorSlider(
                    "Rotate X",
                    value: binding(\.rotationXDegrees),
                    range: -60...60,
                    format: .degrees(signed: true)
                )

                InspectorSlider(
                    "Rotate Y",
                    value: binding(\.rotationYDegrees),
                    range: -60...60,
                    format: .degrees(signed: true)
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
