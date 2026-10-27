//
//  CaptureShelfPresenter.swift
//  Screendrop
//
//  The floating screenshot preview's window: a borderless, transparent panel
//  sized to the card itself rather than to the screen edge. CaptureShelfView
//  fills it; the panel follows the pointer while the card is dragged, and the
//  place it is left in is remembered for the next capture.
//
//  The panel never takes focus, floats above ordinary windows, follows the
//  user across Spaces, and is excluded from Screendrop's own captures. Its
//  clear margin only exists so the card's shadow is not clipped.
//

import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class CaptureShelfPresenter {
    static let shared = CaptureShelfPresenter()

    var onAnnotate: ((URL) -> Void)?
    var onEditVideo: ((URL) -> Void)?

    private(set) var panel: NSPanel?
    private var targetDisplayID: CGDirectDisplayID?
    private var keyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var scrollMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var shownItemID: ShelfItem.ID?
    /// The app that was in front before an area capture, restored when the
    /// preview closes.
    private var appToRestore: NSRunningApplication?
    private var previewHiddenForCapture = false
    /// Where and at what size the last area capture was made.
    private var captureSelection: CGRect?

    /// Size of one square card.
    private(set) var previewCardSize = PreviewCardMetrics.tileSize
    /// Size of the whole stack of squares.
    private(set) var previewStackSize = PreviewCardMetrics.tileSize
    private var moveObserver: NSObjectProtocol?
    private var placementSaveTask: Task<Void, Never>?

    private init() {}

    /// Remembers the display a capture is happening on, so its card shows
    /// on that screen.
    func setTargetDisplay(_ displayID: CGDirectDisplayID?) {
        targetDisplayID = displayID ?? ActiveDisplayResolver.activeDisplayID()
    }

    /// Called by the area selector: the preview keeps focus so ⌘W dismisses
    /// it, and this app is reactivated once it is gone.
    func adoptPreviousApp(_ app: NSRunningApplication?) {
        appToRestore = app
    }

    /// Puts the app that was in front before the selection back, for flows
    /// that end without showing a preview.
    func restoreAdoptedAppIfNeeded() {
        guard let appToRestore else { return }
        appToRestore.activate()
        self.appToRestore = nil
    }

    /// Sets the capture's rectangle before the after-capture actions run, so
    /// the automatic pin can be placed on it.
    func prepareCapture(displayID: CGDirectDisplayID?, selection: CGRect?) {
        setTargetDisplay(displayID)
        captureSelection = selection
    }

    /// The preview always opens in the chosen bottom corner. `selection` is
    /// accepted for callers that know the captured rectangle, but the card is
    /// not placed on it: it is a floating thumbnail, not a frozen overlay.
    func show(displayID: CGDirectDisplayID?, selection: CGRect? = nil) {
        setTargetDisplay(displayID)
        // Remembered so a pin can return to the captured area.
        captureSelection = selection
        guard let item = CaptureShelf.shared.items.first else { return }
        let panel = panel ?? makePanel()
        // A capture the user faded out of the way should come back readable
        // when the next one arrives.
        if shownItemID != item.id {
            panel.alphaValue = 1
            shownItemID = item.id
        }

        if appToRestore == nil {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                appToRestore = frontmost
            }
        }

        layoutForCurrentCapture(restoringPosition: true)
        // A pin for this capture has focus and owns ⌘W, so the card must not
        // take the key window from it. With no pin on screen the card is the
        // only capture surface and keeps focus.
        if PinnedScreenshotPresenter.shared.hasPins {
            panel.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
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
        if !PinnedScreenshotPresenter.shared.hasPins, let appToRestore {
            appToRestore.activate()
            self.appToRestore = nil
        }
    }

    /// Hides the preview while a screen capture is in progress, then brings
    /// it back. Exclusion alone can leave a transparent hole where the card
    /// covers the area being captured.
    func hidePreviewForCapture() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        previewHiddenForCapture = true
    }

    func restorePreviewAfterCapture() {
        guard previewHiddenForCapture else { return }
        previewHiddenForCapture = false
        guard let panel, CaptureShelf.shared.items.first != nil else { return }
        panel.orderFrontRegardless()
    }

    /// Hides the preview while an editor opened from it is on screen, then
    /// brings it back in the same place.
    func setTucked(_ isTucked: Bool) {
        guard let panel else { return }
        if isTucked {
            panel.orderOut(nil)
        } else if CaptureShelf.shared.items.first != nil {
            layoutForCurrentCapture(restoringPosition: true)
            panel.orderFrontRegardless()
        }
    }

    /// Re-measures the card, e.g. when a recording's real thumbnail replaces
    /// its placeholder, keeping the top-left corner where the user left it.
    func refreshCardSize() {
        guard let panel, panel.isVisible, CaptureShelf.shared.items.first != nil else { return }
        layoutForCurrentCapture(restoringPosition: false)
    }

    /// Puts the preview back in the bottom-right corner.
    func resetPlacement() {
        PreviewPlacementStore.reset()
        guard let panel, panel.isVisible else { return }
        layoutForCurrentCapture(restoringPosition: true)
    }

    /// Asks before closing a floating screenshot (the file is never deleted).
    /// The question can be switched off from the dialog itself.
    func confirmFloatingClose(message: String, informative: String) -> Bool {
        guard ScreendropPreferences.confirmPinnedClose else { return true }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: ScreendropPreferences.confirmPinnedCloseKey)
        }
        return response == .alertFirstButtonReturn
    }

    @discardableResult
    func confirmAndDismissPreview() -> Bool {
        guard let item = CaptureShelf.shared.items.first else { return false }
        guard confirmFloatingClose(
            message: "Dismiss this preview?",
            informative: "The screenshot stays saved in your Screenshots folder."
        ) else { return true }
        CaptureShelf.shared.dismiss(id: item.id)
        return true
    }

    // MARK: Placement

    /// Dragging is left to the window server (see CaptureShelfCard's
    /// WindowDragGesture), so nothing here recomputes the frame per mouse
    /// event. The window's own move notifications remember where it was
    /// left, however it moved.
    private func installMoveObserver(on panel: NSPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { CaptureShelfPresenter.shared.schedulePlacementSave() }
        }
    }

    private func schedulePlacementSave() {
        placementSaveTask?.cancel()
        placementSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            savePlacement()
        }
    }

    /// Keeps the card fully on screen and remembers the position when the
    /// window stops moving.
    private func savePlacement() {
        guard let panel, let screen = targetScreen() else { return }
        let clamped = clampedCardRect(
            panel.frame,
            in: screen.visibleFrame,
            margin: PreviewCardMetrics.screenMargin
        )
        if clamped.origin != panel.frame.origin {
            panel.setFrameOrigin(snapped(clamped.origin))
        }
        // Measured against the corner, never against the stored offset, or
        // each save would cancel the previous one.
        let base = baseOrigin(for: panel.frame.size, on: screen)
        PreviewPlacementStore.save(
            CGSize(
                width: panel.frame.minX - base.x,
                height: panel.frame.minY - base.y
            )
        )
    }

    #if DEBUG
    /// Moves the preview without a mouse, for the self-test.
    func moveForTesting(by translation: CGSize) {
        guard let panel else { return }
        let proposed = CGPoint(
            x: panel.frame.minX + translation.width,
            y: panel.frame.minY - translation.height
        )
        panel.setFrameOrigin(snapped(clampedOrigin(proposed)))
        savePlacement()
    }
    #endif

    /// Whether the hover controls need to sit at the top of the card because
    /// its bottom is against the screen edge or the Dock.
    var previewIsNearScreenBottom: Bool {
        guard let panel, let screen = targetScreen() else { return false }
        return panel.frame.minY - screen.visibleFrame.minY < 120
    }

    /// The preview's right-click menu. Built as a real NSMenu: a SwiftUI
    /// context menu in a non-activating panel does not always get the event.
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let item = CaptureShelf.shared.items.first else { return menu }
        let shelf = CaptureShelf.shared
        let id = item.id
        let isImage = item.kind == .image

        menu.addItem(MenuActionItem(isImage ? "Open Annotator" : "Edit Recording", image: isImage ? "pencil.tip" : "scissors") {
            shelf.openEditor(id: id)
        })
        menu.addItem(MenuActionItem("Quick Look", image: "eye") { shelf.quickLook(id: id) })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem("Copy to Clipboard", image: "doc.on.doc") { shelf.copy(id: id) })
        if isImage {
            menu.addItem(MenuActionItem("Copy Text from Image", image: "text.viewfinder") { shelf.copyText(id: id) })
            menu.addItem(MenuActionItem("Copy as Compressed JPG", image: "arrow.down.right.and.arrow.up.left") { shelf.compress(id: id) })
        }
        menu.addItem(MenuActionItem("Save", image: "square.and.arrow.down") { shelf.save(id: id) })
        menu.addItem(MenuActionItem("Save As…") { shelf.save(id: id, choosingLocation: true) })
        if isImage {
            menu.addItem(MenuActionItem("Pin to Screen", image: "pin") { shelf.pin(id: id) })
        }
        if CloudUploader.shared.isConfigured {
            if CloudUploader.shared.uploadedURLs[id] != nil {
                menu.addItem(MenuActionItem("Copy Share Link", image: "link") { shelf.copyLink(id: id) })
            } else {
                menu.addItem(MenuActionItem("Upload to Cloud & Copy Link", image: "cloud") { shelf.upload(id: id) })
            }
        } else {
            menu.addItem(MenuActionItem("Set Up Cloud Upload…", image: "cloud") {
                SettingsWindowController.show(tab: .cloud)
            })
        }
        menu.addItem(.separator())
        menu.addItem(MenuActionItem("Dismiss") { shelf.dismiss(id: id) })
        menu.addItem(MenuActionItem(
            isImage ? "Delete Screenshot" : "Delete Recording",
            image: "trash",
            enabled: !shelf.isOpenInEditor(id: id)
        ) {
            shelf.delete(id: id)
        })
        return menu
    }

    /// The capture's own rectangle, so a pin can reappear exactly where the
    /// screenshot was taken, at the size it was taken.
    var captureFrame: CGRect? { captureSelection }

    /// The capture under a point in the preview panel, top-down.
    func itemIndex(atPoint point: CGPoint, in bounds: CGSize, flipped: Bool) -> Int? {
        let tile = PreviewCardMetrics.tileSize
        let spacing = PreviewCardMetrics.tileSpacing
        let fromTop = flipped ? point.y : bounds.height - point.y
        guard fromTop >= 0 else { return nil }
        let index = Int(fromTop / (tile.height + spacing))
        return CaptureShelf.shared.items.indices.contains(index) ? index : nil
    }

    /// Opens the editor for the capture under a double-click.
    func openEditorForPreview(at index: Int) {
        guard CaptureShelf.shared.items.indices.contains(index) else { return }
        CaptureShelf.shared.openEditor(id: CaptureShelf.shared.items[index].id)
    }

    /// Opens the editor for the newest capture (⌘W / menu paths).
    func openEditorForPreview() {
        guard let item = CaptureShelf.shared.items.first else { return }
        CaptureShelf.shared.openEditor(id: item.id)
    }

    /// The native drag has finished: keep the card on screen and remember
    /// where it was left.
    func finishNativeDrag() {
        savePlacement()
    }

    /// Option-dragging the picture starts a normal file drag, so the PNG can
    /// be dropped into Finder, Mail or any other app.
    func beginFileDrag(with event: NSEvent, index: Int = 0) {
        guard let panel, CaptureShelf.shared.items.indices.contains(index) else { return }
        let item = CaptureShelf.shared.items[index]
        let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        dragItem.setDraggingFrame(panel.frame, contents: item.thumbnail)
        let source = PreviewFileDragSource(
            onBegin: { CaptureShelf.shared.beginDrag(id: item.id) },
            onEnd: { CaptureShelf.shared.endDrag(id: item.id) }
        )
        Self.activeDragSource = source
        panel.beginDraggingSession(items: [dragItem], event: event, source: source)
    }

    private static var activeDragSource: PreviewFileDragSource?

    // MARK: Layout

    private func layoutForCurrentCapture(restoringPosition: Bool) {
        guard let panel, let screen = targetScreen() else { return }

        // A column of fixed square tiles, newest on top, bottom-anchored.
        let card = PreviewCardMetrics.tileSize
        previewCardSize = card
        let spacing = PreviewCardMetrics.tileSpacing
        let available = screen.visibleFrame.height - PreviewCardMetrics.screenMargin * 2
        let capacity = max(1, Int((available + spacing) / (card.height + spacing)))
        CaptureShelf.shared.visibleCapacity = capacity

        let count = max(1, CaptureShelf.shared.items.count)
        let stack = CGSize(
            width: card.width,
            height: CGFloat(count) * card.height + CGFloat(count - 1) * spacing
        )
        let sizeChanged = previewStackSize != stack
        previewStackSize = stack

        let origin = restoringPosition
            ? resolvedCardOrigin(for: stack, on: screen)
            : panel.frame.origin
        let frame = CGRect(origin: origin, size: stack)
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
            if sizeChanged { panel.invalidateShadow() }
        }
    }

    /// The chosen bottom corner, before the user's drag offset.
    private func baseOrigin(for card: CGSize, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let margin = PreviewCardMetrics.screenMargin
        let x = ScreendropPreferences.previewPosition == .left
            ? visible.minX + margin
            : visible.maxX - card.width - margin
        return CGPoint(x: x, y: visible.minY + margin)
    }

    private func naturalOrigin(for card: CGSize, on screen: NSScreen) -> CGPoint {
        let base = baseOrigin(for: card, on: screen)
        let offset = PreviewPlacementStore.load() ?? .zero
        return CGPoint(x: base.x + offset.width, y: base.y + offset.height)
    }

    private func resolvedCardOrigin(for card: CGSize, on screen: NSScreen) -> CGPoint {
        var rect = CGRect(origin: naturalOrigin(for: card, on: screen), size: card)
        rect = clampedCardRect(
            rect,
            in: screen.visibleFrame,
            margin: PreviewCardMetrics.screenMargin
        )
        return rect.origin
    }

    private func clampedCardRect(_ rect: CGRect, in visible: CGRect, margin: CGFloat) -> CGRect {
        var rect = rect
        let minX = visible.minX + margin
        let maxX = max(minX, visible.maxX - rect.width - margin)
        let minY = visible.minY + margin
        let maxY = max(minY, visible.maxY - rect.height - margin)
        rect.origin.x = min(max(rect.origin.x, minX), maxX)
        rect.origin.y = min(max(rect.origin.y, minY), maxY)
        return rect
    }

    private func clampedOrigin(_ proposed: CGPoint) -> CGPoint {
        let screen = screen(containing: CGPoint(x: proposed.x + previewStackSize.width / 2,
                                               y: proposed.y + previewStackSize.height / 2))
            ?? screen(containing: proposed)
            ?? targetScreen()
        guard let screen else { return proposed }
        let clamped = clampedCardRect(
            CGRect(origin: proposed, size: previewStackSize),
            in: screen.visibleFrame,
            margin: PreviewCardMetrics.screenMargin
        )
        return clamped.origin
    }

    /// Whole points, so the picture never lands on a half pixel and
    /// resamples while it moves.
    private func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded(), y: point.y.rounded())
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func targetScreen() -> NSScreen? {
        ActiveDisplayResolver.screen(for: targetDisplayID) ?? ActiveDisplayResolver.activeScreen()
    }

    /// Screen changes move the visible frame under the card; keep it inside.
    func applyPlacement() {
        guard let panel, panel.isVisible, let screen = targetScreen() else { return }
        let clamped = clampedCardRect(
            panel.frame,
            in: screen.visibleFrame,
            margin: PreviewCardMetrics.screenMargin
        )
        panel.setFrameOrigin(snapped(clamped.origin))
    }

    private func makePanel() -> NSPanel {
        let panel = CaptureShelfPanel(
            contentRect: CGRect(origin: .zero, size: previewStackSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The system draws the shadow from the card's rounded alpha shape.
        // A SwiftUI shadow would have to be re-rendered on every drag step.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        // The cards bring their own entrance; AppKit's window fade on top of
        // it reads as a second, different transition.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        installMoveObserver(on: panel)
        // Scrolling over the preview dims it, like a pinned screenshot. A
        // local monitor is used rather than the panel's scrollWheel: the
        // SwiftUI hosting view otherwise swallows the event.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak panel] event in
            guard let panel, event.window === panel else { return event }
            panel.alphaValue = PreviewOpacity.alpha(panel.alphaValue, after: event)
            return nil
        }

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
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        placementSaveTask?.cancel()
        placementSaveTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        keyMonitor = nil
        globalKeyMonitor = nil
        scrollMonitor = nil
        moveObserver = nil
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

/// The floating preview's proportions: the card follows the capture's own
/// aspect ratio instead of cropping it into a fixed box.
enum PreviewCardMetrics {
    /// Gap between stacked preview squares.
    static let tileSpacing: CGFloat = 8

    /// The floating preview is a square tile at the chosen corner.
    static let tileSize = CGSize(width: 200, height: 132)
    static let maxSize = CGSize(width: 380, height: 300)
    /// Small captures are enlarged, but never past this long edge.
    static let minLongEdge: CGFloat = 120
    /// The card's rounding grows with the card, so a large area preview keeps
    /// the same soft CleanShot-style corners as a small one.
    static func cornerRadius(for size: CGSize) -> CGFloat {
        min(26, max(16, min(size.width, size.height) * 0.14))
    }
    /// Gap between the card and the screen edges (about 1 cm).
    static let screenMargin: CGFloat = 32

    /// The card's size: the picture's aspect, capped at `maxSize`, with very
    /// small captures enlarged a little.
    static func cardSize(for image: NSImage?, scale: CGFloat) -> CGSize {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: 260, height: 170)
        }
        let natural = CGSize(
            width: image.size.width / max(scale, 1),
            height: image.size.height / max(scale, 1)
        )
        var factor = min(
            1,
            min(maxSize.width / natural.width, maxSize.height / natural.height)
        )
        let longEdge = max(natural.width, natural.height) * factor
        if longEdge < minLongEdge {
            factor = min(
                minLongEdge / max(natural.width, natural.height),
                min(maxSize.width / natural.width, maxSize.height / natural.height)
            )
        }
        return CGSize(
            width: max(1, (natural.width * factor).rounded()),
            height: max(1, (natural.height * factor).rounded())
        )
    }
}

