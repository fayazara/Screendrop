//
//  AnnotationInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

// MARK: - Inspector

enum AnnotationEditorFocusedField: Hashable {
    case watermarkText
}

/// Sections that fold with a chevron rather than a feature switch.
private enum AnnotationInspectorAdvancedSection: String, Hashable, CaseIterable {
    case camera
}

private enum AnnotationInspectorSectionState {
    static let expandedSectionsKey = "annotationInspector.expandedAdvancedSections"

    static func loadExpandedSections() -> Set<AnnotationInspectorAdvancedSection> {
        let rawValues = UserDefaults.standard.stringArray(forKey: expandedSectionsKey) ?? []
        return Set(rawValues.compactMap(AnnotationInspectorAdvancedSection.init(rawValue:)))
    }

    static func saveExpandedSections(_ sections: Set<AnnotationInspectorAdvancedSection>) {
        UserDefaults.standard.set(sections.map(\.rawValue), forKey: expandedSectionsKey)
    }
}

struct AnnotationEditorInspector: View {
    @Bindable var model: AnnotationEditorModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    @Bindable var backgroundPresetStore: AnnotationBackgroundPresetStore
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var expandedAdvancedSections: Set<AnnotationInspectorAdvancedSection> = AnnotationInspectorSectionState.loadExpandedSections()

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                AnnotationStyleStrip(
                    model: model,
                    presetStore: backgroundPresetStore,
                    onEditorAction: onEditorAction
                )

                // Only while a styled tool is picked or an annotation is
                // selected; with nothing to style it would be filler.
                if model.hasInspectorStyleControls {
                    InspectorSection("Annotation") {
                        styleControls
                    }

                    InspectorGroupBreak()
                }

                InspectorSection("Canvas") {
                    InspectorSegmented(
                        options: AnnotationBackgroundAspectRatio.allCases,
                        isSelected: { $0 == model.backgroundSettings.aspectRatio },
                        onTap: { ratio in
                            onEditorAction()
                            model.backgroundSettings.aspectRatio = ratio
                        },
                        label: { ratio in
                            Text(ratio.title)
                                .font(.inspectorSegment)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    )
                    // The ratio shapes the background canvas; there is none
                    // to shape without one.
                    .disabled(!model.backgroundSettings.usesCanvasLayout)
                    .opacity(model.backgroundSettings.usesCanvasLayout ? 1 : 0.4)
                }

                InspectorSection(
                    "Frame",
                    accessory: {
                        if !usesDefaultFrame {
                            sectionResetButton("Reset padding, corners, shadow and alignment") {
                                let defaults = AnnotationBackgroundSettings()
                                model.backgroundSettings.padding = defaults.padding
                                model.backgroundSettings.cornerRadius = defaults.cornerRadius
                                model.backgroundSettings.shadow = defaults.shadow
                                model.backgroundSettings.shadowStyle = defaults.shadowStyle
                                model.backgroundSettings.alignment = defaults.alignment
                            }
                        }
                    }
                ) {
                    AnnotationFrameInspector(
                        settings: Binding(
                            get: { model.backgroundSettings },
                            set: { model.backgroundSettings = $0 }
                        ),
                        wallpaperStore: wallpaperStore,
                        onEditorAction: onEditorAction,
                        onPickWallpaper: onPickWallpaper,
                        onPreview: { model.previewBackground($0, isHovering: $1) },
                        onEndPreview: { model.previewBackground = nil }
                    )
                }

                InspectorSection(
                    "Border",
                    summary: AnnotationInspectorSummary.border(model.backgroundSettings.border),
                    isOn: featureBinding(\.border.isEnabled),
                    toggleTitle: "Enable border",
                    accessory: {
                        if model.backgroundSettings.border != AnnotationScreenshotBorderSettings(),
                           model.backgroundSettings.border.isEnabled {
                            sectionResetButton("Reset border") {
                                var border = AnnotationScreenshotBorderSettings()
                                border.isEnabled = true
                                model.backgroundSettings.border = border
                            }
                        }
                    }
                ) {
                    AnnotationScreenshotBorderInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.border },
                            set: { model.backgroundSettings.border = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Camera",
                    summary: AnnotationInspectorSummary.camera(model.backgroundSettings.camera),
                    isExpanded: expansionBinding(for: .camera),
                    accessory: {
                        if !model.backgroundSettings.camera.isDefault {
                            InspectorResetButton(help: "Reset camera") {
                                onEditorAction()
                                withAnimation(.canvasMove) {
                                    model.backgroundSettings.camera = AnnotationCameraSettings()
                                }
                            }
                            .transition(.blurPop)
                        }
                    }
                ) {
                    AnnotationCameraInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.camera },
                            set: { model.backgroundSettings.camera = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorSection(
                    "Progressive Blur",
                    summary: AnnotationInspectorSummary.progressiveBlur(model.backgroundSettings.progressiveBlur),
                    isOn: featureBinding(\.progressiveBlur.isEnabled),
                    toggleTitle: "Enable progressive blur",
                    accessory: {
                        if model.backgroundSettings.progressiveBlur != AnnotationProgressiveBlurSettings(),
                           model.backgroundSettings.progressiveBlur.isEnabled {
                            sectionResetButton("Reset progressive blur") {
                                var blur = AnnotationProgressiveBlurSettings()
                                blur.isEnabled = true
                                model.backgroundSettings.progressiveBlur = blur
                            }
                        }
                    }
                ) {
                    AnnotationProgressiveBlurInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.progressiveBlur },
                            set: { model.backgroundSettings.progressiveBlur = $0 }
                        ),
                        onEditorAction: onEditorAction
                    )
                }

                InspectorGroupBreak()

                InspectorSection(
                    "Watermark",
                    summary: AnnotationInspectorSummary.watermark(model.backgroundSettings.watermark),
                    isOn: featureBinding(\.watermark.isEnabled),
                    toggleTitle: "Enable watermark",
                    accessory: {
                        if model.backgroundSettings.watermark != AnnotationWatermarkSettings(),
                           model.backgroundSettings.watermark.isEnabled {
                            sectionResetButton("Reset watermark") {
                                var watermark = AnnotationWatermarkSettings()
                                watermark.isEnabled = true
                                model.backgroundSettings.watermark = watermark
                            }
                        }
                    }
                ) {
                    AnnotationWatermarkInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.watermark },
                            set: { model.backgroundSettings.watermark = $0 }
                        ),
                        focusedField: focusedField,
                        onFocusCleared: onEditorAction
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: InspectorMetrics.columnMinWidth,
            ideal: InspectorMetrics.columnIdealWidth,
            max: InspectorMetrics.columnMaxWidth
        )
        .frame(
            minWidth: InspectorMetrics.columnMinWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var usesDefaultFrame: Bool {
        let settings = model.backgroundSettings
        let defaults = AnnotationBackgroundSettings()
        return settings.padding == defaults.padding
            && settings.cornerRadius == defaults.cornerRadius
            && settings.shadow == defaults.shadow
            && settings.shadowStyle == defaults.shadowStyle
            && settings.alignment == defaults.alignment
    }

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    private func expansionBinding(
        for section: AnnotationInspectorAdvancedSection
    ) -> Binding<Bool> {
        Binding(
            get: { expandedAdvancedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedAdvancedSections.insert(section)
                } else {
                    expandedAdvancedSections.remove(section)
                }
                AnnotationInspectorSectionState.saveExpandedSections(expandedAdvancedSections)
            }
        )
    }

    /// A feature switch in a section header. The section folds with it.
    private func featureBinding(
        _ keyPath: WritableKeyPath<AnnotationBackgroundSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.backgroundSettings[keyPath: keyPath] },
            set: { value in
                onEditorAction()
                model.backgroundSettings[keyPath: keyPath] = value
            }
        )
    }

    /// Restores a switched-on feature's defaults without switching it off.
    private func sectionResetButton(_ help: String, reset: @escaping () -> Void) -> some View {
        InspectorResetButton(help: help) {
            onEditorAction()
            withAnimation(.canvasMove) { reset() }
        }
        .transition(.blurPop)
    }

    // MARK: Tools & style

    @ViewBuilder
    private var styleControls: some View {
        if model.selectionCount > 1 {
            Text("\(model.selectionCount) annotations selected")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
        }

        if model.isTextStyleAvailable {
            AnnotationTextStyleControls(model: model)
        } else {
            if model.isColorStyleAvailable {
                InspectorRow("Color") {
                    AnnotationSwatchStrip(selectedSwatch: model.selectedSwatch) { swatch in
                        onEditorAction()
                        model.setSwatch(swatch)
                    }
                }
            }

            if model.isStrokeStyleAvailable {
                InspectorRow("Stroke") {
                    AnnotationStrokePicker(strokeWidth: model.strokeWidth) { strokeWidth in
                        onEditorAction()
                        model.setStrokeWidth(strokeWidth)
                    }
                }
            }

            if model.isRedactionStyleAvailable {
                InspectorSlider(
                    "Strength",
                    value: Binding(
                        get: { model.redactionDensity },
                        set: {
                            onEditorAction()
                            model.setRedactionDensity($0)
                        }
                    ),
                    range: 0.15...1,
                    format: .percent()
                )
            }
        }
    }
}

