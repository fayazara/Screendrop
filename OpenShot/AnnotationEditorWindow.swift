//
//  AnnotationEditorWindow.swift
//  OpenShot
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
            .navigationTitle("OpenShot Annotate")
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
                AnnotationEditorActivationPolicy.enter()
            }
            .onDisappear {
                AnnotationEditorActivationPolicy.leave()
            }
            .onDeleteCommand {
                model.deleteSelectedAnnotation()
            }
            .background(AnnotationKeyCommandHandler(
                onDelete: model.deleteSelectedAnnotation,
                onUndo: model.undo,
                onRedo: model.redo,
                onSelectAll: model.selectAllAnnotations,
                onSelectTool: model.selectTool
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Save Annotated Screenshot"

        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }

            do {
                try AnnotationRenderer.render(
                    sourceURL: sourceURL,
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
            dismissWindow()
            return
        }

        guard !isFinishing else { return }

        guard !model.items.isEmpty || model.backgroundSettings.isEnabled else {
            dismissWindow()
            return
        }

        isFinishing = true
        do {
            let annotatedURL = try AnnotationRenderer.renderToTemporaryFile(
                sourceURL: sourceURL,
                items: model.items,
                backgroundSettings: model.backgroundSettings
            )
            let updatedExistingPreview = ScreenshotPreviewStack.shared.replace(originalURL: sourceURL, with: annotatedURL)
            if !updatedExistingPreview {
                openWindow(id: "PREVIEWWINDOW")
            }
            dismissWindow()
        } catch {
            isFinishing = false
            model.errorMessage = "Failed to finish annotation: \(error.localizedDescription)"
        }
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
