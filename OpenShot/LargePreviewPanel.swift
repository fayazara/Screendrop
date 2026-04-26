//
//  LargePreviewPanel.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import AppKit

/// Presents the large screenshot preview as an NSPopover anchored to the small preview.
final class LargePreviewPopover: NSObject, NSPopoverDelegate {
    private static let shared = LargePreviewPopover()
    
    private var popover: NSPopover?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    
    static var isShown: Bool {
        shared.popover?.isShown == true
    }
    
    static func show(url: URL, relativeTo anchorView: NSView) {
        shared.show(url: url, relativeTo: anchorView)
    }
    
    static func dismiss() {
        shared.dismiss()
    }
    
    private func show(url: URL, relativeTo anchorView: NSView) {
        if popover?.isShown == true {
            dismiss()
            return
        }
        
        guard anchorView.window != nil else { return }
        
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        
        let contentViewController = LargePreviewViewController(url: url, anchorView: anchorView)
        popover.contentViewController = contentViewController
        popover.contentSize = contentViewController.preferredContentSize
        
        self.popover = popover
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minX)
        startClickMonitoring()
    }
    
    private func dismiss() {
        popover?.performClose(nil)
        stopClickMonitoring()
        popover = nil
    }
    
    func popoverDidClose(_ notification: Notification) {
        stopClickMonitoring()
        popover = nil
    }
    
    private func startClickMonitoring() {
        stopClickMonitoring()
        
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            
            if self.clickIsOutsidePopover() {
                self.dismiss()
            }
            
            return event
        }
        
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }
    
    private func stopClickMonitoring() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        
        localClickMonitor = nil
        globalClickMonitor = nil
    }
    
    private func clickIsOutsidePopover() -> Bool {
        guard let popoverWindow = popover?.contentViewController?.view.window else {
            return true
        }
        
        return !popoverWindow.frame.contains(NSEvent.mouseLocation)
    }
}

private final class LargePreviewViewController: NSViewController {
    private let url: URL
    private let preferredSize: CGSize
    private let imageScale: CGFloat
    
    init(url: URL, anchorView: NSView) {
        self.url = url
        self.preferredSize = Self.contentSize(for: url, anchorView: anchorView)
        self.imageScale = anchorView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        super.init(nibName: nil, bundle: nil)
        self.preferredContentSize = preferredSize
    }
    
    required init?(coder: NSCoder) {
        return nil
    }
    
    override func loadView() {
        let containerView = NSView(frame: NSRect(origin: .zero, size: preferredSize))
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 10
        containerView.layer?.masksToBounds = true
        
        let imageView = LargePreviewImageView(frame: containerView.bounds)
        imageView.image = ScreenshotImageLoader.downsampledImage(
            at: url,
            maxPixelSize: max(preferredSize.width, preferredSize.height) * imageScale
        )
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        containerView.addSubview(imageView)
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: preferredSize.width),
            containerView.heightAnchor.constraint(equalToConstant: preferredSize.height),
            imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        view = containerView
    }
    
    private static func contentSize(for url: URL, anchorView: NSView) -> CGSize {
        let screen = anchorView.window?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let popoverChromeAllowance: CGFloat = 36
        let maxWidth = max(320, visibleFrame.width * 0.75 - popoverChromeAllowance)
        let maxHeight = max(240, visibleFrame.height * 0.75 - popoverChromeAllowance)
        
        guard let imageSize = ScreenshotImageLoader.imageSize(at: url),
              imageSize.width > 0,
              imageSize.height > 0 else {
            return CGSize(width: 640, height: 420)
        }
        
        let aspectRatio = imageSize.width / imageSize.height
        var width = min(maxWidth, imageSize.width)
        var height = width / aspectRatio
        
        if height > maxHeight {
            height = maxHeight
            width = height * aspectRatio
        }
        
        return CGSize(width: width, height: height)
    }
}

private final class LargePreviewImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        .zero
    }
}