// MARK: - Section summaries

/// One-line readouts for collapsed section headers. `nil` means the section
/// has nothing active worth announcing.
private enum AnnotationInspectorSummary {
    static func border(_ settings: AnnotationScreenshotBorderSettings) -> String? {
        guard settings.isEnabled else { return nil }
        let thickness = InspectorValueFormat.percent(fractionDigits: 1).displayString(for: settings.thickness)
        return "\(settings.color.title) · \(thickness)"
    }

    static func camera(_ settings: AnnotationCameraSettings) -> String? {
        guard !settings.isDefault else { return nil }
        var parts: [String] = []
        let angles = [
            settings.tiltXDegrees, settings.tiltYDegrees, settings.rollDegrees,
            settings.rotationXDegrees, settings.rotationYDegrees
        ]
        if angles.contains(where: { abs($0) > 0.0001 }) {
            parts.append("Angled")
        }
        if abs(settings.zoom - 1) > 0.0001 {
            parts.append(InspectorValueFormat.magnification(fractionDigits: 2).displayString(for: settings.zoom))
        }
        if abs(settings.panX) > 0.0001 || abs(settings.panY) > 0.0001 {
            parts.append("Panned")
        }
        if parts.isEmpty {
            parts.append("FOV \(InspectorValueFormat.degrees().displayString(for: settings.fieldOfViewDegrees))")
        }
        return parts.joined(separator: " · ")
    }

    static func progressiveBlur(_ settings: AnnotationProgressiveBlurSettings) -> String? {
        guard settings.isEnabled else { return nil }
        return "\(settings.mode.title) · \(Int(settings.strength.rounded()))"
    }

    static func watermark(_ settings: AnnotationWatermarkSettings) -> String? {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.isEnabled, !text.isEmpty else { return nil }
        return "“\(text)”"
    }
}
