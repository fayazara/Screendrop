//
//  RecordingAreaSelectionPresenter.swift
//  Screendrop
//
//  Pick the area to record. Choosing Area in the recording bar lays a dimmed
//  sheet over every screen, under the bar, the same way Display and Window
//  do. Drag out a region and it stays: grab its handles to resize it, drag
//  it to move it, type an exact size or lock a ratio in the bar, then Start
//  Recording (or Return). The ratio holds while drawing and resizing, so a
//  16:9 selection stays 16:9 however it's adjusted.
//
//  The sheet itself is RecordingAreaSelectionSheet; the bar's size and ratio
//  controls are RecordingAreaBarControls.
//

import AppKit
import QuartzCore
import ScreenCaptureKit

@MainActor
@Observable
final class RecordingAreaSelectionPresenter {
    static let shared = RecordingAreaSelectionPresenter()

    struct Selection: Equatable {
        let displayID: CGDirectDisplayID
        /// The screen the selection is on, in global AppKit coordinates. A
        /// selection never spans screens - a recording is of one display.
        let screenFrame: CGRect
        /// Points per pixel on that screen.
        let scale: CGFloat
        /// Global AppKit coordinates (bottom-left origin).
        var rect: CGRect

        var pixelSize: (width: Int, height: Int) {
            (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
        }
    }

    private(set) var isActive = false
    private(set) var selection: Selection?
    /// The ratio the selection is held to; nil is freeform. Remembered
    /// across recordings.
    private(set) var aspect: RecordingAreaAspect? = ScreendropPreferences.recordingAreaAspect
    /// True while the pointer is drawing, moving or resizing the selection.
    /// The sheet shows its size and thirds guides then, and puts the Start
    /// Recording pill away.
    private(set) var isInteracting = false
    /// What the sheet draws while a programmatic change (a ratio, a typed
    /// size, a swap) eases toward `selection.rect`. Nil when it's at rest.
    private(set) var displayedRect: CGRect?
    /// Held while the pointer is down on the Start Recording pill.
    private(set) var isPillPressed = false

    /// Each screen's pill, in that sheet's top-left coordinates, so a click
    /// on it can be told apart from a click that moves the selection.
    @ObservationIgnored var pillFrames: [CGDirectDisplayID: CGRect] = [:]

    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var sheets: [RecordingAreaSelectionSheet] = []
    @ObservationIgnored private var keyMonitors: [Any] = []
    @ObservationIgnored private var easeTask: Task<Void, Never>?

    private init() {}

    var ratio: CGFloat? { aspect?.ratio }

    // MARK: Lifecycle

    /// Pressing Area again while it's up puts the sheet away, like Display
    /// and Window.
    func toggle() {
        if isActive {
            cancel()
        } else {
            begin()
        }
    }

    func begin() {
        RecordingSourceTargetPresenter.shared.cancel()
        guard !isActive else { return }
        isActive = true
        restoreLastSelection()
        showPanels()
        installKeyMonitors()
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        easeTask?.cancel()
        displayedRect = nil
        isInteracting = false
        isPillPressed = false
        selection = nil
        pillFrames = [:]
        removeKeyMonitors()
        let hadKey = panels.contains(where: \.isKeyWindow)
        for panel in panels {
            panel.orderOut(nil)
        }
        panels = []
        sheets = []
        if hadKey {
            RecordingBarPresenter.shared.reclaimKey()
        }
    }

    /// Records the selection. The bar stays up and morphs into the session
    /// controls once capture starts, as it does for Display and Window.
    func commit() {
        guard let selection,
              let display = RecordingSourceCatalog.shared.displays.first(where: { $0.displayID == selection.displayID }) else {
            NSSound.beep()
            return
        }
        ScreendropPreferences.recordingAreaLastSelection = (selection.displayID, selection.rect)
        cancel()
        RecordingBarPresenter.shared.closeTeleprompter()
        CaptureCoordinator.shared.recordArea(display, rect: selection.rect)
    }

    /// Hands the keyboard back to the sheet after a size field is done with,
    /// so Return records and the arrows nudge again.
    func focusSheet() {
        let target = selection.flatMap { selection in
            sheets.firstIndex { $0.displayID == selection.displayID }
        } ?? sheets.firstIndex { NSMouseInRect(NSEvent.mouseLocation, $0.screenFrame, false) }
        guard let target, panels.indices.contains(target) else { return }
        panels[target].makeKey()
    }

    // MARK: Ratio and size

