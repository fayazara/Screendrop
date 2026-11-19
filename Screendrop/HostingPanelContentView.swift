//
//  HostingPanelContentView.swift
//  Screendrop
//
//  The content view for panels that host SwiftUI at a size the app sets by
//  hand. The hosting view goes inside this container instead of being the
//  window's contentView itself.
//
//  Under the SwiftUI App lifecycle, an NSHostingView that is its window's
//  contentView gets a window-size bridge whatever its `sizingOptions` say
//  (`animatesWindowRootSize`). After every window layout pass the bridge
//  resizes the window to the SwiftUI root (`updateAnimatedWindowSize`); the
//  resize changes the hosting view's safe area, which asks for another
//  constraint update in the middle of that layout pass, and AppKit aborts
//  the app with an exception. One level of nesting removes the bridge.
//

import AppKit

final class HostingPanelContentView: NSView {
    init(hosting hostingView: NSView, size: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        hostingView.frame = bounds
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    /// Only the hosted content takes clicks. Where it declines one (the
    /// recording bar's transparent slack), the container must decline too,
    /// or it would swallow clicks meant for whatever is behind the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

extension NSWindow {
    /// Shows `hostingView` filling the window, without letting SwiftUI resize
    /// the window. See `HostingPanelContentView`.
    func setHostedContent(_ hostingView: NSView) {
        contentView = HostingPanelContentView(
            hosting: hostingView,
            size: contentRect(forFrameRect: frame).size
        )
    }
}
