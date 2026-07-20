//
//  AnnotationScreenshotBorderInspector.swift
//  Screendrop
//

import SwiftUI

struct AnnotationScreenshotBorderInspector: View {
    @Binding var settings: AnnotationScreenshotBorderSettings
    let onEditorAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: InspectorMetrics.groupLabelSpacing) {
                InspectorGroupLabel("Material")

                InspectorSegmented(
                    options: AnnotationScreenshotBorderMaterial.allCases,
                    isSelected: { settings.material == $0 },
                    onTap: { material in
                        onEditorAction()
                        settings.material = material
                    },
                    label: { material in
                        Text(material.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                )
            }

            VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
                InspectorRow(settings.material == .solid ? "Color" : "Tint") {
                    AnnotationSwatchStrip(selectedSwatch: settings.color) { color in
                        onEditorAction()
                        settings.color = color
                    }
                }

                InspectorSlider(
                    "Thickness",
                    value: binding(\.thickness),
                    range: 0.002...0.08,
                    format: .percent(fractionDigits: 1)
                )

                InspectorSlider(
                    "Opacity",
                    value: binding(\.opacity),
                    range: 0...1,
                    format: .percent()
                )
            }
        }
    }

    private func binding(
        _ keyPath: WritableKeyPath<AnnotationScreenshotBorderSettings, CGFloat>
    ) -> Binding<CGFloat> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                settings[keyPath: keyPath] = value
            }
        )
    }
}
