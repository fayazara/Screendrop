//
//  LargePreviewPanel.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit

/// A floating borderless window that shows a large preview of the screenshot.
/// Max width 75% of screen, auto aspect ratio. Esc or click outside closes it.
/// Uses NSImageView directly — no SwiftUI hosting to avoid constraint loops.
final class LargePreviewPanel: NSPanel {
    
    private static var current: LargePreviewPanel?
    private static var clickMonitor: Any?
    
    static func show(image: NSImage, url: URL) {
        // Dismiss any existing panel
        dismiss()
        
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let maxWidth = screenFrame.width * 0.75
        let maxHeight = screenFrame.height * 0.85
        
        // Calculate size preserving the image's aspect ratio
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let aspectRatio = imageSize.width / imageSize.height
        
        var panelWidth = min(maxWidth, imageSize.width)
        var panelHeight = panelWidth / aspectRatio
        
        if panelHeight > maxHeight {
            panelHeight = maxHeight
            panelWidth = panelHeight * aspectRatio
        }
        
        // Center on screen
        let panelX = screenFrame.midX - panelWidth / 2
        let panelY = screenFrame.midY - panelHeight / 2
        let contentRect = CGRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        
        let panel = LargePreviewPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        
        // Build the view hierarchy with AppKit directly
        let containerView = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 12
        containerView.layer?.masksToBounds = true
        containerView.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        containerView.layer?.borderWidth = 1
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.4
        containerView.layer?.shadowRadius = 30
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -10)
        
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: contentRect.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        
        containerView.addSubview(imageView)
        panel.contentView = containerView
        
        current = panel
        panel.makeKeyAndOrderFront(nil)
        
        // Click outside to dismiss
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let panel = LargePreviewPanel.current,
               !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) {
                LargePreviewPanel.dismiss()
                return nil
            }
            return event
        }
    }
    
    static func dismiss() {
        current?.orderOut(nil)
        current?.close()
        current = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }
    
    override var canBecomeKey: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            LargePreviewPanel.dismiss()
        } else {
            super.keyDown(with: event)
        }
    }
}
