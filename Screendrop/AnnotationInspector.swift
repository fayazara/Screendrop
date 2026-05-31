//
//  AnnotationInspector.swift
//  Screendrop
//

import AppKit
import SwiftUI

// MARK: - Inspector

struct AnnotationEditorInspector: View {
    private static let minimumColumnWidth: CGFloat = 260
    private static let idealColumnWidth: CGFloat = 280
    private static let maximumColumnWidth: CGFloat = 440

    @Bindable var model: AnnotationEditorModel
    let onPickWallpaper: () -> Void
    let onSaveAs: () -> Void
    let onDone: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // MARK: Tools
                    VStack(alignment: .leading, spacing: 10) {
                        AnnotationInspectorSectionHeader("TOOLS")
                        AnnotationInspectorToolGrid(selectedTool: model.selectedTool) { tool in
                            model.selectTool(tool)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 16)

                    if model.inspectedTool != nil {
                        AnnotationInspectorDivider()

                        // MARK: Style
                        VStack(alignment: .leading, spacing: 10) {
                            AnnotationInspectorSectionHeader("STYLE")

                            if model.selectionCount > 1 {
                                Text("\(model.selectionCount) annotations selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            AnnotationInspectorRow(title: "Color") {
                                AnnotationColorMenu(selectedSwatch: model.selectedSwatch) { swatch in
                                    model.setSwatch(swatch)
                                }
                            }

                            if model.isStrokeStyleAvailable {
                                AnnotationInspectorRow(title: "Stroke") {
                                    AnnotationStrokeMenu(strokeWidth: model.strokeWidth) { strokeWidth in
                                        model.setStrokeWidth(strokeWidth)
                                    }
                                }
                            }

                            if model.isRedactionStyleAvailable {
                                AnnotationBackgroundSlider(
                                    title: "Density",
                                    value: Binding(
                                        get: { model.redactionDensity },
                                        set: { model.setRedactionDensity($0) }
                                    ),
                                    range: 0.15...1
                                )
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }

                    if model.isTextStyleAvailable {
                        AnnotationInspectorDivider()

                        // MARK: Text
                        VStack(alignment: .leading, spacing: 10) {
                            AnnotationInspectorSectionHeader("TEXT")
                            AnnotationTextStyleControls(model: model)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }

                    AnnotationInspectorDivider()

                    // MARK: Background
                    VStack(alignment: .leading, spacing: 12) {
                        AnnotationInspectorSectionHeader("BACKGROUND")

                        AnnotationBackgroundInspector(
                            settings: Binding(
                                get: { model.backgroundSettings },
                                set: { model.backgroundSettings = $0 }
                            ),
                            onPickWallpaper: onPickWallpaper
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectSoftIfAvailable()
            .background(sidebarBackground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                Button(action: onSaveAs) {
                    Text("Save as...")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .controlSize(.large)

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(sidebarBackground)
        }
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

private struct AnnotationInspectorSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}

private struct AnnotationInspectorDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 14)
    }
}

private struct AnnotationInspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 2), count: 6
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    onSelect(tool)
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTool == tool ? Color.accentColor : .primary.opacity(0.7))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selectedTool == tool ? Color.accentColor.opacity(0.15) : .clear)
                )
                .help(tool.title)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}
