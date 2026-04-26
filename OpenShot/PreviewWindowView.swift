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
    @State private var globalKeyMonitor: Any?
    @State private var popoverAnchorView: NSView?
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
                    let phase = session.phase
                    
                    if phase == .active {
                        LargePreviewPopover.dismiss()
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
            if let url, let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 520) {
                withAnimation(animation) {
                    previewImage = image
                }
                NSSound(named: "Tink")?.play()
            } else {
                dismissWindow()
            }
            
            // Monitor space key globally — .plain windows don't get key focus.
            // Dispatch popover creation async to avoid blocking the event handler.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                if handlePreviewKey(event) {
                    return nil
                }
                
                return event
            }
            
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [self] event in
                if isHovered || LargePreviewPopover.isShown {
                    _ = handlePreviewKey(event)
                }
            }
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            
            if let globalKeyMonitor {
                NSEvent.removeMonitor(globalKeyMonitor)
            }
            globalKeyMonitor = nil
            LargePreviewPopover.dismiss()
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
        guard let url, let pngData = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        LargePreviewPopover.dismiss()
        dismissWindow()
    }
    
    private func openLargePreview() {
        guard let url, let popoverAnchorView else { return }
        LargePreviewPopover.show(url: url, relativeTo: popoverAnchorView)
    }
    
    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, LargePreviewPopover.isShown { // 53 = escape
            LargePreviewPopover.dismiss()
            return true
        }
        
        if event.keyCode == 49, isHovered, previewImage != nil { // 49 = space bar
            DispatchQueue.main.async {
                self.openLargePreview()
            }
            return true
        }
        
        return false
    }
    
    var animation: Animation {
        .smooth(duration: 0.3, extraBounce: 0)
    }
    
    var cornerRadius: CGFloat {
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
        LargePreviewPopover.dismiss()
    }
}