    func setAspect(_ aspect: RecordingAreaAspect?) {
        self.aspect = aspect
        ScreendropPreferences.recordingAreaAspect = aspect
        guard let aspect, let selection else { return }
        ease(to: RecordingAreaGeometry.reshaped(selection.rect, to: aspect.ratio, in: selection.screenFrame))
    }

    /// The ratio of the selection as it stands, offered when it's freeform.
    var currentAspect: RecordingAreaAspect? {
        guard let selection else { return nil }
        let size = selection.pixelSize
        return RecordingAreaAspect.of(pixelWidth: size.width, pixelHeight: size.height)
    }

    func lockCurrentRatio() {
        guard let currentAspect else { return }
        setAspect(currentAspect)
    }

    /// Turns the selection on its side about its centre, and the locked
    /// ratio with it - 16:9 becomes 9:16.
    func swapOrientation() {
        if let aspect {
            self.aspect = aspect.swapped
            ScreendropPreferences.recordingAreaAspect = aspect.swapped
        }
        guard let selection else { return }
        let rect = selection.rect
        ease(to: RecordingAreaGeometry.placed(
            CGSize(width: rect.height, height: rect.width),
            around: CGPoint(x: rect.midX, y: rect.midY),
            in: selection.screenFrame
        ))
    }

    /// Typed into the bar. A locked ratio carries the other side along;
    /// with nothing selected yet, the size is centred on the screen.
    func setPixelWidth(_ width: Int) {
        resize { size, scale in
            let width = CGFloat(width) / scale
            let height = ratio.map { width / $0 } ?? size?.height ?? width
            return CGSize(width: width, height: height)
        }
    }

    func setPixelHeight(_ height: Int) {
        resize { size, scale in
            let height = CGFloat(height) / scale
            let width = ratio.map { height * $0 } ?? size?.width ?? height
            return CGSize(width: width, height: height)
        }
    }

    private func resize(_ makeSize: (CGSize?, CGFloat) -> CGSize) {
        if let selection {
            let size = makeSize(selection.rect.size, selection.scale)
            ease(to: RecordingAreaGeometry.placed(
                size,
                around: CGPoint(x: selection.rect.midX, y: selection.rect.midY),
                in: selection.screenFrame
            ))
            return
        }
        guard let sheet = homeSheet else { return }
        let size = makeSize(nil, sheet.scale)
        let frame = sheet.screenFrame
        let rect = RecordingAreaGeometry.placed(size, around: CGPoint(x: frame.midX, y: frame.midY), in: frame)
        update(rect: rect, on: sheet)
    }

    /// Arrow keys: a point at a time, ten with Shift.
    func nudge(by delta: CGSize) {
        guard let selection else { return }
        finishEase()
        setRect(RecordingAreaGeometry.moved(selection.rect, by: delta, in: selection.screenFrame))
    }

    // MARK: Sheet interaction

    /// The sheet's pointer interactions land here, already in global
    /// coordinates. Moving to another screen starts the selection afresh
    /// there.
    func update(rect: CGRect, on sheet: RecordingAreaSelectionSheet) {
        easeTask?.cancel()
        displayedRect = nil
        let snapped = RecordingAreaGeometry.snapped(rect, scale: sheet.scale, ratio: ratio, in: sheet.screenFrame)
        if selection?.displayID == sheet.displayID {
            selection?.rect = snapped
        } else {
            selection = Selection(displayID: sheet.displayID, screenFrame: sheet.screenFrame, scale: sheet.scale, rect: snapped)
        }
        redraw()
    }

    func restore(_ previous: Selection?) {
        selection = previous
        redraw()
    }

    func setInteracting(_ interacting: Bool) {
        guard interacting != isInteracting else { return }
        isInteracting = interacting
        redraw()
    }

    func setPillPressed(_ pressed: Bool) {
        isPillPressed = pressed
    }

    /// Where the selection is drawn right now - eased, or at rest.
    var visibleRect: CGRect? {
        displayedRect ?? selection?.rect
    }

    // MARK: Drawing

    private func setRect(_ rect: CGRect) {
        guard let selection else { return }
        self.selection?.rect = RecordingAreaGeometry.snapped(
            rect, scale: selection.scale, ratio: ratio, in: selection.screenFrame
        )
        redraw()
    }

    /// Programmatic changes glide to their new shape over a fraction of a
    /// second, so a ratio pick reads as the selection changing rather than
    /// being replaced. The selection itself jumps to the result at once -
    /// only the drawing follows - so Return mid-glide records the final
    /// framing.
    private func ease(to rect: CGRect) {
        guard let selection else { return }
        let from = visibleRect ?? selection.rect
        setRect(rect)
        guard let to = self.selection?.rect, from != to,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishEase()
            return
        }

