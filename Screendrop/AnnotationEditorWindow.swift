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
    @State private var backgroundPresetStore = AnnotationBackgroundPresetStore.shared
    @State private var isInspectorPresented = true
    /// The tool dock and the crop bar share glass, so one morphs into the
    /// other.
    @Namespace private var toolbarGlass
    @State private var isFinishing = false
    @State private var isSaving = false
    @State private var isUploading = false
    @State private var closeGuard = EditorCloseGuard()
    @State private var didCopyLink = false
    @State private var saveFlash = false
    @State private var isToolbarShareOptionsPresented = false
    @FocusState private var focusedField: AnnotationEditorFocusedField?
    @Environment(\.dismiss) private var dismissWindow

    private var isBusy: Bool { isSaving || isFinishing || isUploading || model.isCommitting }

    var body: some View {
        mainContent
            .disabled(model.isCommitting)
            .allowsHitTesting(!model.isCommitting)
            .modifier(CaptureLibraryEditorRegistration(url: url))
            .navigationTitle("Screendrop Annotate")
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    toolbarActions
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
                closeGuard.detach()
                model.releaseEditorResources()
                AnnotationEditorActivationPolicy.leave(restorePreview: true)
            }
            .onWindowChange { window in
                guard let window else {
                    closeGuard.detach()
                    return
                }
                configureCloseGuard()
                closeGuard.attach(to: window)
                closeGuard.refreshDocumentEdited()
            }
            .onDeleteCommand {
                if !model.isCommitting { model.deleteSelectedAnnotation() }
            }
            .onChange(of: model.hasUnsavedChanges) { _, _ in
                closeGuard.refreshDocumentEdited()
            }
            .onChange(of: model.revision) { _, _ in
                closeGuard.refreshDocumentEdited()
                if didCopyLink { withAnimation(.morphQuickIfAllowed) { didCopyLink = false } }
            }
            .onChange(of: model.backgroundSettings) { _, _ in
                closeGuard.refreshDocumentEdited()
                if didCopyLink { withAnimation(.morphQuickIfAllowed) { didCopyLink = false } }
            }
            .onChange(of: model.baseImageURL) { _, _ in
                // Cropping replaces the base image rather than touching the
                // engine, so it never bumps `revision`.
                closeGuard.refreshDocumentEdited()
            }
            .background(AnnotationKeyCommandHandler(
                isEnabled: { !model.isCommitting },
                onDelete: model.deleteSelectedAnnotation,
                onSave: saveEdits,
                onUndo: model.undo,
                onRedo: model.redo,
                onSelectAll: model.selectAllAnnotations,
                onSelectTool: model.selectTool,
                onZoomIn: model.zoomIn,
                onZoomOut: model.zoomOut,
                onFitCanvas: model.fitCanvas,
                onActualSize: { model.setZoomPercent(100) },
                onToggleCrop: { withAnimation(.canvasMoveIfAllowed) { model.toggleCropping() } },
                onApplyCrop: applyCropAction,
                onCancelCrop: { withAnimation(.canvasMoveIfAllowed) { model.cancelCrop() } },
                onNudgeCrop: model.nudgeCrop(by:),
                isCropping: { model.isCropping }
            ))
            .inspector(isPresented: $isInspectorPresented) {
                AnnotationEditorInspector(
                    model: model,
                    wallpaperStore: wallpaperStore,
                    backgroundPresetStore: backgroundPresetStore,
                    focusedField: $focusedField,
                    onEditorAction: clearInspectorFocus,
                    onPickWallpaper: pickCustomWallpaper
                )
                .disabled(model.isCropping || model.isCommitting)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    actionFooter
                        .background(Palette.panel)
                }
            }
    }

    // MARK: Toolbar actions

    /// Save and the inspector toggle. Crop lives at the end of the tool
    /// dock, which morphs into the crop bar. Share, Save As and Done live in
    /// the inspector's footer, and move up here while the inspector is
    /// hidden rather than floating over the canvas.
    @ViewBuilder
    private var toolbarActions: some View {
        if !isInspectorPresented {
            finishingToolbarActions
        }

        Button(action: saveEdits) {
            Label(saveFlash ? "Saved" : "Save", systemImage: saveFlash ? "checkmark" : "square.and.arrow.down")
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace.downUp))
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled((!model.hasUnsavedChanges && !saveFlash) || isBusy || model.isCropping)
        .help(model.hasUnsavedChanges ? "Save annotations (⌘S)" : "All changes saved")
        .motion(.morphQuick, value: saveFlash)

        Button {
            clearInspectorFocus()
            withAnimation(.morphIfAllowed) { isInspectorPresented.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
    }

    /// The footer's actions as toolbar buttons, for when the inspector and
    /// its footer are hidden.
    @ViewBuilder
    private var finishingToolbarActions: some View {
        let isDisabled = isBusy || model.isCropping

        if CloudUploader.shared.isConfigured {
            Button {
                isToolbarShareOptionsPresented = true
            } label: {
                Label(
                    didCopyLink ? "Link Copied" : "Share",
                    systemImage: didCopyLink ? "checkmark" : isUploading ? "arrow.up.circle" : "link"
                )
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace.downUp))
            }
            .disabled(isDisabled)
            .help(isUploading ? "Uploading…" : "Share a link")
            .popover(isPresented: $isToolbarShareOptionsPresented, arrowEdge: .bottom) {
                CloudUploadOptionsPopover(
                    suggestedTitle: model.sourceURL?.deletingPathExtension().lastPathComponent ?? "",
                    onConfirm: uploadAnnotation
                )
            }
        }

        Button(action: saveAs) {
            Label("Save a Copy As…", systemImage: "square.and.arrow.down.on.square")
                .labelStyle(.iconOnly)
        }
        .disabled(isDisabled)
        .help("Save a Copy As…")

        Button(action: finishEditing) {
            Label(isFinishing ? "Saving…" : "Done", systemImage: "checkmark")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.glassProminent)
        .tint(Palette.accent)
        .foregroundStyle(Palette.onAccent)
        .disabled(isDisabled)
        .help("Save and close")
    }

    /// Share, Save As and Done, built like Studio's Share/Export footer.
    private var actionFooter: some View {
        AnnotationActionFooter(
            canShare: CloudUploader.shared.isConfigured,
            isUploading: isUploading,
            didCopyLink: didCopyLink,
            isFinishing: isFinishing,
            isBusy: isBusy || model.isCropping,
            suggestedTitle: model.sourceURL?.deletingPathExtension().lastPathComponent ?? "",
            onUpload: uploadAnnotation,
            onSaveAs: saveAs,
            onDone: finishEditing
        )
    }

    private func enterCrop() {
        clearInspectorFocus()
        withAnimation(.canvasMoveIfAllowed) { model.beginCropping() }
    }

    private func exitCrop() {
        clearInspectorFocus()
        withAnimation(.canvasMoveIfAllowed) { model.cancelCrop() }
    }

    private func applyCropAction() {
        clearInspectorFocus()
        // Not animated: the crop first lands where its box was, and the canvas
        // animates the fit from there (`canvasRevealID`).
        model.applyCrop()
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
            } else if let errorMessage = model.errorMessage {
                // A load failure (missing/unreadable source file, e.g. a stale
                // URL replayed by macOS window restoration) should never sit
                // behind an unexplained spinner with no way out.
                AnnotationLoadFailureView(message: errorMessage, onClose: closeAfterLoadFailure)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .clipped()
        .overlay(alignment: .bottom) {
            if hasImage {
                bottomChrome
            }
        }
        // The canvas reframes here; overshoot on the image reads as a whip.
        // Crop changes animate where they are made, not here: applying a crop
        // must land on the box before it moves.
        .motion(.canvasMove, value: isInspectorPresented)
    }

    private var hasImage: Bool {
        model.previewImage != nil && model.imageSize != .zero
    }

    /// The row floating along the bottom of the canvas: zoom on the left,
    /// the tool dock - or, while cropping, the crop bar - in the middle, and
    /// the crop size on the right. Messages rise above the middle.
    private var bottomChrome: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 8) {
                AnnotationZoomControl(model: model)
                if model.isPreviewDownscaled {
                    LowResolutionPreviewNotice()
                }
                Spacer(minLength: 0)
                if model.isCropping {
                    CropResolutionBadge(size: model.cropPixelSize)
                        .transition(.blurPop)
                }
            }
            .frame(height: AnnotationToolDock.height)
            .padding(.horizontal, 16)

            VStack(spacing: 10) {
                if let message = toastMessage {
                    AnnotationDockToast(
                        text: message.text,
                        systemImage: message.isError ? "exclamationmark.triangle.fill" : "sparkles"
                    )
                    .id(message.text)
                    .onTapGesture(perform: clearToast)
                    .help("Click to dismiss")
                    .transition(.rise)
                }

                GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                    if model.isCropping {
                        GlassCropBar(
                            aspect: model.cropAspect,
                            onAspectChange: { aspect in
                                clearInspectorFocus()
                                withAnimation(.canvasMoveIfAllowed) { model.setCropAspect(aspect) }
                            },
                            onReset: {
                                clearInspectorFocus()
                                withAnimation(.canvasMoveIfAllowed) { model.resetCrop() }
                            },
                            onCancel: exitCrop,
                            onApply: applyCropAction,
                            namespace: toolbarGlass
                        )
                        .frame(height: AnnotationToolDock.height)
                    } else {
                        AnnotationToolDock(
                            model: model,
                            onEditorAction: clearInspectorFocus,
                            canCrop: !isBusy,
                            onCrop: enterCrop,
                            glass: toolbarGlass
                        )
                    }
                }
                // The canvas moves on `canvasMove`; the bars keep the morph.
                .motion(.morph, value: model.isCropping)
            }
        }
        .padding(.bottom, AnnotationToolDock.bottomPadding)
        .motion(.morph, value: toastMessage?.text)
        // Every message leaves on its own; errors stay long enough to read.
        .task(id: toastMessage?.text) {
            guard let message = toastMessage else { return }
            try? await Task.sleep(for: .seconds(message.isError ? 5 : 2.6))
            guard !Task.isCancelled else { return }
            clearToast()
        }
    }

    /// Clears whichever message the toast is showing.
    private func clearToast() {
        withAnimation(.morphIfAllowed) {
            if model.errorMessage != nil, model.previewImage != nil {
                model.errorMessage = nil
            } else {
                model.smartRedactionMessage = nil
            }
        }
    }

    /// Inline save or upload failures, then automatic-redaction results.
    private var toastMessage: (text: String, isError: Bool)? {
        if let error = model.errorMessage, model.previewImage != nil { return (error, true) }
        if let message = model.smartRedactionMessage { return (message, false) }
        return nil
    }

    private func closeAfterLoadFailure() {
        model.releaseEditorResources()
        dismissWindow()
    }

    private func saveAs() {
        clearInspectorFocus()
        guard !isBusy, let sourceURL = model.sourceURL else { return }
        let baseURL = model.baseImageURL ?? sourceURL

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Save Annotated Screenshot"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            Task {
                do {
                    try await AnnotationRenderer.renderInBackground(
                        sourceURL: baseURL,
                        shapes: model.shapes,
                        backgroundSettings: model.backgroundSettings,
                        destinationURL: destinationURL,
                        contentType: ScreenshotFileActions.exportContentType
                    )
                } catch {
                    model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
                }
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

    private func uploadAnnotation(options: CloudUploadOptions) {
        clearInspectorFocus()
        guard model.sourceURL != nil, !isBusy else { return }

        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                // Persist the current annotations first so the uploaded file
                // matches what's saved in history, then upload that file. The
                // editor stays open.
                guard let sourceURL = model.sourceURL else { return }
                let resultURL = try await model.commitEdits() ?? sourceURL

                _ = CaptureShelf.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )

                let result = try await CloudUploader.shared.upload(
                    itemID: UUID(),
                    fileURL: resultURL,
                    title: options.trimmedTitleOrNil,
                    socialEnabled: options.socialEnabled
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: resultURL, cloudURL: result.url)
                withAnimation(.morphQuickIfAllowed) { didCopyLink = true }
            } catch {
                model.errorMessage = "Upload failed: \(error.localizedDescription)"
            }
        }
    }

    /// Cmd-S. Commits without closing, so long editing sessions have a
    /// checkpoint that isn't "press Done and start over".
    private func saveEdits() {
        clearInspectorFocus()
        // Committing re-renders the composite, so a Cmd-S with nothing
        // changed should cost nothing.
        guard model.sourceURL != nil, model.hasUnsavedChanges, !isBusy else { return }

        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                guard let sourceURL = model.sourceURL,
                      let resultURL = try await model.commitEdits() else { return }
                _ = CaptureShelf.shared.applyAnnotation(
                    originalURL: sourceURL,
                    historyURL: resultURL
                )
                saveFlash = true
                try? await Task.sleep(for: .seconds(1.4))
                saveFlash = false
            } catch {
                model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
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

        guard !isBusy else { return }

        isFinishing = true
        Task {
            do {
                if let resultURL = try await model.commitEdits() {
                    let updatedExistingPreview = CaptureShelf.shared.applyAnnotation(
                        originalURL: sourceURL,
                        historyURL: resultURL,
                        addsIfMissing: true
                    )
                    if !updatedExistingPreview {
                        CaptureShelfPresenter.shared.show(displayID: nil)
                    }
                }
                guard !model.hasUnsavedChanges else {
                    isFinishing = false
                    return
                }
                model.releaseEditorResources()
                dismissWindow()
            } catch {
                isFinishing = false
                model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
            }
        }
    }

    private func configureCloseGuard() {
        closeGuard.canClose = { [weak model] in model?.isCommitting != true }
        closeGuard.hasUnsavedChanges = { [weak model] in model?.hasUnsavedChanges ?? false }
        // A screenshot is already in History whether or not it is annotated,
        // so there is no "delete the whole thing" case here.
        closeGuard.offersDelete = { false }
        closeGuard.projectName = { [weak model] in model?.sourceURL?.lastPathComponent ?? "this screenshot" }
        // Capture only the model, not this view and its @State close guard.
        closeGuard.onDecision = { [weak model] decision, done in
            guard let model else { return }
            switch decision {
            case .save:
                Task {
                    do {
                        if let sourceURL = model.sourceURL,
                           let resultURL = try await model.commitEdits() {
                            _ = CaptureShelf.shared.applyAnnotation(
                                originalURL: sourceURL,
                                historyURL: resultURL
                            )
                        }
                        guard !model.hasUnsavedChanges else { return }
                        model.releaseEditorResources()
                        done()
                    } catch {
                        model.errorMessage = "Failed to save annotation: \(error.localizedDescription)"
                    }
                }
            case .discard:
                model.releaseEditorResources()
                done()
            case .delete, .cancel:
                break
            }
        }
    }

    private func clearInspectorFocus() {
        focusedField = nil
    }
}

private struct AnnotationLoadFailureView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
    }
}