private final class CaptureShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the card at the panel's size.
private final class CaptureShelfHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // The presenter sets this view's size; letting SwiftUI size the window
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
    /// press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        CaptureShelfPresenter.shared.makeContextMenu()
    }

    /// The card's body starts a native window drag, exactly like a title
    /// bar; only the strip holding the hover controls is handed to SwiftUI so
    /// its buttons keep working.
    override func mouseDown(with event: NSEvent) {
        // The preview does not take ⌘W; do not steal focus from the app
        // behind just because its card is clicked.
        window?.makeKey()

        // Control-click is the other way to ask for the context menu.
        if event.modifierFlags.contains(.control) {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if isInControlsStrip(point) {
            super.mouseDown(with: event)
            return
        }
        let index = CaptureShelfPresenter.shared.itemIndex(
            atPoint: point,
            in: bounds.size,
            flipped: isFlipped
        ) ?? 0
        if event.clickCount == 2 {
            CaptureShelfPresenter.shared.openEditorForPreview(at: index)
            return
        }
        if event.modifierFlags.contains(.option) {
            CaptureShelfPresenter.shared.beginFileDrag(with: event, index: index)
            return
        }
        window?.performDrag(with: event)
        CaptureShelfPresenter.shared.finishNativeDrag()
    }

    /// The hover controls of every square: a capsule at its bottom and the
    /// close badge in its top-left. Clicks there go to SwiftUI; the rest of
    /// the stack drags the window.
    private func isInControlsStrip(_ point: CGPoint) -> Bool {
        let tile = PreviewCardMetrics.tileSize
        let spacing = PreviewCardMetrics.tileSpacing
        let count = max(1, CaptureShelf.shared.items.count)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let halfWidth = min(tile.width * 0.48, 240)

        for index in 0..<count {
            let top = CGFloat(index) * (tile.height + spacing)
            let bottom = top + tile.height
            let inCloseBadge = fromTop >= top && fromTop <= top + 40 && point.x <= 40
            let inCapsule = fromTop >= bottom - 48 && fromTop <= bottom
                && abs(point.x - bounds.midX) < halfWidth
            if inCloseBadge || inCapsule { return true }
        }
        return false
    }
}

/// Owns one file drag started from the preview's body, and tells the shelf
/// when it begins and ends so "Close after dragging" keeps working.
@MainActor
final class PreviewFileDragSource: NSObject, NSDraggingSource {
    private let onBegin: () -> Void
    private let onEnd: () -> Void

    init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void) {
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onBegin()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd()
    }
}

/// A menu item that runs a closure, so context menus can be built from the
/// model without an ObjC target for every action.
@MainActor
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(
        _ title: String,
        image systemImage: String? = nil,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func run() {
        handler()
    }
}
