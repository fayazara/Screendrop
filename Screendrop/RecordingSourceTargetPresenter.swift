//
//  RecordingSourceTargetPresenter.swift
//  Screendrop
//
//  Pick the recording source by pointing at it. Choosing Display or Window
//  in the recording bar lays a transparent, click-catching sheet over every
//  screen; the screen or window under the pointer lights up with its name,
//  its size and a Start Recording pill, and a click there starts recording
//  it. The bar floats above the sheet, so switching source or backing out
//  never needs the sheet to go first.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
@Observable
final class RecordingSourceTargetPresenter {
    static let shared = RecordingSourceTargetPresenter()

    enum Mode: Equatable {
        case display
        case window
        /// A browser window, highlighted and recorded as just its page.
        case browserTab
    }

    struct Target: Equatable {
        enum Source: Equatable {
            case display(CGDirectDisplayID)
            case window(CGWindowID)
            case browserTab(CGWindowID)
        }

        let source: Source
        /// Global AppKit coordinates (bottom-left origin).
        let frame: CGRect
        let title: String
        let detail: String
        let icon: NSImage?
    }

    /// What a click does. Browser Tab is also the screenshot picker: the
    /// same sheet, but the click takes a picture instead of recording.
    enum Purpose: Equatable {
        case record
        case screenshot
    }

    private(set) var mode: Mode?
    private(set) var purpose: Purpose = .record
    private(set) var target: Target?

    @ObservationIgnored private var panels: [NSPanel] = []
    /// On-screen, layer-0 windows front to back, snapshotted when the sheet
    /// goes up. Nothing behind the sheet can be moved or raised while it's
    /// up, so the snapshot stays true for as long as it's needed.
    @ObservationIgnored private var windowStack: [(id: CGWindowID, frame: CGRect)] = []
    /// Pages of the browser windows in the stack, found when the sheet goes
    /// up so hovering never waits on another app.
    @ObservationIgnored private var browserContents: [CGWindowID: BrowserContent] = [:]
    /// The frontmost browser window. A screenshot pick lights it up while
    /// the pointer is over anything else, so the shortcut followed by a
    /// click (or Return) captures the tab already in front.
    @ObservationIgnored private var frontmostBrowserWindowID: CGWindowID?
    @ObservationIgnored private var keyMonitors: [Any] = []

    private init() {}

    var isActive: Bool { mode != nil }

    /// Pressing the button for the mode that's already up puts the sheet
    /// away; pressing the other one switches it in place.
    func toggle(_ mode: Mode) {
        if self.mode == mode {
            cancel()
        } else {
            begin(mode)
        }
    }

    func begin(_ mode: Mode, purpose: Purpose = .record) {
        RecordingAreaSelectionPresenter.shared.cancel()
        if mode == .browserTab, !BrowserContentLocator.ensureAccessibilityAccess() {
            cancel()
            return
        }
        self.mode = mode
        self.purpose = mode == .browserTab ? purpose : .record
        if mode != .display {
            snapshotWindowStack()
        }
        showPanels()
        installKeyMonitors()
        updateTarget(at: NSEvent.mouseLocation)
        Task {
            // The bar refreshes the catalog when it appears, but a window
            // opened since then would otherwise be unpickable.
            await RecordingSourceCatalog.shared.refresh()
            guard self.mode == mode else { return }
            if mode != .display {
                snapshotWindowStack()
            }
            if mode == .browserTab {
                await findBrowserContents()
                guard self.mode == mode else { return }
                if browserContents.isEmpty, self.purpose == .screenshot {
                    cancel()
                    BrowserContentLocator.presentNoBrowserFound()
                    return
                }
            }
            updateTarget(at: NSEvent.mouseLocation)
        }
    }

