//
//  CaptureShelfPresenter.swift
//  Screendrop
//
//  The capture shelf's window: a borderless panel the height of the screen
//  and only as wide as a card, standing against the edge the shelf is docked
//  to. It is transparent everywhere except the cards, the header and the
//  handle, and the window server passes clicks on clear pixels to whatever
//  is beneath, so the panel never blocks the windows it floats over.
//

import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class CaptureShelfPresenter {
    static let shared = CaptureShelfPresenter()

    var onAnnotate: ((URL) -> Void)?
    var onEditVideo: ((URL) -> Void)?

    private var panel: NSPanel?
    private var targetDisplayID: CGDirectDisplayID?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private init() {}

    /// Remembers the display a capture is happening on, so its card shows
    /// on that screen.
    func setTargetDisplay(_ displayID: CGDirectDisplayID?) {
        targetDisplayID = displayID ?? ActiveDisplayResolver.activeDisplayID()
        applyPlacement()
    }

    func show(displayID: CGDirectDisplayID?) {
        let panel = panel ?? makePanel()
        setTargetDisplay(displayID)
        panel.orderFrontRegardless()
        // Ordering front while a Space switch or a full-screen transition
        // is settling can be dropped; assert it once more after it lands.
        Task { @MainActor [weak panel] in
            try? await Task.sleep(for: .milliseconds(150))
            panel?.orderFrontRegardless()
        }
    }

    func closeIfEmpty() {
        guard CaptureShelf.shared.items.isEmpty, let panel else { return }
        QuickLookPreviewPresenter.dismiss()
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        removeMonitors()
    }

    /// Moves the panel to the docked edge of the target screen.
    func applyPlacement() {
        guard let panel, let screen = targetScreen() else { return }
        let visible = screen.visibleFrame.integral
        let width = CaptureShelfMetrics.panelWidth
        let x = ScreendropPreferences.previewPosition == .left ? visible.minX : visible.maxX - width
        let frame = CGRect(x: x, y: visible.minY, width: width, height: visible.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
    }

    private func targetScreen() -> NSScreen? {
        ActiveDisplayResolver.screen(for: targetDisplayID) ?? ActiveDisplayResolver.activeScreen()
    }

    private func makePanel() -> NSPanel {
        let panel = CaptureShelfPanel(
            contentRect: CGRect(x: 0, y: 0, width: CaptureShelfMetrics.panelWidth, height: 600),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        // The cards bring their own entrance; AppKit's window fade on top of
        // it reads as a second, different transition.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        let hostingView = CaptureShelfHostingView(rootView: CaptureShelfView())
        panel.contentView = hostingView

        self.panel = panel
        installMonitors()
        return panel
    }

    // MARK: Input

    /// Space previews the hovered card in Quick Look, and Escape closes Quick
    /// Look. The global monitor covers the usual case of another app being
    /// active while the pointer rests on a card.
    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event) ? nil : event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = Self.handleKey(event)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { CaptureShelfPresenter.shared.applyPlacement() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        keyMonitor = nil
        globalKeyMonitor = nil
        screenObserver = nil
    }

    private static func handleKey(_ event: NSEvent) -> Bool {
        let shelf = CaptureShelf.shared
        switch event.keyCode {
        case 53 where QuickLookPreviewPresenter.isShown:
            QuickLookPreviewPresenter.dismiss()
            return true
        case 49:
            guard let item = shelf.hoveredItem else { return false }
            if QuickLookPreviewPresenter.isShown, QuickLookPreviewPresenter.currentURL == item.url {
                QuickLookPreviewPresenter.dismiss()
            } else {
                shelf.quickLook(id: item.id)
            }
            return true
        default:
            return false
        }
    }
}

enum CaptureShelfMetrics {
    /// Set in Settings → Overlay, so the panel width and capacity follow it.
    static var cardSize: CGSize { ScreendropPreferences.previewSize.cardSize }
    static let cardRadius: CGFloat = 14
    static let cardSpacing: CGFloat = 12
    /// Gap between the cards and the screen edge.
    static let edgeInset: CGFloat = 20
    static let bottomInset: CGFloat = 24
    /// Room above the top card for the header that appears on hover.
    static let headerHeight: CGFloat = 26
    static let headerSpacing: CGFloat = 10
    /// Clear room on the inner side for the cards' shadows.
    static let shadowRoom: CGFloat = 28
    static var panelWidth: CGFloat { edgeInset + cardSize.width + shadowRoom }

    /// Cards that fit a panel of this height under the header.
    static func capacity(forHeight height: CGFloat) -> Int {
        let usable = height - bottomInset - headerHeight - headerSpacing - edgeInset
        let stride = cardSize.height + cardSpacing
        return max(1, Int((usable + cardSpacing) / stride))
    }
}

private final class CaptureShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the shelf at the panel's size, and turns two-finger swipes into
/// tucking and untucking: toward the edge tucks the shelf away, away from it
/// brings the shelf back from its handle.
private final class CaptureShelfHostingView<Content: View>: NSHostingView<Content> {
    private var swipeDistance: CGFloat = 0
    private var didSwipe = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The panel sets this view's size; letting SwiftUI size the window
        // while it animates feeds a layout loop.
        sizingOptions = []
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The panel is non-activating and usually not key. Without this the
    /// first click on it only makes it key, and SwiftUI never sees the
    /// press: the handle needed a second click, and when the panel could
    /// not become key it never opened at all.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase == .began {
            swipeDistance = 0
            didSwipe = false
        }
        guard !didSwipe, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }

        // Positive is toward the docked edge on either side.
        let towardEdge: CGFloat = ScreendropPreferences.previewPosition == .left ? -1 : 1
        swipeDistance += event.scrollingDeltaX * towardEdge
        let shelf = CaptureShelf.shared
        if swipeDistance > 36, !shelf.isTucked {
            didSwipe = true
            shelf.tuck(.user)
        } else if swipeDistance < -36, shelf.isTucked {
            didSwipe = true
            shelf.open()
        }
    }
}
