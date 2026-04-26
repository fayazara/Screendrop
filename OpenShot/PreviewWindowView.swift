//
//  PreviewWindowView.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//
//  Single screenshot preview window.
//

import SwiftUI
import UniformTypeIdentifiers

struct PreviewWindowView: View {
    @Binding var url: URL?
    @AppStorage(OpenShotPreferences.autoSaveKey) private var autoSave = false
    @AppStorage(OpenShotPreferences.autoCopyKey) private var autoCopy = false
    
    @State private var previewImage: NSImage?
    @State private var isHovered = false
    @State private var hideView = false
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @State private var popoverAnchorView: NSView?
    @State private var autoSavedURL: URL?
    @Environment(\.dismiss) private var dismissWindow
    
    var body: some View {
        ZStack {
            if let previewImage, let url {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 220, height: 165)
                    .clipped()
                    .overlay {
                        if isHovered {
                            HoveredContent()
                        }
                    }
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 12)
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
                    .background(PopoverAnchorView(anchorView: $popoverAnchorView))
                    .opacity(hideView ? 0 : 1)
                    .draggable(url) {
                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(.rect(cornerRadius: cornerRadius))
                    }
                    .onDragSessionUpdated { session in
                        switch session.phase {
                        case .active:
                            QuickLookPreviewPresenter.dismiss()
                            hideView = true
                        case .ended:
                            dismissWindow()
                        default:
                            break
                        }
                    }
                    .onHover { status in
                        withAnimation(animation) {
                            isHovered = status
                        }
                    }
                    .transition(.push(from: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onAppear(perform: loadPreview)
        .onDisappear(perform: tearDown)
        .padding(.trailing, 28)
        .padding(.bottom, 32)
    }
    
    // MARK: - Hover Overlay
    
    @ViewBuilder
    private func HoveredContent() -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            
            Button {
                QuickLookPreviewPresenter.dismiss()
                dismissWindow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.black, .white)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(10)
            
            VStack(spacing: 10) {
                Button {
                    copyToClipboard()
                } label: {
                    Text("Copy")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.background.opacity(0.8), in: .capsule)
                }
                .buttonStyle(.plain)
                
                Button {
                    saveScreenshot()
                } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.background.opacity(0.8), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }
    
    // MARK: - Lifecycle
    
    private func loadPreview() {
        guard let url,
              let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 520) else {
            dismissWindow()
            return
        }
        
        withAnimation(animation) {
            previewImage = image
        }
        NSSound(named: "Tink")?.play()
        
        if autoSave {
            autoSaveIfNeeded()
        }
        
        if autoCopy {
            copyToClipboard(shouldDismiss: false)
        }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handlePreviewKey(event) {
                return nil
            }
            
            return event
        }
        
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if isHovered || QuickLookPreviewPresenter.isShown {
                _ = handlePreviewKey(event)
            }
        }
    }
    
    private func tearDown() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        
        keyMonitor = nil
        globalKeyMonitor = nil
        QuickLookPreviewPresenter.dismiss()
    }
    
    // MARK: - Actions
    
    private func saveScreenshot() {
        guard let url else { return }
        
        if autoSave {
            autoSaveIfNeeded()
            QuickLookPreviewPresenter.dismiss()
            dismissWindow()
            return
        }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.canCreateDirectories = true
        panel.title = "Save Screenshot"
        
        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                do {
                    try FileManager.default.copyItem(at: url, to: destURL)
                } catch {
                    print("Failed to save: \(error)")
                }
            }
        }
    }
    
    private func copyToClipboard() {
        copyToClipboard(shouldDismiss: true)
    }
    
    private func copyToClipboard(shouldDismiss: Bool) {
        guard let url else { return }
        
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
        } catch {
            print("Failed to copy screenshot: \(error)")
            return
        }
        
        if shouldDismiss {
            QuickLookPreviewPresenter.dismiss()
            dismissWindow()
        }
    }
    
    private func autoSaveIfNeeded() {
        guard autoSavedURL == nil, let url else { return }
        
        do {
            autoSavedURL = try ScreenshotFileActions.saveToDefaultLocation(from: url)
        } catch {
            print("Failed to auto save: \(error)")
        }
    }
    
    private func openLargePreview() {
        guard let url else { return }
        QuickLookPreviewPresenter.show(
            url: url,
            sourceView: popoverAnchorView,
            sourceImage: previewImage
        )
    }
    
    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, QuickLookPreviewPresenter.isShown {
            QuickLookPreviewPresenter.dismiss()
            return true
        }
        
        if event.keyCode == 49, isHovered, previewImage != nil {
            DispatchQueue.main.async {
                openLargePreview()
            }
            return true
        }
        
        return false
    }
    
    private var animation: Animation {
        .smooth(duration: 0.3, extraBounce: 0)
    }
    
    private var cornerRadius: CGFloat {
        16
    }
}

private struct PopoverAnchorView: NSViewRepresentable {
    @Binding var anchorView: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            anchorView = view
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            anchorView = nsView
        }
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        QuickLookPreviewPresenter.dismiss()
    }
}
