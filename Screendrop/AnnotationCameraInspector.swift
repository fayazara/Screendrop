//
//  AnnotationCameraInspector.swift
//  Screendrop
//

import SwiftUI

struct AnnotationCameraInspector: View {
    @Binding var settings: AnnotationCameraSettings
    let onEditorAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.groupSpacing) {
            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Camera angle")

                sliderPair(
                    ("Tilt X", \.tiltXDegrees),
                    ("Tilt Y", \.tiltYDegrees),
                    range: -45...45,
                    format: .degrees(signed: true)
                )

                InspectorFieldPair {
                    InspectorSlider(
                        "Roll",
                        value: binding(\.rollDegrees),
                        range: -45...45,
                        format: .degrees(signed: true)
                    )
                } trailing: {
                    Color.clear.frame(height: InspectorMetrics.controlHeight)
                }
            }
            .help("Orbit the camera around the card center, then roll the view")

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Framing")

                InspectorFieldPair {
                    InspectorSlider(
                        "FOV",
                        value: binding(\.fieldOfViewDegrees),
                        range: 18...80,
                        format: .degrees()
                    )
                } trailing: {
                    InspectorSlider(
                        "Zoom",
                        value: binding(\.zoom),
                        range: 0.4...2.5,
                        format: .magnification(fractionDigits: 2)
                    )
                }

                sliderPair(
                    ("Pan X", \.panX),
                    ("Pan Y", \.panY),
                    range: -0.5...0.5,
                    format: .percent(signed: true)
                )
            }
            .help("Use a lower FOV for a calmer lens, then frame with Zoom and Pan")

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorGroupLabel("Card rotation")

                sliderPair(
                    ("Rotate X", \.rotationXDegrees),
                    ("Rotate Y", \.rotationYDegrees),
                    range: -60...60,
                    format: .degrees(signed: true)
                )
            }
            .help("Rotate the card around its own horizontal and vertical center axes")
        }
    }

    /// X/Y companions share one row so the section reads as axis pairs.
    private func sliderPair(
        _ first: (title: LocalizedStringResource, keyPath: WritableKeyPath<AnnotationCameraSettings, CGFloat>),
        _ second: (title: LocalizedStringResource, keyPath: WritableKeyPath<AnnotationCameraSettings, CGFloat>),
        range: ClosedRange<CGFloat>,
        format: InspectorValueFormat
    ) -> some View {
        InspectorFieldPair {
            InspectorSlider(
                first.title,
                value: binding(first.keyPath),
                range: range,
                format: format
            )
        } trailing: {
            InspectorSlider(
                second.title,
                value: binding(second.keyPath),
                range: range,
                format: format
            )
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

}
