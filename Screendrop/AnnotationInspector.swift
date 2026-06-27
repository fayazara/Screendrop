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

struct AnnotationEditorInspector: View {
    private static let minimumColumnWidth: CGFloat = 260
    private static let idealColumnWidth: CGFloat = 280
    private static let maximumColumnWidth: CGFloat = 440

    @Bindable var model: AnnotationEditorModel
    @Bindable var wallpaperStore: AnnotationWallpaperStore
    let focusedField: FocusState<AnnotationEditorFocusedField?>.Binding
    let onEditorAction: () -> Void
    let onPickWallpaper: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Tools") {
                    AnnotationInspectorToolGrid(selectedTool: model.selectedTool) { tool in
                        onEditorAction()
                        model.selectTool(tool)
                    }
                }

                InspectorSectionDivider()

                InspectorSection("Smart Redaction") {
                    HStack(spacing: 8) {
                        SmartRedactionButton(
                            title: "Pixelate",
                            systemImage: "app.background.dotted",
                            isRunning: model.isSmartRedacting
                        ) {
                            onEditorAction()
                            model.smartRedact(using: .pixelate)
                        }

                        SmartRedactionButton(
                            title: "Blur",
                            systemImage: "drop.fill",
                            isRunning: model.isSmartRedacting
                        ) {
                            onEditorAction()
                            model.smartRedact(using: .blur)
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

                if model.inspectedTool != nil {
                    InspectorSectionDivider()

                    InspectorSection("Style") {
                        if model.selectionCount > 1 {
                            Text("\(model.selectionCount) annotations selected")
                                .font(.inspectorLabel)
                                .foregroundStyle(.secondary)
                        }

                        InspectorRow("Color") {
                            AnnotationColorMenu(selectedSwatch: model.selectedSwatch) { swatch in
                                onEditorAction()
                                model.setSwatch(swatch)
                            }
                        }

                        if model.isStrokeStyleAvailable {
                            InspectorRow("Stroke") {
                                AnnotationStrokeMenu(strokeWidth: model.strokeWidth) { strokeWidth in
                                    onEditorAction()
                                    model.setStrokeWidth(strokeWidth)
                                }
                            }
                        }

                        if model.isRedactionStyleAvailable {
                            InspectorSlider(
                                "Density",
                                value: Binding(
                                    get: { model.redactionDensity },
                                    set: {
                                        onEditorAction()
                                        model.setRedactionDensity($0)
                                    }
                                ),
                                range: 0.15...1,
                                formatted: { "\(Int(($0 * 100).rounded()))%" }
                            )
                        }
                    }
                }

                if model.isTextStyleAvailable {
                    InspectorSectionDivider()

                    InspectorSection("Text") {
                        AnnotationTextStyleControls(model: model)
                    }
                }

                InspectorSectionDivider()

                InspectorSection(
                    title: "Background",
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

                InspectorSectionDivider()

                InspectorSection("Watermark") {
                    AnnotationWatermarkInspector(
                        settings: Binding(
                            get: { model.backgroundSettings.watermark },
                            set: { model.backgroundSettings.watermark = $0 }
                        ),
                        focusedField: focusedField
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Reserve clearance so the last control (aspect ratio) is never
            // hidden behind the floating preview peek pill.
            .padding(.bottom, PreviewPeekTab.pillHeight * 1.1)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectSoftIfAvailable()
        .background(sidebarBackground)
        .inspectorColumnWidth(
            min: Self.minimumColumnWidth,
            ideal: Self.idealColumnWidth,
            max: Self.maximumColumnWidth
        )
        .frame(
            minWidth: Self.minimumColumnWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var sidebarBackground: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }
}

// MARK: - Smart redaction

private struct SmartRedactionButton: View {
    let title: String
    let systemImage: String
    let isRunning: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.inspectorValue)
            }
            .foregroundStyle(.primary.opacity(0.85))
            .frame(maxWidth: .infinity)
            .inspectorField(height: 28)
            .overlay {
                if isHovering && !isRunning {
                    RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .opacity(isRunning ? 0.5 : 1)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Tools

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 4), count: 6
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(AnnotationTool.allCases) { tool in
                AnnotationToolCell(
                    tool: tool,
                    isSelected: selectedTool == tool,
                    action: { onSelect(tool) }
                )
            }
        }
    }
}

private struct AnnotationToolCell: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : .primary.opacity(0.75))
        .background(
            RoundedRectangle(cornerRadius: InspectorMetrics.tileRadius, style: .continuous)
                .fill(background)
        )
        .help(tool.title)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        return isHovering ? Color.primary.opacity(0.07) : .clear
    }
}
