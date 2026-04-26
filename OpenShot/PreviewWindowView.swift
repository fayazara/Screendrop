//
//  PreviewWindowView.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//
//  Floating screenshot preview stack.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let previewCardSize = CGSize(width: 165, height: 124)
private let previewTrailingPadding: CGFloat = 28
private let previewStackAnimation = Animation.smooth(duration: 0.3, extraBounce: 0)
private let previewCardSlideOffset = previewCardSize.width + previewTrailingPadding + 48

struct PreviewWindowView: View {
    @State private var previewStack = ScreenshotPreviewStack.shared
    @State private var keyMonitor: Any?
    @State private var globalKeyMonitor: Any?
    @Environment(\.dismiss) private var dismissWindow
    
    var body: some View {
        VStack(spacing: 15) {
            ForEach(previewStack.items) { item in
                PreviewCardView(
                    item: item,
                    isHidden: previewStack.draggingItemID == item.id,
                    isDismissing: previewStack.dismissingItemIDs.contains(item.id),
                    onHoverChanged: { isHovered in
                        previewStack.setHovered(item.id, isHovered: isHovered)
                    },
                    onClose: {
                        previewStack.dismiss(id: item.id)
                    },
                    onDelete: {
                        previewStack.deleteScreenshot(id: item.id)
                    },
                    onCopy: {
                        previewStack.copyToClipboard(id: item.id)
                    },
                    onSave: {
                        previewStack.save(id: item.id)
                    },
                    onDragBegan: {
                        previewStack.beginDrag(id: item.id)
                    },
                    onDragEnded: {
                        withAnimation(previewStackAnimation) {
                            previewStack.finishDrag(id: item.id)
                        }
                    }
                )
            }
        }
        .frame(width: previewCardSize.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, previewTrailingPadding)
        .padding(.bottom, 32)
        .animation(previewStackAnimation, value: previewStack.itemIDs)
        .onAppear(perform: installKeyMonitors)
        .onDisappear(perform: tearDown)
        .onChange(of: previewStack.items.count) { _, count in
            if count == 0 {
                dismissWindow()
            }
        }
    }
    
    // MARK: - Keyboard
    
    private func installKeyMonitors() {
        guard keyMonitor == nil, globalKeyMonitor == nil else { return }
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if handlePreviewKey(event) {
                return nil
            }
            
            return event
        }
        
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if previewStack.hoveredItemID != nil || QuickLookPreviewPresenter.isShown {
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
    
    private func handlePreviewKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, QuickLookPreviewPresenter.isShown {
            QuickLookPreviewPresenter.dismiss()
            return true
        }
        
        if event.keyCode == 49, let hoveredItem = previewStack.hoveredItem {
            QuickLookPreviewPresenter.show(url: hoveredItem.url)
            return true
        }
        
        return false
    }
}

private struct PreviewCardView: View {
    let item: ScreenshotPreviewItem
    let isHidden: Bool
    let isDismissing: Bool
    let onHoverChanged: (Bool) -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void
    
    @State private var isHovered = false
    @State private var isPresented = false
    
    var body: some View {
        Image(nsImage: item.previewImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: previewCardSize.width, height: previewCardSize.height)
            .clipped()
            .overlay {
                if isHovered {
                    hoveredContent
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 12)
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            .opacity(isHidden ? 0 : 1)
            .offset(x: horizontalOffset)
            .draggable(item.url) {
                Image(nsImage: item.previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: cornerRadius))
            }
            .onDragSessionUpdated { session in
                switch session.phase {
                case .active:
                    onDragBegan()
                case .ended:
                    onDragEnded()
                default:
                    break
                }
            }
            .onHover { status in
                withAnimation(previewStackAnimation) {
                    isHovered = status
                    onHoverChanged(status)
                }
            }
            .onAppear {
                isPresented = false
                
                DispatchQueue.main.async {
                    withAnimation(previewStackAnimation) {
                        isPresented = true
                    }
                }
            }
            .animation(previewStackAnimation, value: isDismissing)
    }
    
    private var hoveredContent: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.black, .white)
            }
            .buttonStyle(.plain)
            .help("Dismiss preview")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(10)
            
            Button(action: onDelete) {
                Image(systemName: "trash.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.black, .white)
            }
            .buttonStyle(.plain)
            .help("Delete screenshot")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            
            VStack(spacing: 8) {
                Button(action: onCopy) {
                    Text("Copy")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.background.opacity(0.8), in: .capsule)
                }
                .buttonStyle(.plain)
                
                Button(action: onSave) {
                    Text("Save")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.background.opacity(0.8), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
    }
    
    private var cornerRadius: CGFloat {
        16
    }
    
    private var horizontalOffset: CGFloat {
        isPresented && !isDismissing ? 0 : previewCardSlideOffset
    }
}

