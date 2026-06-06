//
//  AnnotationEditorWindow.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AnnotationEditorWindow: View {
    @Binding var url: URL?

    @State private var model = AnnotationEditorModel()
    @State private var isInspectorPresented = true
    @State private var isFinishing = false
    @Environment(\.dismiss) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        mainContent
            .navigationTitle("Screendrop Annotate")
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
                }
            }
            .task(id: url) {
                model.load(url: url, dismiss: dismissWindow)
            }
            .onAppear {
                AnnotationEditorActivationPolicy.enter(hidePreview: true)
            }
            .onDisappear {
                model.releaseEditorResources()
                AnnotationEditorActivationPolicy.leave(restorePreview: true)
            }
            .onDeleteCommand {
                model.deleteSelectedAnnotation()
            }
            .background(AnnotationKeyCommandHandler(
                onDelete: model.deleteSelectedAnnotation,
                onUndo: model.undo,
                onRedo: model.redo,
                onSelectAll: model.selectAllAnnotations,
                onSelectTool: model.selectTool,
                onZoomIn: { withAnimation(.canvasZoom) { model.zoomIn() } },
                onZoomOut: { withAnimation(.canvasZoom) { model.zoomOut() } },
                onFitCanvas: { withAnimation(.canvasZoom) { model.fitCanvas() } },
                onActualSize: { withAnimation(.canvasZoom) { model.setZoomPercent(100) } }
            ))
            .inspector(isPresented: $isInspectorPresented) {
                AnnotationEditorInspector(
                    model: model,
                    onPickWallpaper: pickCustomWallpaper,
                    onSaveAs: saveAs,
                    onDone: finishEditing
                )
            }
    }

    private var mainContent: some View {
        ZStack {
            AnnotationEditorWorkspaceBackground()

            if let previewImage = model.previewImage, model.imageSize != .zero {
                AnnotationCanvas(model: model, image: previewImage)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 28)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if model.previewImage != nil, model.imageSize != .zero {
                HStack(spacing: 8) {
                    AnnotationZoomControl(model: model)

                    if model.isPreviewDownscaled {
                        LowResolutionPreviewNotice()
                    }
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
    }

    private func saveAs() {
        guard let sourceURL = model.sourceURL else { return }
        let baseURL = model.baseImageURL ?? sourceURL

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Save Annotated Screenshot"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                try AnnotationRenderer.render(
                    sourceURL: baseURL,
                    items: model.items,
                    backgroundSettings: model.backgroundSettings,
                    destinationURL: destinationURL,
                    contentType: ScreenshotFileActions.exportContentType
                )
            } catch {
                model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
            }
        }
    }

    private func pickCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Background Wallpaper"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let wallpaper = AnnotationCustomWallpaper(url: url)
            model.backgroundSettings.customWallpaper = wallpaper
            model.backgroundSettings.style = .customWallpaper(wallpaper)
        }
    }

    private func finishEditing() {
        guard let sourceURL = model.sourceURL else {
            model.releaseEditorResources()
            dismissWindow()
            return
        }

        guard !isFinishing else { return }

        let baseURL = model.baseImageURL ?? sourceURL
        let items = model.items
        let backgroundSettings = model.backgroundSettings
        let hasContent = !items.isEmpty || backgroundSettings.isEnabled
        let hadDocument = ScreenshotHistoryStore.shared.hasEditDocument(for: sourceURL)

        // Nothing drawn and nothing previously saved -- just close.
        guard hasContent || hadDocument else {
            model.releaseEditorResources()
            dismissWindow()
            return
        }

        isFinishing = true
        do {
            let resultURL: URL
            if hasContent {
                let annotatedURL = try AnnotationRenderer.renderToTemporaryFile(
                    sourceURL: baseURL,
                    items: items,
                    backgroundSettings: backgroundSettings
                )
                let document = AnnotationDocument(items: items, background: backgroundSettings)
                resultURL = ScreenshotHistoryStore.shared.commitAnnotations(
                    displayURL: sourceURL,
                    baseURL: baseURL,
                    renderedURL: annotatedURL,
                    document: document
                )
            } else {
                // All annotations were cleared on a previously-edited image:
                // restore the untouched original.
                resultURL = ScreenshotHistoryStore.shared.removeAnnotations(displayURL: sourceURL)
            }

            let updatedExistingPreview = ScreenshotPreviewStack.shared.applyAnnotation(
                originalURL: sourceURL,
                historyURL: resultURL
            )
            if !updatedExistingPreview {
                openWindow(id: "PREVIEWWINDOW")
            }
            model.releaseEditorResources()
            dismissWindow()
        } catch {
            isFinishing = false
            model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
        }
    }
}

private extension Animation {
    /// Animation used for discrete zoom changes (menu, shortcuts, zoom in/out).
    static var canvasZoom: Animation { .smooth(duration: 0.24) }
}

private struct AnnotationZoomControl: View {
    @Bindable var model: AnnotationEditorModel

    private func zoom(_ change: () -> Void) {
        withAnimation(.canvasZoom, change)
    }

    var body: some View {
        Menu {
            Button("Zoom In") { zoom { model.zoomIn() } }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { zoom { model.zoomOut() } }
                .keyboardShortcut("-", modifiers: .command)

            Divider()

            Button("Fit Canvas") { zoom { model.fitCanvas() } }
                .keyboardShortcut("1", modifiers: .command)

            Divider()

            Button("50%") { zoom { model.setZoomPercent(50) } }
            Button("100%") { zoom { model.setZoomPercent(100) } }
                .keyboardShortcut("0", modifiers: .command)
            Button("200%") { zoom { model.setZoomPercent(200) } }
        } label: {
            Text("\(model.zoomPercent)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 38)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .help("Zoom")
    }
}

/// A small badge shown beside the zoom control when the editing preview is
/// downscaled to save memory. Collapsed it's just an "i" button; tapping it
/// expands an explanation that the reduction is preview-only and points users
/// to Settings to disable it.
private struct LowResolutionPreviewNotice: View {
    @State private var isExpanded = false

    private let diameter: CGFloat = 28

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: diameter, height: diameter)

                if isExpanded {
                    Text("Low-res preview to save memory — exports stay full quality")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .frame(height: diameter)
            .fixedSize()
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Why is this preview low resolution?")
    }
}

private struct AnnotationEditorWorkspaceBackground: View {
    private let dotSpacing: CGFloat = 18
    private let dotRadius: CGFloat = 1.15

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            Canvas { context, size in
                var path = Path()
                let offset = dotSpacing / 2

                stride(from: offset, through: size.width, by: dotSpacing).forEach { x in
                    stride(from: offset, through: size.height, by: dotSpacing).forEach { y in
                        path.addEllipse(in: CGRect(
                            x: x - dotRadius,
                            y: y - dotRadius,
                            width: dotRadius * 2,
                            height: dotRadius * 2
                        ))
                    }
                }

                context.fill(path, with: .color(Color.secondary.opacity(0.14)))
            }
            .allowsHitTesting(false)
        }
    }
}
