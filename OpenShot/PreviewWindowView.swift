//
//  PreviewWindowView.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//
//  Screenshot preview that slides in from bottom-right.
//  Pattern adapted from Kavsoft's ScreenshotPreviewAnimation template.
//

import SwiftUI
import UniformTypeIdentifiers

struct PreviewWindowView: View {
    @Binding var url: URL?
    /// View Properties
    @State private var previewImage: NSImage?
    @State private var isHovered: Bool = false
    @State private var hideView: Bool = false
    @State private var keyMonitor: Any?
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
                .opacity(hideView ? 0 : 1)
                .draggable(url) {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: cornerRadius))
                }
                .onDragSessionUpdated { session in
                    let phase = session.phase
                    
                    if phase == .active {
                        hideView = true
                    }
                    
                    if case .ended(_) = phase {
                        dismissWindow()
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
        .onAppear {
            if let url, let image = NSImage(contentsOf: url) {
                withAnimation(animation) {
                    previewImage = image
                }
                NSSound(named: "Tink")?.play()
            } else {
                dismissWindow()
            }
            
            // Monitor space key globally — .plain windows don't get key focus.
            // Dispatch panel creation async to avoid blocking the event handler.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                if event.keyCode == 49, previewImage != nil { // 49 = space bar
                    DispatchQueue.main.async {
                        self.openLargePreview()
                    }
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
        }
        .padding(.trailing, 28)
        .padding(.bottom, 32)
    }
    
    // MARK: - Hover Overlay
    
    @ViewBuilder
    func HoveredContent() -> some View {
        ZStack {
            // Dark frosted glass overlay
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            
            // Close button — original template style
            Button {
                dismissWindow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.black, .white)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(10)
            
            // Action buttons — pill shaped
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
                    saveWithPanel()
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
    
    // MARK: - Actions
    
    private func saveWithPanel() {
        guard let url else { return }
        
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
        guard let previewImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([previewImage])
        dismissWindow()
    }
    
    private func openLargePreview() {
        guard let previewImage, let url else { return }
        LargePreviewPanel.show(image: previewImage, url: url)
    }
    
    var animation: Animation {
        .smooth(duration: 0.3, extraBounce: 0)
    }
    
    var cornerRadius: CGFloat {
        16
    }
}
