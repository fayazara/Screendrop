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

private enum AnnotationInspectorAdvancedSection: String, Hashable, CaseIterable {
    case camera
    case progressiveBlur
    case background
    case border
    case watermark
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
                InspectorSection("Tools") {
                    AnnotationInspectorToolGrid(selectedTool: model.selectedTool) { tool in
                        onEditorAction()
                        model.selectTool(tool)
                    }

                    smartRedactionRow
                }

                InspectorSectionDivider()

                // Always present so selecting or deselecting annotations never
                // shifts the sections below.
                InspectorSection("Style") {
                    styleControls
                }

                InspectorSectionDivider()

                InspectorDisclosureSection(
                    title: "Background",
                    summary: AnnotationInspectorSummary.background(model.backgroundSettings),
                    isExpanded: expansionBinding(for: .background),
                    accessory: {
                        if model.backgroundSettings.style != .none {
                            InspectorClearButton(help: "Remove background") {
                                onEditorAction()
                                model.backgroundSettings.style = .none
                            }
                        }
                    }
                ) {
                    AnnotationBackgroundInspector(
                        settings: Binding(
                            get: { model.backgroundSettings },
                            set: { model.backgroundSettings = $0 }
                        ),
                        wallpaperStore: wallpaperStore,
                        onEditorAction: onEditorAction,
                        onPickWallpaper: onPickWallpaper
                    )
                }

