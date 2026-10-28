//
//  PinnedScreenshotPresenter.swift
//  Screendrop
//
//  Pins a screenshot to the screen as a floating, always-on-top window the user
//  can keep around for reference while they work. Supports multiple pins.
//
//  Pins move with the window server's own drag loop (the same one a title bar
//  uses), so they follow the pointer without re-rendering. Right-clicking a pin
//  reaches the annotator, the cloud upload and the clipboard; scrolling fades
//  it out of the way.
//

import AppKit
import SwiftUI

@MainActor
final class PinnedScreenshotPresenter {
    static let shared = PinnedScreenshotPresenter()

    private var panels: Set<NSPanel> = []
    /// Creation order, so ⌘W closes the pin the user just made rather than
    /// whichever panel happens to come out of the set first.
    private var pinOrder: [NSPanel] = []
    private var panelURLs: [ObjectIdentifier: URL] = [:]
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    /// The app that was in front before the first pin appeared.
    private var appToRestore: NSRunningApplication?

    private init() {
        // Scrolling on a pin fades it. A local monitor is used because a
        // SwiftUI hosting view otherwise consumes the scroll event.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let panel = event.window as? PinnedPanel else { return event }
            panel.alphaValue = PreviewOpacity.alpha(panel.alphaValue, after: event)
            return nil
        }