    private func findBrowserContents() async {
        var found: [CGWindowID: BrowserContent] = [:]
        // Front to back, so the frontmost browser lights up first.
        let catalog = RecordingSourceCatalog.shared.windows
        let windows = windowStack.compactMap { entry in catalog.first { $0.windowID == entry.id } }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for window in windows {
            guard let processID = window.owningApplication?.processID,
                  let content = await BrowserContentLocator.content(
                      windowID: window.windowID,
                      processID: processID,
                      windowFrame: window.frame,
                      windowTitle: window.title
                  ) else { continue }
            found[window.windowID] = content
            // The topmost browser window, unless the frontmost app owns one
            // further back (it was the one in use when the shortcut fired).
            let current = frontmostBrowserWindowID.flatMap { found[$0] }
            if current == nil || (processID == frontmostPID && current?.processID != frontmostPID) {
                frontmostBrowserWindowID = window.windowID
            }
            guard mode == .browserTab else { return }
            // Light up the window under the pointer as soon as it's known.
            browserContents = found
            updateTarget(at: NSEvent.mouseLocation)
        }
        browserContents = found
    }

    func cancel() {
        mode = nil
        target = nil
        windowStack = []
        browserContents = [:]
        frontmostBrowserWindowID = nil
        purpose = .record
        removeKeyMonitors()
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
    }

    // MARK: Pointer