        easeTask?.cancel()
        displayedRect = from
        easeTask = Task { [weak self] in
            let duration: CFTimeInterval = 0.22
            let start = CACurrentMediaTime()
            while !Task.isCancelled {
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = CGFloat(1 - pow(1 - t, 3))
                guard let self else { return }
                if t >= 1 {
                    self.finishEase()
                    return
                }
                self.displayedRect = CGRect(
                    x: from.minX + (to.minX - from.minX) * eased,
                    y: from.minY + (to.minY - from.minY) * eased,
                    width: from.width + (to.width - from.width) * eased,
                    height: from.height + (to.height - from.height) * eased
                )
                self.redraw()
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func finishEase() {
        easeTask?.cancel()
        easeTask = nil
        displayedRect = nil
        redraw()
    }

    private func redraw() {
        for sheet in sheets {
            sheet.selectionDidChange()
        }
    }

    // MARK: Restore

    /// A retake usually wants the same framing, so the last area recorded
    /// comes back - as long as its display is still attached and holds it.
    private func restoreLastSelection() {
        selection = nil
        guard let last = ScreendropPreferences.recordingAreaLastSelection,
              let screen = ActiveDisplayResolver.screen(for: last.displayID),
              screen.frame.contains(last.rect),
              RecordingAreaGeometry.isLargeEnough(last.rect) else {
            return
        }
        var rect = last.rect
        if let ratio, !RecordingAreaGeometry.matches(rect, ratio: ratio, scale: screen.backingScaleFactor) {
            rect = RecordingAreaGeometry.reshaped(rect, to: ratio, in: screen.frame)
        }
        selection = Selection(
            displayID: last.displayID,
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor,
            rect: RecordingAreaGeometry.snapped(rect, scale: screen.backingScaleFactor, ratio: ratio, in: screen.frame)
        )
    }

    /// The screen a typed size lands on when nothing is selected yet: the
    /// one the bar is on.
    private var homeSheet: RecordingAreaSelectionSheet? {
        let anchor = RecordingBarPresenter.shared.barFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? NSEvent.mouseLocation
        return sheets.first { NSMouseInRect(anchor, $0.screenFrame, false) } ?? sheets.first
    }

    /// The screen that shows the "drag to select" hint while there's no
    /// selection - the bar's.
    func isHome(_ displayID: CGDirectDisplayID) -> Bool {
        homeSheet?.displayID == displayID
    }

    // MARK: Keyboard

    /// Esc puts the sheet away (the next Esc closes the bar), Return records,
    /// and the arrows nudge. A size field being typed in keeps its keys. The
    /// global monitor covers Esc while another app is frontmost, and is a
    /// no-op without Accessibility access.
    private func installKeyMonitors() {
        guard keyMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.isActive else { return event }
            return self.handleKey(event) ? nil : event
        }) {
            keyMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.cancel() }
        }) {
            keyMonitors.append(global)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let isEditingText = NSApp.keyWindow?.firstResponder is NSText
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1

        switch event.keyCode {
        case 53:
            guard !isEditingText else { return false }
            cancel()
        case 36, 76:
            guard !isEditingText, selection != nil else { return false }
            commit()
        case 123 where !isEditingText:
            nudge(by: CGSize(width: -step, height: 0))
        case 124 where !isEditingText:
            nudge(by: CGSize(width: step, height: 0))
        case 125 where !isEditingText:
            nudge(by: CGSize(width: 0, height: -step))
        case 126 where !isEditingText:
            nudge(by: CGSize(width: 0, height: step))
        default:
            return false
        }
        return true
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
        for screen in NSScreen.screens {
            guard let displayID = ActiveDisplayResolver.displayID(for: screen) else { continue }
            let sheet = RecordingAreaSelectionSheet(
                displayID: displayID,
                screenFrame: screen.frame,
                scale: screen.backingScaleFactor
            )
            panels.append(makePanel(for: screen, sheet: sheet))
            sheets.append(sheet)
        }
        for panel in panels {
            panel.orderFrontRegardless()
        }
        // Key without activating, so Return and the arrows reach the sheet
        // while the app being recorded stays frontmost.
        focusSheet()
    }

    private func makePanel(for screen: NSScreen, sheet: RecordingAreaSelectionSheet) -> NSPanel {
        let panel = RecordingAreaSelectionPanel(
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
        // the size and ratio controls stay usable while the sheet is up.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = false
        panel.setFrame(screen.frame, display: false)

        sheet.frame = CGRect(origin: .zero, size: screen.frame.size)
        sheet.autoresizingMask = [.width, .height]
        panel.contentView = sheet
        return panel
    }
}

private final class RecordingAreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
