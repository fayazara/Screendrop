//
//  NotchWindow.swift
//  {{AppName}}
//
//  A borderless, transparent, click-through NSPanel that positions itself
//  flush against the top of the screen at the highest window level, directly
//  over the MacBook's hardware notch area.
//
//  Usage:
//    let window = NotchWindow()
//    window.showNotch(content: MyNotchContentView())
//    window.hideNotch()
//

import AppKit
import SwiftUI

class NotchWindow: NSPanel {

    /// Shadow padding around the content to allow for drop shadows or glow effects.
    /// Increase if your content has large shadows.
    var shadowPadding: CGFloat = 20

    /// The width of the content area (excluding shadow padding).
    var contentWidth: CGFloat = 360

    /// The height of the content area (excluding shadow padding).
    var contentHeight: CGFloat = 140

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
    }

    /// Show the notch overlay with the given SwiftUI content.
    ///
    /// The window is positioned at `CGShieldingWindowLevel` (above everything)
    /// centered at the top of the main screen, flush with the top edge.
    func showNotch<Content: View>(content: Content) {
        // Place above everything, including the menu bar
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let totalWidth = contentWidth + shadowPadding * 2
        let totalHeight = contentHeight + shadowPadding

        if let screen = NSScreen.main {
            let x = screen.frame.origin.x + (screen.frame.width - totalWidth) / 2
            let y = screen.frame.origin.y + screen.frame.height - totalHeight
            setFrame(CGRect(x: x, y: y, width: totalWidth, height: totalHeight), display: false)
        }

        let hosting = NSHostingView(rootView:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting

        alphaValue = 1
        orderFront(nil)
    }

    /// Show as a floating pill at the bottom of the screen (fallback for non-notch Macs).
    func showPill<Content: View>(content: Content) {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let size = CGSize(width: contentWidth, height: contentHeight)
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 30
            setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: false)
        }

        let hosting = NSHostingView(rootView:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        contentView = hosting

        alphaValue = 1
        orderFront(nil)
    }

    /// Hide with a fade-out animation.
    func hideNotch(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }

    /// Whether the current main screen has a hardware notch.
    static var screenHasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }
}