    fileprivate func updateTarget(at point: CGPoint) {
        let next: Target? = switch mode {
        case .display: displayTarget(at: point)
        case .window: windowTarget(at: point)
        case .browserTab: browserTabTarget(at: point)
        case nil: nil
        }
        guard next != target else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            target = next
        }
    }

    fileprivate func commit(at point: CGPoint) {
        updateTarget(at: point)
        commitTarget()
    }

    fileprivate func commitTarget() {
        guard let target else { return }
        if purpose == .screenshot, case let .browserTab(windowID) = target.source {
            guard let content = browserContents[windowID] else { return }
            cancel()
            CaptureCoordinator.shared.captureBrowserTab(content)
            return
        }
        let sources = RecordingSourceCatalog.shared

        switch target.source {
        case let .display(displayID):
            guard let display = sources.displays.first(where: { $0.displayID == displayID }) else { return }
            cancel()
            RecordingBarPresenter.shared.closeTeleprompter()
            CaptureCoordinator.shared.recordFullscreen(display)
        case let .window(windowID):
            guard let window = sources.windows.first(where: { $0.windowID == windowID }) else { return }
            cancel()
            RecordingBarPresenter.shared.closeTeleprompter()
            CaptureCoordinator.shared.recordWindow(window)
        case let .browserTab(windowID):
            guard let window = sources.windows.first(where: { $0.windowID == windowID }) else { return }
            cancel()
            RecordingBarPresenter.shared.closeTeleprompter()
            CaptureCoordinator.shared.recordBrowserTab(window)
        }
    }

    private func displayTarget(at point: CGPoint) -> Target? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let displayID = ActiveDisplayResolver.displayID(for: screen),
              RecordingSourceCatalog.shared.displays.contains(where: { $0.displayID == displayID }) else {
            return nil
        }

        let scale = screen.backingScaleFactor
        let size = "\(Int(screen.frame.width * scale))×\(Int(screen.frame.height * scale))"
        let fps = screen.maximumFramesPerSecond
        return Target(
            source: .display(displayID),
            frame: screen.frame,
            title: screen.localizedName,
            detail: fps > 0 ? "\(size) · \(fps) FPS" : size,
            icon: nil
        )
    }

    private func windowTarget(at point: CGPoint) -> Target? {
        // Frontmost window under the pointer wins. If that window isn't one
        // the catalog can record, nothing lights up rather than the window
        // hidden behind it.
        guard let hit = windowStack.first(where: { $0.frame.contains(point) }),
              let window = RecordingSourceCatalog.shared.windows.first(where: { $0.windowID == hit.id }) else {
            return nil
        }

        let app = window.owningApplication
        let appName = app?.applicationName ?? "Window"
        let title = (window.title?.isEmpty == false) ? window.title! : appName
        let scale = NSScreen.screens
            .first { NSMouseInRect(CGPoint(x: hit.frame.midX, y: hit.frame.midY), $0.frame, false) }?
            .backingScaleFactor ?? 2
        let size = "\(Int(hit.frame.width * scale))×\(Int(hit.frame.height * scale))"
        let icon = app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }

        return Target(
            source: .window(hit.id),
            frame: hit.frame,
            title: title,
            detail: title == appName ? size : "\(appName) · \(size)",
            icon: icon
        )
    }

    /// Like a window pick, but only browser windows light up, and only
    /// their page.
    private func browserTabTarget(at point: CGPoint) -> Target? {
        let hit = windowStack.first(where: { $0.frame.contains(point) })
        let windowID: CGWindowID?
        if let hit, browserContents[hit.id] != nil {
            windowID = hit.id
        } else if purpose == .screenshot {
            windowID = frontmostBrowserWindowID
        } else {
            windowID = nil
        }
        guard let windowID, let content = browserContents[windowID] else { return nil }

        let app = NSRunningApplication(processIdentifier: content.processID)
        let appName = app?.localizedName ?? "Browser"
        let frame = content.appKitContentFrame
        let scale = NSScreen.screens
            .first { NSMouseInRect(CGPoint(x: frame.midX, y: frame.midY), $0.frame, false) }?
            .backingScaleFactor ?? 2
        let size = "\(Int(frame.width * scale))×\(Int(frame.height * scale))"

        return Target(
            source: .browserTab(windowID),
            frame: frame,
            title: content.windowTitle ?? appName,
            detail: "\(appName) tab · \(size)",
            icon: app?.icon
        )
    }

    private func snapshotWindowStack() {
        let recordable = Set(RecordingSourceCatalog.shared.windows.map(\.windowID))
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // CoreGraphics reports top-left-origin frames measured from the
        // primary display; AppKit's are bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier

        windowStack = info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                return nil
            }
            let id = CGWindowID(number.uint32Value)
            // Our own windows (Library, editors) never occlude a pick unless
            // they're recordable themselves - the sheet is what's on top.
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if pid == ownPID && !recordable.contains(id) { return nil }
            if (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 0 { return nil }
            return (id, CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height))
        }
    }

    // MARK: Escape

    /// Esc backs out of the sheet without closing the bar. The bar's own
    /// panel handles it while Screendrop is active; the global monitor covers
    /// the usual case of picking from inside another app, and is a no-op
    /// without Accessibility access.
    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        let isEscape: (NSEvent) -> Bool = { $0.keyCode == 53 }
        // Return / Enter takes the highlighted tab, for a keyboard-only
        // shortcut-then-confirm screenshot.
        let isReturn: (NSEvent) -> Bool = { $0.keyCode == 36 || $0.keyCode == 76 }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.isActive else { return event }
            if isEscape(event) {
                self.cancel()
                return nil
            }
            if isReturn(event), self.purpose == .screenshot {
                self.commitTarget()
                return nil
            }
            return event
        }) {
            keyMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let escape = isEscape(event)
            let enter = isReturn(event)
            guard escape || enter else { return }
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                if escape {
                    self.cancel()
                } else if self.purpose == .screenshot {
                    self.commitTarget()
                }
            }
        }) {
            keyMonitors.append(global)
        }
    }

    private func removeKeyMonitors() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors = []
    }

    // MARK: Panels

    private func showPanels() {
        guard panels.isEmpty else { return }
        panels = NSScreen.screens.map(makePanel(for:))
        for panel in panels {
            panel.orderFrontRegardless()
        }
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = RecordingSourceTargetPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Over every app window, under the recording bar (`.floating`), so
        // the bar stays usable while the sheet is up.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        // The sheet is clear, and the window server passes clicks on clear
        // pixels to whatever is behind. Setting this explicitly makes the
        // whole panel catch them, whatever the overlay happens to draw.
        panel.ignoresMouseEvents = false
        panel.setFrame(screen.frame, display: false)

        let sheet = RecordingSourceTargetSheetView(frame: CGRect(origin: .zero, size: screen.frame.size))
        sheet.autoresizingMask = [.width, .height]

        let hostingView = NSHostingView(rootView: RecordingSourceTargetOverlay(screenFrame: screen.frame))
        hostingView.frame = sheet.bounds
        // Sized by the panel, never the other way round - see
        // RecordingBarPresenter.makePanel.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        sheet.addSubview(hostingView)

        panel.contentView = sheet
        return panel
    }
}