        // ⌘W closes the pin that is currently key, the same as a document
        // window. Clicking a pin makes it key (nonactivating, so the app that
        // was in front stays in front).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard NSApp.isActive,
                  event.modifierFlags.contains(.command),
                  event.keyCode == 13,
                  let panel = NSApp.keyWindow as? PinnedPanel,
                  panel.isKeyWindow
            else { return event }
            self?.confirmAndClose(panel)
            return nil
        }
    }

    private var hiddenForCapture: [NSPanel] = []

    /// Screenshots and scrolling captures must photograph the real screen,
    /// not our own pins. Exclusion alone leaves transparent holes when a pin
    /// covers the selected area, so hide them for the duration.
    func hideAllForCapture() {
        guard hiddenForCapture.isEmpty else { return }
        hiddenForCapture = panels.filter { $0.isVisible }
        for panel in hiddenForCapture {
            panel.orderOut(nil)
        }
    }

    func restoreAfterCapture() {
        let hidden = hiddenForCapture
        hiddenForCapture = []
        for panel in hidden where panels.contains(panel) {
            panel.orderFrontRegardless()
        }
    }

    #if DEBUG
    /// Drives one resize step without mouse events, for the self-test.
    func resizeForTesting(_ panel: NSPanel, delta: CGSize) {
        beginResize(of: panel)
        resize(panel, by: delta)
        endResize(of: panel)
    }

    /// Whether the app is active with a pin as its key window.
    var isPinKeyWindow: Bool {
        NSApp.isActive && (NSApp.keyWindow as? PinnedPanel)?.isKeyWindow == true
    }

    /// Windows currently pinned; used by the preview self-test.
    var panelsForTesting: [NSPanel] { Array(panels) }
    #endif

    var hasPins: Bool { !panels.isEmpty }

    /// Closes the most recently created pin. Returns false when there is
    /// nothing pinned, so the caller can decide what ⌘W should do instead.
    @discardableResult
    private func confirmAndClose(_ panel: NSPanel) {
        guard CaptureShelfPresenter.shared.confirmFloatingClose(
            message: "Close this pinned screenshot?",
            informative: "The image stays in your Screenshots folder."
        ) else { return }
        close(panel)
    }

    func closeMostRecent() -> Bool {
        guard let panel = pinOrder.last else { return false }
        close(panel)
        return true
    }

    /// `frame` is the floating preview's frame: the pin takes its place
    /// instead of jumping to the middle of the screen.
    func pin(url: URL, at frame: CGRect? = nil) {
        // The floating preview already holds this capture decoded; reusing it
        // makes the pin appear at once instead of after another full decode.
        let cached = CaptureShelf.shared.items.first { $0.url == url }?.thumbnail
        // A pin can be resized up to 1200 points wide, which is 2400 pixels on
        // a Retina display: keep above that so text in a large pin is not
        // resampled from a smaller copy.
        guard let image = cached
            ?? ScreenshotImageLoader.downsampledImage(at: url, maxPixelSize: 2800)
        else { return }

        // One pin per file: clicking Pin again brings the existing one forward
        // instead of stacking duplicates.
        if let existing = panels.first(where: { panelURLs[ObjectIdentifier($0)] == url }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentSize = frame?.size ?? displaySize(forPixelSize: image.size)
        let panel = PinnedPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Never hidden just because another app becomes active.
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentAspectRatio = contentSize
        panel.minSize = NSSize(width: 80, height: 80)
        // No fade-in or size animation: the pin is laid out at its final size
        // before it is ordered on screen, so it never flashes through another
        // shape on the way in.
        panel.animationBehavior = .none
        // Never photograph our own pins: their edge and shadow were showing
        // up as a black line in the next area capture.
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        let hostingView = PinnedHostingView(
            rootView: PinnedScreenshotView(
                image: image,
                url: url,
                cornerRadius: PreviewCardMetrics.cornerRadius(for: contentSize),
                onAnnotate: { CaptureShelfPresenter.shared.onAnnotate?(url) },
                onResizeBegan: { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.beginResize(of: panel)
                },
                onResizeChanged: { [weak self, weak panel] translation in
                    guard let panel else { return }
                    self?.resize(panel, by: translation)
                },
                onResizeEnded: { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.endResize(of: panel)
                },
                onClose: { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.close(panel)
                }
            )
        )
        // The panel owns the size; without this the hosting view proposes the
        // image's ideal size first and the window visibly reshapes.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setFrame(
            NSRect(origin: frame?.origin ?? cascadedOrigin(for: contentSize), size: contentSize),
            display: false
        )
        finishDrag(of: panel)
        hostingView.layoutSubtreeIfNeeded()
        panel.alphaValue = 0

        if appToRestore == nil {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                appToRestore = frontmost
            }
        }
        // Make the new pin the key window so ⌘W closes it immediately,
        // without waiting for a click. The app is activated so the key event
        // is delivered here rather than to the page that was captured; the
        // event tap covers the case where the user clicks away first.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panels.insert(panel)
        pinOrder.append(panel)
        panelURLs[ObjectIdentifier(panel)] = url
        // The preview card for this capture is ordered front after the pin is
        // created. That ordering used to take the key window away again, so
        // ⌘W never reached the pin. Claim focus once that has settled.
        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let panel, self.panels.contains(panel), panel.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: Resizing

    private var resizeStarts: [ObjectIdentifier: (origin: CGPoint, size: CGSize)] = [:]

    private func beginResize(of panel: NSPanel) {
        resizeStarts[ObjectIdentifier(panel)] = (panel.frame.origin, panel.frame.size)
    }

    private func resize(_ panel: NSPanel, by translation: CGSize) {
        guard let start = resizeStarts[ObjectIdentifier(panel)] else { return }
        let aspect = start.size.width / max(start.size.height, 1)
        let visible = (screen(containing: panel.frame) ?? NSScreen.main)?.visibleFrame

        // An aspect-locked corner drag grows along the diagonal, so a drag in
        // either direction has to count. Half the sum keeps a true diagonal
        // drag following the pointer exactly, instead of ignoring vertical
        // movement the way the old width-only math did.
        let growth = (translation.width - translation.height) / 2
        let maximumWidth = min(1200, max(200, (visible?.width ?? 1200) - 40))
        let minimumWidth = min(150, start.size.width)
        let newWidth = min(max(minimumWidth, start.size.width + growth), maximumWidth)
        let newHeight = newWidth / aspect

        // Keep the top-left corner where it is while the pin grows, and stop
        // at the screen edges instead of letting the frame slide away.
        var origin = CGPoint(
            x: start.origin.x,
            y: start.origin.y + (start.size.height - newHeight)
        )
        if let visible {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - newWidth)
            origin.y = max(origin.y, visible.minY)
        }

        // No shadow rebuild per mouse event: it is by far the most expensive
        // part of resizing and made the grip feel sticky.
        panel.setFrame(
            CGRect(origin: origin, size: CGSize(width: newWidth, height: newHeight)).integral,
            display: false
        )
    }

    private func endResize(of panel: NSPanel) {
        resizeStarts.removeValue(forKey: ObjectIdentifier(panel))
        panel.invalidateShadow()
        panel.displayIfNeeded()
        finishDrag(of: panel)
    }

    /// After a native drag: keep the pin on screen and refresh its shadow.
    func finishDrag(of panel: NSPanel) {
        guard let screen = screen(containing: panel.frame) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
        }
        panel.invalidateShadow()
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func close(_ panel: NSPanel) {
        guard panels.contains(panel) else { return }
        panels.remove(panel)
        pinOrder.removeAll { $0 === panel }
        panelURLs.removeValue(forKey: ObjectIdentifier(panel))

        // Keep the keyboard inside the stack: after the newest pin goes, the
        // next newest takes focus so ⌘W closes 3, 2, 1 without the app behind
        // ever coming forward. Only the last one hands focus back.
        if let next = pinOrder.last {
            NSApp.activate(ignoringOtherApps: true)
            next.makeKeyAndOrderFront(nil)
            animateOut(panel, handingFocusTo: next)
            return
        }

        if let appToRestore {
            appToRestore.activate()
            self.appToRestore = nil
        }
        animateOut(panel, handingFocusTo: nil)
    }

    /// The pin slides a little to the right and fades, the way CleanShot's
    /// floating image leaves, instead of disappearing on a single frame.
    private func animateOut(_ panel: NSPanel, handingFocusTo next: NSPanel?) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            panel.contentView = nil
            next.map { panel in
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        let target = panel.frame.offsetBy(dx: 34, dy: -6)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        } completionHandler: {
            panel.orderOut(nil)
            panel.contentView = nil
            // Ordering out the window that was key can hand activation back to
            // the previous app, so the next pin claims it once more.
            if let next, next.isVisible {
                NSApp.activate(ignoringOtherApps: true)
                next.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// The pin's right-click menu. A real NSMenu works in a non-activating
    /// panel, where a SwiftUI context menu can miss the event.
    func makeContextMenu(for panel: NSPanel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let url = panelURLs[ObjectIdentifier(panel)] else { return menu }

        menu.addItem(MenuActionItem("Open Annotator", image: "pencil.tip") {
            CaptureShelfPresenter.shared.onAnnotate?(url)
        })
        menu.addItem(MenuActionItem("Copy to Clipboard", image: "doc.on.doc") {
            try? ScreenshotFileActions.copyPNGToClipboard(from: url)
        })
        menu.addItem(MenuActionItem("Copy Text from Image", image: "text.viewfinder") {
            Task {
                let text = await ImageTextRecognizer.recognizeText(at: url)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        })
        menu.addItem(.separator())
        if CloudUploader.shared.isConfigured {
            menu.addItem(MenuActionItem("Upload to Cloud & Copy Link", image: "cloud") {
                Task {
                    do {
                        let result = try await CloudUploader.shared.upload(
                            itemID: UUID(),
                            fileURL: url,
                            socialEnabled: CloudUploadPreferences.lastSocialEnabled
                        )
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.url, forType: .string)
                        ScreenshotHistoryStore.shared.setCloudURL(for: url, cloudURL: result.url)
                    } catch {
                        NSSound.beep()
                    }
                }
            })
        } else {
            menu.addItem(MenuActionItem("Set Up Cloud Upload…", image: "cloud") {
                SettingsWindowController.show(tab: .cloud)
            })
        }
        menu.addItem(MenuActionItem("Save As…", image: "square.and.arrow.down") { [weak self] in
            self?.saveAs(url)
        })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem("Close Pin", image: "xmark") { [weak self, weak panel] in
            guard let panel else { return }
            self?.close(panel)
        })
        return menu
    }

    private func saveAs(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: url)
        panel.canCreateDirectories = true
        panel.title = "Save Screenshot"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? ScreenshotFileActions.save(from: url, to: destination)
        }
    }

    /// Convert pixel dimensions to a sensible point size for the pinned window,
    /// scaled for the display and clamped so pins stay handy but readable.
    private func displaySize(forPixelSize pixelSize: CGSize) -> NSSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var width = pixelSize.width / scale
        var height = pixelSize.height / scale
        guard width > 0, height > 0 else { return NSSize(width: 320, height: 240) }

        let longest = max(width, height)
        let maxLongest: CGFloat = 560
        let minLongest: CGFloat = 160
        let target = min(max(longest, minLongest), maxLongest)
        let factor = target / longest
        width *= factor
        height *= factor
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private func cascadedOrigin(for size: NSSize) -> CGPoint {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 100, y: 100, width: 800, height: 600)
        let offset = CGFloat(panels.count % 8) * 28
        return CGPoint(
            x: visible.midX - size.width / 2 + offset,
            y: visible.midY - size.height / 2 - offset
        )
    }
}