                InspectorDisclosureSection(
                    title: "Border",
                    summary: AnnotationInspectorSummary.border(model.backgroundSettings.border),
                    isExpanded: expansionBinding(for: .border),
                    accessory: {
                        HStack(spacing: 5) {
                            if model.backgroundSettings.border != AnnotationScreenshotBorderSettings() {
                                sectionResetButton("Reset border", section: .border) {
                                    model.backgroundSettings.border = AnnotationScreenshotBorderSettings()
                                }
                            }

                            sectionToggle("Enable border", isOn: \.border.isEnabled, section: .border)
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
                    .disabled(!model.backgroundSettings.border.isEnabled)
                    .opacity(model.backgroundSettings.border.isEnabled ? 1 : 0.48)
                }

                InspectorDisclosureSection(
                    title: "Camera",
                    summary: AnnotationInspectorSummary.camera(model.backgroundSettings.camera),
                    isExpanded: expansionBinding(for: .camera),
                    accessory: {
                        if !model.backgroundSettings.camera.isDefault {
                            InspectorResetButton(help: "Reset camera") {
                                onEditorAction()
                                withAnimation(.snappy(duration: 0.2)) {
                                    model.backgroundSettings.camera = AnnotationCameraSettings()
                                }
                            }
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

                InspectorDisclosureSection(
                    title: "Progressive Blur",
                    summary: AnnotationInspectorSummary.progressiveBlur(model.backgroundSettings.progressiveBlur),
                    isExpanded: expansionBinding(for: .progressiveBlur),
                    accessory: {
                        HStack(spacing: 5) {
                            if model.backgroundSettings.progressiveBlur != AnnotationProgressiveBlurSettings() {
                                sectionResetButton("Reset progressive blur", section: .progressiveBlur) {
                                    model.backgroundSettings.progressiveBlur = AnnotationProgressiveBlurSettings()
                                }
                            }

                            sectionToggle(
                                "Enable progressive blur",
                                isOn: \.progressiveBlur.isEnabled,
                                section: .progressiveBlur
                            )
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
                    .disabled(!model.backgroundSettings.progressiveBlur.isEnabled)
                    .opacity(model.backgroundSettings.progressiveBlur.isEnabled ? 1 : 0.48)
                }

                InspectorDisclosureSection(
                    title: "Watermark",
                    summary: AnnotationInspectorSummary.watermark(model.backgroundSettings.watermark),
                    isExpanded: expansionBinding(for: .watermark),
                    accessory: {
                        HStack(spacing: 5) {
                            if model.backgroundSettings.watermark != AnnotationWatermarkSettings() {
                                sectionResetButton("Reset watermark", section: .watermark) {
                                    model.backgroundSettings.watermark = AnnotationWatermarkSettings()
                                }
                            }

                            sectionToggle("Enable watermark", isOn: \.watermark.isEnabled, section: .watermark)
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
            // Reserve clearance so the final inspector controls are never
            // hidden behind the floating preview peek pill.
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                AnnotationBackgroundPresetBar(
                    model: model,
                    presetStore: backgroundPresetStore,
                    onEditorAction: onEditorAction
                )

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(height: 0.5)
            }
            .background(sidebarBackground)
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

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    private var sectionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .snappy(duration: 0.18)
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

    private func setExpanded(_ section: AnnotationInspectorAdvancedSection, _ isExpanded: Bool) {
        withAnimation(sectionAnimation) {
            if isExpanded {
                expandedAdvancedSections.insert(section)
            } else {
                expandedAdvancedSections.remove(section)
            }
        }
        AnnotationInspectorSectionState.saveExpandedSections(expandedAdvancedSections)
    }

    /// Header switch for sections with an on/off state. Turning one on opens
    /// its controls; turning it off folds them away.
    private func sectionToggle(
        _ title: LocalizedStringResource,
        isOn keyPath: WritableKeyPath<AnnotationBackgroundSettings, Bool>,
        section: AnnotationInspectorAdvancedSection
    ) -> some View {
        InspectorToggle(
            title,
            isOn: Binding(
                get: { model.backgroundSettings[keyPath: keyPath] },
                set: { value in
                    onEditorAction()
                    model.backgroundSettings[keyPath: keyPath] = value
                    setExpanded(section, value)
                }
            )
        )
    }

    private func sectionResetButton(
        _ help: String,
        section: AnnotationInspectorAdvancedSection,
        reset: @escaping () -> Void
    ) -> some View {
        InspectorResetButton(help: help) {
            onEditorAction()
            reset()
            if expandedAdvancedSections.contains(section) {
                setExpanded(section, false)
            }
        }
    }

    // MARK: Tools & style

    private var smartRedactionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            InspectorRow("Redact") {
                HStack(spacing: 6) {
                    InspectorActionButton(
                        "Pixelate",
                        systemImage: "app.background.dotted",
                        isBusy: model.isSmartRedacting
                    ) {
                        onEditorAction()
                        model.smartRedact(using: .pixelate)
                    }
                    .help("Find sensitive content and pixelate it")

                    InspectorActionButton(
                        "Blur",
                        systemImage: "drop.fill",
                        isBusy: model.isSmartRedacting
                    ) {
                        onEditorAction()
                        model.smartRedact(using: .blur)
                    }
                    .help("Find sensitive content and blur it")
                }
            }

            if model.isSmartRedacting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning screenshot…")
                        .font(.inspectorLabel)
                        .foregroundStyle(.secondary)
                }
            } else if let message = model.smartRedactionMessage {
                Text(message)
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var styleControls: some View {
        if !model.hasInspectorStyleControls {
            Text("Choose a drawing tool or select an annotation to change its style.")
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
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
}

// MARK: - Section summaries

/// One-line readouts for collapsed section headers. `nil` means the section
/// has nothing active worth announcing.
private enum AnnotationInspectorSummary {
    static func background(_ settings: AnnotationBackgroundSettings) -> String? {
        let fill: String
        switch settings.style {
        case .none:
            return nil
        case .solid(let color):
            fill = color.title
        case .gradient(let gradient):
            fill = gradient.title
        case .customWallpaper(let wallpaper):
            fill = wallpaper.title
        }
        guard settings.aspectRatio != .auto else { return fill }
        return "\(fill) · \(settings.aspectRatio.title)"
    }

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
            parts.append(String(localized: "Angled"))
        }
        if abs(settings.zoom - 1) > 0.0001 {
            parts.append(InspectorValueFormat.magnification(fractionDigits: 2).displayString(for: settings.zoom))
        }
        if abs(settings.panX) > 0.0001 || abs(settings.panY) > 0.0001 {
            parts.append(String(localized: "Panned"))
        }
        if parts.isEmpty {
            parts.append(String(localized: "FOV \(InspectorValueFormat.degrees().displayString(for: settings.fieldOfViewDegrees))"))
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

// MARK: - Tools

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 4), count: 6
    )
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Nested radius: the tray wraps tiles inset by `controlInset`.
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.tileRadius + InspectorMetrics.controlInset,
            style: .continuous
        )

        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(AnnotationTool.allCases) { tool in
                AnnotationToolCell(
                    tool: tool,
                    isSelected: selectedTool == tool,
                    action: { onSelect(tool) }
                )
            }
        }
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
        .padding(InspectorMetrics.controlInset)
        .background(shape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
        .clipShape(shape)
    }
}

private struct AnnotationToolCell: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear

                Image(systemName: tool.systemImage)
                    .font(.system(size: 13, weight: .medium))
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(isSelected ? InspectorControlPalette.selectedForeground : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                .fill(background)
                .shadow(
                    color: isSelected ? InspectorControlPalette.selectedChipShadow(for: colorScheme) : .clear,
                    radius: 1,
                    y: 0.5
                )
        }
        .help(tool.helpText)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.helpText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected {
            return InspectorControlPalette.selectedChipFill(for: colorScheme)
        }
        return isHovering ? InspectorControlPalette.hoverFill : .clear
    }
}