private final class RecordingSourceTargetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Catches every pointer event on its screen. The SwiftUI overlay inside it
/// only draws; the hit-testing is by target frame, which is simpler than
/// keeping a SwiftUI button and a whole-window click in agreement.
private final class RecordingSourceTargetSheetView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        RecordingSourceTargetPresenter.shared.updateTarget(at: NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        let presenter = RecordingSourceTargetPresenter.shared
        (presenter.purpose == .screenshot ? CameraCursor.shared : NSCursor.arrow).set()
        RecordingSourceTargetPresenter.shared.updateTarget(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        RecordingSourceTargetPresenter.shared.commit(at: NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        RecordingSourceTargetPresenter.shared.cancel()
    }
}

// MARK: - Overlay

private struct RecordingSourceTargetOverlay: View {
    let screenFrame: CGRect

    @State private var presenter = RecordingSourceTargetPresenter.shared

    var body: some View {
        GeometryReader { _ in
            if let target = presenter.target,
               let local = localRect(for: target.frame) {
                let visible = local.intersection(CGRect(origin: .zero, size: screenFrame.size))
                let shape = RoundedRectangle(cornerRadius: highlightRadius(for: target), style: .continuous)

                shape
                    .fill(Palette.highlight.opacity(0.28))
                    .overlay {
                        shape.strokeBorder(Palette.highlight, lineWidth: 2)
                    }
                    .frame(width: local.width, height: local.height)
                    .position(x: local.midX, y: local.midY)

                // The card is drawn once, on the screen holding the middle of
                // what's visible, so a window straddling two displays doesn't
                // get two of them.
                if ownsCard(for: target) {
                    RecordingSourceTargetCard(target: target)
                        .position(x: visible.midX, y: visible.midY)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Displays are lit edge to edge; windows follow the system's window
    /// corners so the highlight sits on the window rather than around it.
    private func highlightRadius(for target: RecordingSourceTargetPresenter.Target) -> CGFloat {
        switch target.source {
        case .display: 0
        case .window: 16
        case .browserTab: 8
        }
    }

    /// The target's frame in this screen's SwiftUI space (top-left origin),
    /// or nil when it doesn't touch this screen.
    private func localRect(for frame: CGRect) -> CGRect? {
        guard frame.intersects(screenFrame) else { return nil }
        return CGRect(
            x: frame.minX - screenFrame.minX,
            y: screenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func ownsCard(for target: RecordingSourceTargetPresenter.Target) -> Bool {
        let screens = NSScreen.screens.map(\.frame)
        let owner = screens.max { lhs, rhs in
            area(lhs.intersection(target.frame)) < area(rhs.intersection(target.frame))
        }
        return owner == screenFrame
    }

    private func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

private struct RecordingSourceTargetCard: View {
    let target: RecordingSourceTargetPresenter.Target

    private var isDisplay: Bool {
        if case .display = target.source { return true }
        return false
    }

    private var isScreenshot: Bool {
        RecordingSourceTargetPresenter.shared.purpose == .screenshot
    }

    var body: some View {
        VStack(spacing: 10) {
            if let icon = target.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 56, height: 56)
            }

            VStack(spacing: 4) {
                Text(target.title)
                    .font(.system(size: isDisplay ? 30 : 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(target.detail)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)

            HStack(spacing: 6) {
                Image(systemName: isScreenshot ? "camera.fill" : "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(isScreenshot ? "Capture Tab" : "Start Recording")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            // Solid rather than glass: glass in this never-key panel renders
            // untinted, and the pill has to read over any content.
            .background(isScreenshot ? Palette.accent : Palette.record, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
            .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .padding(20)
    }
}

/// The camera pointer `screencapture -w` uses while picking: a white camera
/// with a dark outline, so it reads over any page.
@MainActor
private enum CameraCursor {
    static let shared: NSCursor = {
        let size = CGSize(width: 28, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return false }
            let symbolRect = CGRect(
                x: (rect.width - symbol.size.width) / 2,
                y: (rect.height - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            for (color, offsets) in [
                (NSColor.black.withAlphaComponent(0.85), [(-1.5, 0), (1.5, 0), (0, -1.5), (0, 1.5)]),
                (NSColor.white, [(0, 0)])
            ] as [(NSColor, [(CGFloat, CGFloat)])] {
                let tinted = NSImage(size: symbol.size, flipped: false) { tintRect in
                    symbol.draw(in: tintRect)
                    color.set()
                    tintRect.fill(using: .sourceAtop)
                    return true
                }
                for (dx, dy) in offsets {
                    tinted.draw(in: symbolRect.offsetBy(dx: dx, dy: dy))
                }
            }
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }()
}