/// A pinned window is rarely key, so without this the first click only keys
/// it. Body presses start the window server's drag loop; the strip holding
/// the hover controls is handed to SwiftUI so its buttons keep working.
private final class PinnedHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let panel = event.window as? NSPanel else { return nil }
        return PinnedScreenshotPresenter.shared.makeContextMenu(for: panel)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a pin gives it focus, so ⌘W here closes the pin.
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
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
        window?.performDrag(with: event)
        if let panel = window as? NSPanel {
            PinnedScreenshotPresenter.shared.finishDrag(of: panel)
        }
    }

    private func isInControlsStrip(_ point: CGPoint) -> Bool {
        // A tiny pin has no capsule, but its close badge and resize grip sit
        // in the corners and must receive the click instead of dragging.
        guard bounds.width >= 160, bounds.height >= 90 else {
            let fromBottom = isFlipped ? bounds.height - point.y : point.y
            let fromTop = isFlipped ? point.y : bounds.height - point.y
            let inClose = fromTop <= 30 && point.x <= 30
            let inGrip = fromBottom <= 30 && point.x >= bounds.width - 30
            return inClose || inGrip
        }
        let fromBottom = isFlipped ? bounds.height - point.y : point.y
        // Wide enough for the labelled capsule, not just the icon row.
        let halfWidth = min(bounds.width * 0.48, 240)
        let inCapsule = fromBottom <= 48 && abs(point.x - bounds.midX) < halfWidth
        // The close badge lives in the top-left corner.
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let inCloseBadge = fromTop <= 40 && point.x <= 40
        return inCapsule || inCloseBadge
    }
}

