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
    @State private var wallpaperStore = AnnotationWallpaperStore.shared
    @State private var isInspectorPresented = true
    @State private var isFinishing = false
    @State private var isUploading = false
    @State private var didCopyLink = false
    @FocusState private var focusedField: AnnotationEditorFocusedField?
    @Environment(\.dismiss) private var dismissWindow

    var body: some View {
        mainContent
            .navigationTitle("Screendrop Annotate")
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.isCropping {
                        cropActions
                    } else {
                        editingActions
                    }
                }
            }
            .task(id: url) {
                clearInspectorFocus()
                model.load(url: url, dismiss: dismissWindow)
            }
            .onAppear {
                Task { await wallpaperStore.reload() }
                AnnotationEditorActivationPolicy.enter(hidePreview: true)
            }
            .onDisappear {
                model.releaseEditorResources()
                AnnotationEditorActivationPolicy.leave(restorePreview: true)
            }
            .onDeleteCommand {
                model.deleteSelectedAnnotation()
            }
            .onChange(of: model.items) { _, _ in
                if didCopyLink { withAnimation(.snappy(duration: 0.2)) { didCopyLink = false } }
            }
            .onChange(of: model.backgroundSettings) { _, _ in
                if didCopyLink { withAnimation(.snappy(duration: 0.2)) { didCopyLink = false } }
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
                onActualSize: { withAnimation(.canvasZoom) { model.setZoomPercent(100) } },
                onToggleCrop: { withAnimation(.snappy(duration: 0.2)) { model.toggleCropping() } },
                onApplyCrop: { withAnimation(.snappy(duration: 0.2)) { model.applyCrop() } },
                onCancelCrop: { withAnimation(.snappy(duration: 0.2)) { model.cancelCrop() } },
                isCropping: { model.isCropping }
            ))
            .inspector(isPresented: $isInspectorPresented) {
                AnnotationEditorInspector(
                    model: model,
                    wallpaperStore: wallpaperStore,
                    focusedField: $focusedField,
                    onEditorAction: clearInspectorFocus,
                    onPickWallpaper: pickCustomWallpaper
                )
                .disabled(model.isCropping)
            }
    }

    // MARK: Toolbar actions

    /// The standard trailing actions shown when not cropping.
    @ViewBuilder
    private var editingActions: some View {
        Button(action: enterCrop) {
            Label("Crop", systemImage: "crop")
                .labelStyle(.titleAndIcon)
        }
        .help("Crop the screenshot")
        .disabled(model.previewImage == nil || model.imageSize == .zero)

        if CloudUploader.shared.isConfigured {
            Button(action: uploadAnnotation) {
                if isUploading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Uploading...")
                    }
                    .padding(.horizontal, 6)
                } else if didCopyLink {
                    Label("Link copied", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                } else {
                    Label("Upload", systemImage: "arrow.up.circle")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                }
            }
            .tint(.accentColor)
            .help("Upload to the cloud and copy the link")
            .disabled(isUploading)
        }

        Button(action: saveAs) {
            Label("Save As", systemImage: "arrow.down.circle")
                .labelStyle(.titleAndIcon)
        }
        .help("Save a copy to a location of your choice")

        Button(action: finishEditing) {
            Image(systemName: "checkmark.circle")
        }
        .help("Finish editing and save")

        Button {
            clearInspectorFocus()
            isInspectorPresented.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// The crop controls that replace the trailing actions while cropping.
    @ViewBuilder
    private var cropActions: some View {
        Menu {
            Picker("Aspect Ratio", selection: aspectBinding) {
                ForEach(CropAspectRatio.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(model.cropAspect.title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .help("Aspect ratio")

        Button {
            clearInspectorFocus()
            withAnimation(.snappy(duration: 0.18)) { model.resetCrop() }
        } label: {
            Text("Reset").padding(.horizontal, 6)
        }
        .help("Reset the selection to the whole image")

        Button(action: exitCrop) {
            Text("Cancel").padding(.horizontal, 6)
        }
        .keyboardShortcut(.cancelAction)

        Button(action: applyCropAction) {
            Text("Crop").padding(.horizontal, 8)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    }

    private var aspectBinding: Binding<CropAspectRatio> {
        Binding(
            get: { model.cropAspect },
            set: { newValue in
                clearInspectorFocus()
                withAnimation(.snappy(duration: 0.18)) { model.setCropAspect(newValue) }
            }
        )
    }

    private func enterCrop() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.beginCropping() }
    }

    private func exitCrop() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.cancelCrop() }
    }

    private func applyCropAction() {
        clearInspectorFocus()
        withAnimation(.snappy(duration: 0.22)) { model.applyCrop() }
    }

    private var mainContent: some View {
        ZStack {
            AnnotationEditorWorkspaceBackground()

            if let previewImage = model.previewImage, model.imageSize != .zero {
                AnnotationCanvas(
                    model: model,
                    image: previewImage,
                    onEditorInteraction: clearInspectorFocus
                )
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
        .overlay(alignment: .bottomTrailing) {
            if model.isCropping, model.imageSize != .zero {
                CropResolutionBadge(size: model.cropPixelSize)
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
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
        clearInspectorFocus()
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
        clearInspectorFocus()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Choose Background Wallpaper"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let wallpaper = AnnotationCustomWallpaper(url: url)
            wallpaperStore.addRecentWallpaper(url)
            model.backgroundSettings.customWallpaper = wallpaper
            model.backgroundSettings.style = .customWallpaper(wallpaper)
        }
    }

    private func uploadAnnotation() {
        clearInspectorFocus()
        guard let sourceURL = model.sourceURL, !isUploading else { return }

        let baseURL = model.baseImageURL ?? sourceURL
        let items = model.items
        let backgroundSettings = model.backgroundSettings
        let hasContent = !items.isEmpty || backgroundSettings.hasRenderableContent || model.isCropped

        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                // Persist the current annotations first so the uploaded file
                // matches what's saved in history, then upload that file. The
                // editor stays open.
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
                    // The display image is now the composite; repoint the editor
                    // at the preserved base snapshot so continued edits don't
                    // re-bake annotations on top of an already-composited image.
                    model.baseImageURL = ScreenshotHistoryStore.baseImageURL(for: resultURL)
                } else {
                    resultURL = ScreenshotHistoryStore.shared.removeAnnotations(displayURL: sourceURL)
                    model.baseImageURL = resultURL
                }

                _ = ScreenshotPreviewStack.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )

                let result = try await CloudUploader.shared.upload(itemID: UUID(), fileURL: resultURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: resultURL, cloudURL: result.url)
                withAnimation(.snappy(duration: 0.2)) { didCopyLink = true }
            } catch {
                model.errorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishEditing() {
        clearInspectorFocus()
        guard let sourceURL = model.sourceURL else {
            model.releaseEditorResources()
            dismissWindow()
            return
        }

        guard !isFinishing else { return }

        let baseURL = model.baseImageURL ?? sourceURL
        let items = model.items
        let backgroundSettings = model.backgroundSettings
        let hasContent = !items.isEmpty || backgroundSettings.hasRenderableContent || model.isCropped
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
                PreviewPanelPresenter.shared.show(displayID: nil)
            }
            model.releaseEditorResources()
            dismissWindow()
        } catch {
            isFinishing = false
            model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
        }
    }

    private func clearInspectorFocus() {
        focusedField = nil
    }
}