struct ScreenshotPreviewItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let previewImage: NSImage
    var autoSavedURL: URL?
    
    static func == (lhs: ScreenshotPreviewItem, rhs: ScreenshotPreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
final class ScreenshotPreviewStack {
    static let shared = ScreenshotPreviewStack()
    
    private(set) var items: [ScreenshotPreviewItem] = []
    var hoveredItemID: ScreenshotPreviewItem.ID?
    var draggingItemID: ScreenshotPreviewItem.ID?
    var dismissingItemIDs: Set<ScreenshotPreviewItem.ID> = []
    
    var itemIDs: [ScreenshotPreviewItem.ID] {
        items.map(\.id)
    }
    
    var hoveredItem: ScreenshotPreviewItem? {
        guard let hoveredItemID else { return nil }
        return items.first { $0.id == hoveredItemID }
    }
    
    private init() {}
    
    func add(url: URL) {
        guard let image = ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 520) else {
            return
        }
        
        QuickLookPreviewPresenter.dismiss()
        
        var item = ScreenshotPreviewItem(url: url, previewImage: image)
        
        if OpenShotPreferences.autoSave {
            item.autoSavedURL = saveToDefaultLocation(from: url)
        }
        
        if OpenShotPreferences.autoCopy {
            _ = copyURLToClipboard(url)
        }
        
        items.insert(item, at: 0)
        NSSound(named: "Tink")?.play()
    }
    
    func setHovered(_ id: ScreenshotPreviewItem.ID, isHovered: Bool) {
        if isHovered {
            hoveredItemID = id
        } else if hoveredItemID == id {
            hoveredItemID = nil
        }
    }
    
    func beginDrag(id: ScreenshotPreviewItem.ID) {
        QuickLookPreviewPresenter.dismiss()
        draggingItemID = id
    }
    
    func finishDrag(id: ScreenshotPreviewItem.ID) {
        removeImmediately(id: id)
    }
    
    func dismiss(id: ScreenshotPreviewItem.ID) {
        guard items.contains(where: { $0.id == id }),
              !dismissingItemIDs.contains(id) else {
            return
        }
        
        QuickLookPreviewPresenter.dismiss()
        
        withAnimation(previewStackAnimation) {
            dismissingItemIDs.insert(id)
            if hoveredItemID == id {
                hoveredItemID = nil
            }
            
            if draggingItemID == id {
                draggingItemID = nil
            }
        }
        
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            removeImmediately(id: id)
        }
    }
    
    private func removeImmediately(id: ScreenshotPreviewItem.ID) {
        QuickLookPreviewPresenter.dismiss()
        items.removeAll { $0.id == id }
        dismissingItemIDs.remove(id)
        
        if hoveredItemID == id {
            hoveredItemID = nil
        }
        
        if draggingItemID == id {
            draggingItemID = nil
        }
    }
    
    func copyToClipboard(id: ScreenshotPreviewItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        
        guard copyURLToClipboard(item.url) else { return }
        dismiss(id: id)
    }
    
    func deleteScreenshot(id: ScreenshotPreviewItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        
        deleteFile(at: item.url)
        
        if let autoSavedURL = item.autoSavedURL, autoSavedURL != item.url {
            deleteFile(at: autoSavedURL)
        }
        
        dismiss(id: id)
    }
    
    func save(id: ScreenshotPreviewItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        
        if OpenShotPreferences.autoSave {
            if items[index].autoSavedURL == nil {
                items[index].autoSavedURL = saveToDefaultLocation(from: items[index].url)
            }
            
            dismiss(id: id)
            return
        }
        
        let url = items[index].url
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: url)
        panel.canCreateDirectories = true
        panel.title = "Save Screenshot"
        
        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                do {
                    try ScreenshotFileActions.save(from: url, to: destURL)
                } catch {
                    print("Failed to save: \(error)")
                }
            }
        }
    }
    
    private func deleteFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("Failed to delete screenshot: \(error)")
        }
    }
    
    private func copyURLToClipboard(_ url: URL) -> Bool {
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
            return true
        } catch {
            print("Failed to copy screenshot: \(error)")
            return false
        }
    }
    
    private func saveToDefaultLocation(from url: URL) -> URL? {
        do {
            return try ScreenshotFileActions.saveToDefaultLocation(from: url)
        } catch {
            print("Failed to auto save: \(error)")
            return nil
        }
    }
}