/// The pin's bottom-right resize grip, backed by AppKit.
///
/// It replaces a SwiftUI drag gesture on a 20-point image: the gesture had to
/// win against the window's own mouse handling, ignored vertical movement and
/// repainted the whole SwiftUI tree on every event, which is why resizing felt
/// sticky. This view takes the mouse events directly and reports raw window
/// deltas, so the window follows the pointer one to one.
private struct PinResizeHandle: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class HandleView: NSView {
        var onBegan: (() -> Void)?
        var onChanged: ((CGSize) -> Void)?
        var onEnded: (() -> Void)?
        private var start: NSPoint?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            onBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            onChanged?(CGSize(width: point.x - start.x, height: point.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            onEnded?()
        }
    }
}

private final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PinnedScreenshotView: View {
    let image: NSImage
    let url: URL
    let cornerRadius: CGFloat
    let onAnnotate: () -> Void
    let onResizeBegan: () -> Void
    let onResizeChanged: (CGSize) -> Void
    let onResizeEnded: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var didCopy = false
    @State private var flash: String?
    @State private var isUploading = false
    @State private var hasAppeared = false
    @State private var flashTask: Task<Void, Never>?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        // Read the live size rather than the size the pin was created at, so
        // a small pin grows its controls when it is enlarged.
        GeometryReader { proxy in
            let size = proxy.size
            let showsControls = size.width >= 160 && size.height >= 90
            let showsLabels = size.width >= 400
            let compactSize = min(22, max(14, min(size.width, size.height) * 0.32))

            ZStack {
                Color.black.opacity(0.92)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(shape)
            .overlay(alignment: .bottom) {
                if isHovered && showsControls {
                    toolbar(showsLabels: showsLabels)
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .overlay(alignment: .topLeading) {
                if isHovered {
                    closeBadge(size: showsControls ? 24 : compactSize)
                        .padding(showsControls ? 8 : 3)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Too small for the capsule, but it still needs a grab handle
                // to be enlarged into one.
                if isHovered && !showsControls {
                    compactResizeGrip(size: compactSize)
                        .padding(3)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let flash {
                    Text(flash)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(white: 0.95).opacity(0.95), in: Capsule())
                        .transition(.opacity)
                }
            }
            .contentShape(shape)
        }
        .scaleEffect(hasAppeared ? 1 : 0.95)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                hasAppeared = true
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.bool(forKey: "previewForceHover") {
                isHovered = true
            }
        }
        #endif
    }

    /// A compact pill of icons along the bottom of the pin, rather than a
    /// full-width bar across the picture.
    private func toolbar(showsLabels: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.black.opacity(0.55))
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
                .help("Drag the screenshot into another app")
                .draggable(url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

            toolbarButton(
                systemImage: "pencil.tip",
                title: showsLabels ? "Annotate" : nil,
                help: "Open Annotator",
                action: onAnnotate
            )
            toolbarButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                title: showsLabels ? "Copy" : nil,
                help: "Copy to clipboard",
                action: copy
            )
            toolbarButton(
                systemImage: isUploading ? "arrow.up.circle" : "cloud",
                title: showsLabels ? "Upload" : nil,
                help: CloudUploader.shared.isConfigured ? "Upload to Cloud and copy link" : "Set up cloud upload",
                action: uploadToCloud
            )
            toolbarButton(
                systemImage: "square.and.arrow.down",
                title: showsLabels ? "Save" : nil,
                help: "Save…",
                action: save
            )
            resizeGrip
        }
        .padding(4)
        .background(Color(white: 0.94).opacity(0.94), in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func closeBadge(size: CGFloat) -> some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: max(8, size * 0.42), weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: size, height: size)
                .background(Color(white: 0.94).opacity(0.94), in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close pin")
    }

    /// The corner grip a pin too small for the toolbar still needs.
    private func compactResizeGrip(size: CGFloat) -> some View {
        ZStack {
            PinResizeHandle(
                onBegan: onResizeBegan,
                onChanged: onResizeChanged,
                onEnded: onResizeEnded
            )
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: max(7, size * 0.4), weight: .bold))
                .foregroundStyle(.black.opacity(0.6))
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .background(Color(white: 0.94).opacity(0.94), in: Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 1))
        .contentShape(Circle())
        .help("Drag to resize")
    }

    private var resizeGrip: some View {
        ZStack {
            PinResizeHandle(
                onBegan: onResizeBegan,
                onChanged: onResizeChanged,
                onEnded: onResizeEnded
            )
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.55))
                .allowsHitTesting(false)
        }
        // A 20-point image was a tiny target. The hit area is wider than the
        // glyph, with a corner-resize cursor so the affordance is obvious.
        .frame(width: 30, height: 22)
        .contentShape(Rectangle())
        .help("Drag to resize")
    }

    private func toolbarButton(
        systemImage: String,
        title: String? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.black.opacity(0.75))
            .padding(.horizontal, title == nil ? 0 : 5)
            .frame(minWidth: 24, minHeight: 22)
            .contentTransition(.symbolEffect(.replace))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copy() {
        do {
            try ScreenshotFileActions.copyPNGToClipboard(from: url)
            withAnimation(.morphQuickIfAllowed) { didCopy = true }
            showFlash("Copied")
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.morphQuickIfAllowed) { didCopy = false }
            }
        } catch {
            print("Failed to copy pinned screenshot: \(error)")
            showFlash("Copy Failed")
        }
    }

    private func copyText() {
        let url = url
        Task {
            let text = await ImageTextRecognizer.recognizeText(at: url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showFlash("Text Copied")
        }
    }

    private func uploadToCloud() {
        guard CloudUploader.shared.isConfigured else {
            openCloudSettings()
            return
        }
        guard !isUploading else { return }
        isUploading = true
        Task {
            defer { isUploading = false }
            do {
                let result = try await CloudUploader.shared.upload(
                    itemID: UUID(),
                    fileURL: url,
                    socialEnabled: CloudUploadPreferences.lastSocialEnabled
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url, forType: .string)
                ScreenshotHistoryStore.shared.setCloudURL(for: url, cloudURL: result.url)
                showFlash("Link Copied")
            } catch {
                showFlash("Upload Failed")
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ScreenshotFileActions.exportContentType]
        panel.nameFieldStringValue = ScreenshotFileActions.exportFileName(for: url)
        panel.canCreateDirectories = true
        panel.title = "Save Screenshot"
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                try ScreenshotFileActions.save(from: url, to: destURL)
            } catch {
                print("Failed to save pinned screenshot: \(error)")
            }
        }
    }

    private func openCloudSettings() {
        SettingsWindowController.show(tab: .cloud)
    }

    private func showFlash(_ message: String) {
        flashTask?.cancel()
        withAnimation(.morphQuickIfAllowed) { flash = message }
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.morphQuickIfAllowed) { flash = nil }
        }
    }
}
