//
//  RecordingBarPresenter.swift
//  Screendrop
//
//  One floating bar, two modes. Before recording it picks the source and the
//  capture inputs; during recording it drives the session. They share a
//  single panel so the handoff is a morph - the bar's rounded rect animates
//  to the new width while the controls cross-fade - rather than one window
//  vanishing and another appearing somewhere near it.
//
//  RecordingPickerPresenter and RecordingControlPresenter are the entry
//  points callers still use; both forward here.
//

import AppKit
import SwiftUI

@Observable
@MainActor
final class RecordingBarPresenter {
    static let shared = RecordingBarPresenter()

    enum Mode: Equatable {
        case picker
        case recording
    }

    private(set) var mode: Mode = .picker
    /// Whether the bar is unfolded into the teleprompter's script editor.
    /// Picker mode only.
    private(set) var isTeleprompterOpen = false

    /// The bar's frame inside the panel's content view, reported by SwiftUI.
    /// The panel is deliberately much larger than the bar, so this is what
    /// tells the hosting view which part of itself is real and satellite
    /// windows where to anchor.
    var barFrameInPanel: CGRect = .zero
    var visibilityBannerFrameInPanel: CGRect = .zero
    /// The area pill beside the bar, while the area picker is up.
    var areaPillFrameInPanel: CGRect?

    func containsPanelPoint(_ point: CGPoint) -> Bool {
        if barFrameInPanel.contains(point) { return true }
        if let areaPillFrameInPanel, areaPillFrameInPanel.contains(point) { return true }
        return mode == .picker
            && ScreendropPreferences.includeAppWindowsInCaptures
            && visibilityBannerFrameInPanel.contains(point)
    }

    @ObservationIgnored private var panel: NSPanel?

    private init() {}

    // MARK: Teleprompter

    func toggleTeleprompter() {
        withAnimation(BarMetrics.modeChange) { isTeleprompterOpen.toggle() }
        // Typing goes to the key window; the panel is nonactivating, so
        // this never activates Screendrop.
        if isTeleprompterOpen { panel?.makeKey() }
    }

    func closeTeleprompter() {
        guard isTeleprompterOpen else { return }
        withAnimation(BarMetrics.modeChange) { isTeleprompterOpen = false }
    }

    // MARK: Picker

    func togglePicker() {
        if let panel, panel.isVisible, mode == .picker {
            hide()
        } else {
            showPicker()
        }
    }

    func showPicker() {
        let panel = panel ?? makePanel()
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        Task {
            await RecordingSourceCatalog.shared.refresh()
        }
        mode = .picker
        position(panel, displayID: ActiveDisplayResolver.activeDisplayID(preferPointer: false))
        panel.orderFrontRegardless()
        // Key without activating (the panel is nonactivating): pointer styles
        // and Esc both resolve against the key window. Key-ness is dormant
        // while Screendrop isn't the active app, so this never pulls
        // keystrokes out of the app being recorded.
        panel.makeKey()
        warmCameraPreviewIfEnabled()
    }

    // MARK: Recording

    /// Called once capture is actually starting. If the bar is already up on
    /// the recording's display it morphs in place; otherwise it has to move,
    /// and there's nothing to morph from.
    func showRecording(displayID: CGDirectDisplayID?) {
        let panel = panel ?? makePanel()
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        RecordingSourceTargetPresenter.shared.cancel()
        RecordingAreaSelectionPresenter.shared.cancel()

        let isMorphing = panel.isVisible && isPositioned(panel, onDisplayID: displayID)
        if isMorphing {
                withAnimation(BarMetrics.modeChange) {
                mode = .recording
                isTeleprompterOpen = false
            }
        } else {
            mode = .recording
            isTeleprompterOpen = false
            position(panel, displayID: displayID)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        if mode == .picker { CaptureCountdownPresenter.shared.cancel() }
        RecordingSourceTargetPresenter.shared.cancel()
        RecordingAreaSelectionPresenter.shared.cancel()
        // `orderOut` sends no exit events, so a hover that's live when the
        // bar hides has to be ended by hand, or its puck would linger.
        BarControlHoverView.endActiveHover()
        panel?.orderOut(nil)
        // Next appearance should always start as the folded picker, and
        // without animating out of a mode nobody can see.
        mode = .picker
        isTeleprompterOpen = false
    }

    /// Takes the keyboard back from a sheet that's going away, so the next
    /// Esc reaches the bar and closes it.
    func reclaimKey() {
        guard let panel, panel.isVisible else { return }
        panel.makeKey()
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return containsPanelPoint(CGPoint(
            x: point.x - panel.frame.minX,
            y: panel.frame.maxY - point.y
        ))
    }

    // MARK: Geometry

    /// Where the bar currently sits on screen, so satellite windows can
    /// anchor to it even after the user drags it around. This is the visible bar, not the panel: the panel is padded
    /// out with transparent slack for the tooltips and shadows, and anchoring
    /// to that would leave satellites floating clear of the bar.
    var barFrame: CGRect? {
        guard let panel, panel.isVisible, barFrameInPanel != .zero else { return nil }
        // SwiftUI reports a top-left origin; screen coordinates are bottom-up.
        return CGRect(
            x: panel.frame.minX + barFrameInPanel.minX,
            y: panel.frame.maxY - barFrameInPanel.maxY,
            width: barFrameInPanel.width,
            height: barFrameInPanel.height
        )
    }

    /// The area pill on screen, so the area sheet can keep its Start
    /// Recording pill clear of it.
    var areaPillFrame: CGRect? {
        guard let panel, panel.isVisible, let frame = areaPillFrameInPanel else { return nil }
        return CGRect(
            x: panel.frame.minX + frame.minX,
            y: panel.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func isPositioned(_ panel: NSPanel, onDisplayID displayID: CGDirectDisplayID?) -> Bool {
        guard let target = ActiveDisplayResolver.screen(for: displayID) else { return true }
        return target.frame.intersects(panel.frame)
    }

    private func position(_ panel: NSPanel, displayID: CGDirectDisplayID?) {
        let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: BarMetrics.panelWidth, height: BarMetrics.panelHeight)
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            // Dropped by the bottom slack so the bar - not the panel - lands
            // 48pt above the visible frame.
            y: visibleFrame.minY + 48 - BarMetrics.bottomSlack
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// The bar's hosting view is created once and just reordered in/out on
    /// every show/hide, so its SwiftUI `.task` never reruns after the first
    /// appearance. Reading the camera preference here - on every real
    /// `showPicker()` - is what makes a camera left on from a previous
    /// session warm up immediately instead of needing an off/on toggle.
    private func warmCameraPreviewIfEnabled() {
        let cameraID = ScreendropPreferences.recordingCameraDeviceID
        guard !cameraID.isEmpty else { return }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        Task {
            await CameraRecordingManager.shared.startPreview(deviceID: cameraID, displayID: displayID)
        }
    }

    private func makePanel() -> NSPanel {
        let size = CGSize(width: BarMetrics.panelWidth, height: BarMetrics.panelHeight)
        let panel = RecordingBarPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Shadows are drawn in SwiftUI, not by AppKit. The window shadow is
        // derived from the window's alpha silhouette and recomputed lazily,
        // so anything that fades or resizes inside the panel - the tooltip,
        // the morph - leaves its shadow outline hanging for a frame or two
        // after the fill has moved on. The panel reserves slack on all four
        // sides so SwiftUI's shadows aren't clipped by the panel edge, which
        // was the original reason for using the AppKit one.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        // The controls track hover themselves so they still highlight while
        // Screendrop is in the background, which is the whole time a recording
        // is running. Their tracking areas need the moved events.
        panel.acceptsMouseMovedEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        let hostingView = RecordingBarHostingView(rootView: RecordingBarView())
        hostingView.frame = CGRect(origin: .zero, size: size)
        // The panel is sized explicitly and the bar inside it animates its own
        // width during a morph. Left to bridge its ideal size onto the
        // window, the hosting view and the window fight over sizing every
        // frame until AppKit's constraint watchdog kills the app.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.isOpaque = false

        self.panel = panel
        return panel
    }
}

private final class RecordingBarPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        // Escape backs out of picking a source; it must not abandon a
        // recording that's already running.
        guard RecordingBarPresenter.shared.mode == .picker else { return }
        // The open teleprompter folds away first.
        if RecordingBarPresenter.shared.isTeleprompterOpen {
            RecordingBarPresenter.shared.closeTeleprompter()
            return
        }
        // First Esc puts away the point-to-pick or area sheet; the next one
        // closes the bar.
        if RecordingAreaSelectionPresenter.shared.isActive {
            RecordingAreaSelectionPresenter.shared.cancel()
            return
        }
        if RecordingSourceTargetPresenter.shared.isActive {
            RecordingSourceTargetPresenter.shared.cancel()
            return
        }
        RecordingBarPresenter.shared.hide()
        Task { await CameraRecordingManager.shared.stopPreview() }
    }
}

private final class RecordingBarHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }

    /// The panel is much larger than the bar - fixed size, so a morph never
    /// resizes the window, plus slack for tooltips and shadows. AppKit
    /// hit-tests by view bounds, not alpha, so without this all that empty
    /// space would silently swallow clicks meant for whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // SwiftUI reports a top-left origin, and NSHostingView is flipped, so
        // the two agree without conversion.
        guard RecordingBarPresenter.shared.containsPanelPoint(convert(point, from: superview)) else {
            return nil
        }
        return super.hitTest(point)
    }
}

// MARK: - Bar

private struct RecordingBarView: View {
    @State private var presenter = RecordingBarPresenter.shared
    @State private var area = RecordingAreaSelectionPresenter.shared
    @State private var tooltip = BarTooltipModel()
    /// The control row's width, which the teleprompter matches so opening
    /// it grows the bar upward only.
    @State private var rowWidth: CGFloat = 0
    @AppStorage(ScreendropPreferences.includeAppWindowsInCapturesKey)
    private var includeAppWindowsInCaptures = false

    var body: some View {
        bar
            // The panel is a fixed size both modes sit inside, so a morph only
            // ever changes the bar's own width - never the window's. The bar
            // sits at the bottom: the slack above it is the tooltip's room,
            // the slack below holds the reminder and its shadow. Reserving
            // it in both modes keeps the bar stationary when it disappears.
            .padding(.bottom, BarMetrics.bottomSlack)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .coordinateSpace(.named(BarCoordinateSpace.panel))
            .environment(tooltip)
            .onChange(of: includeAppWindowsInCaptures) { _, _ in
                PreviewWindowCaptureExclusion.shared.refreshRegisteredWindows()
                Task { await RecordingSourceCatalog.shared.refresh() }
            }
    }

    private var showsTeleprompter: Bool {
        presenter.mode == .picker && presenter.isTeleprompterOpen
    }

    private var bar: some View {
        VStack(spacing: 0) {
            if showsTeleprompter {
                RecordingBarTeleprompter()
                    .frame(width: rowWidth)
                    .transition(.opacity)
            }

            controlRow
        }
        // Clipped to the same shape the glass takes, so a morph reveals and
        // hides content behind the moving edge instead of letting it spill.
        .clipShape(barShape)
        .glassEffect(.regular, in: barShape)
        .overlay {
            barShape.strokeBorder(BarMetrics.edge, lineWidth: 0.5)
        }
        .background(alignment: .bottom) {
            if presenter.mode == .picker && includeAppWindowsInCaptures {
                visibilityBanner
                    .padding(.horizontal, BarMetrics.visibilityBannerInset)
                    .offset(y: BarMetrics.visibilityBannerHeight - BarMetrics.visibilityBannerOverlap)
            }
        }
        // The area controls are a pill of their own hanging off the bar's
        // trailing end, so choosing Area never reshapes or moves the bar.
        .overlay(alignment: .bottomTrailing) {
            if presenter.mode == .picker && area.isActive {
                RecordingAreaBarPill()
                    .alignmentGuide(.trailing) { $0[.leading] - BarMetrics.pillGap }
                    .transition(
                        .opacity.combined(with: .offset(x: -12))
                            .animation(.easeOut(duration: 0.18))
                    )
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(BarCoordinateSpace.panel))
                    } action: {
                        presenter.areaPillFrameInPanel = $0
                    }
                    .onDisappear {
                        presenter.areaPillFrameInPanel = nil
                    }
            }
        }
        // The tooltip rides on the control row, outside the clip, so it
        // floats just above the controls whether or not the bar is unfolded.
        .overlay(alignment: .bottom) {
            tooltipLayer.frame(height: BarMetrics.height)
        }
        // Controls report their frames here for the tooltip, which is laid
        // out over the bar - including the area pill's, beyond its end.
        .coordinateSpace(.named(BarCoordinateSpace.bar))
        // Satellite windows anchor to the bar itself, excluding the reminder.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(BarCoordinateSpace.panel))
        } action: {
            presenter.barFrameInPanel = $0
        }
    }

    private var controlRow: some View {
        HStack(spacing: 0) {
            // The controls fill the bar edge to edge, so the background never
            // shows to drag by; the grip is somewhere to take hold of it.
            BarDragHandle()

            Group {
                switch presenter.mode {
                case .picker:
                    RecordingPickerControls()
                case .recording:
                    RecordingSessionControls()
                }
            }
            // The outgoing controls leave instantly so the bar starts
            // narrowing immediately; a fading-out set would hold its layout
            // width and the bar would visibly bulge to fit both before
            // collapsing.
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
        .padding(.leading, 2)
        .padding(.trailing, BarMetrics.horizontalPadding)
        .frame(height: BarMetrics.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var visibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text("Screendrop windows will be captured")
                .foregroundStyle(BarMetrics.activeTint)
            Spacer(minLength: 8)
            InspectorToggle("Include Screendrop windows in captures", isOn: $includeAppWindowsInCaptures)
                .accessibilityHint("Turn off to hide Screendrop windows from screenshots and recordings")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.top, BarMetrics.visibilityBannerOverlap)
        .frame(maxWidth: .infinity)
        .frame(height: BarMetrics.visibilityBannerHeight)
        .glassEffect(.regular, in: visibilityBannerShape)
        .overlay {
            visibilityBannerShape
                .strokeBorder(BarMetrics.edge, lineWidth: 0.5)
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(BarCoordinateSpace.panel))
        } action: {
            presenter.visibilityBannerFrameInPanel = $0
        }
    }

    private var visibilityBannerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 12,
            bottomTrailingRadius: 12,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    /// Positioned off the hovered control's measured frame rather than a
    /// hardcoded index, so it keeps tracking when the bar's contents change -
    /// a mode swap, or the display picker becoming a menu on a second monitor.
    private var tooltipLayer: some View {
        GeometryReader { _ in
            if let target = tooltip.visible {
                BarTooltipPill(text: target.text)
                    .position(
                        x: target.frame.midX,
                        y: -(BarTooltip.gap + BarTooltip.pillHeight / 2)
                    )
            }
        }
        .allowsHitTesting(false)
        // Keyed on the id as well as the text so sliding the pointer along
        // the bar glides the pill from control to control rather than
        // cross-fading it in place.
        .animation(.easeOut(duration: 0.12), value: tooltip.visible?.id)
        .animation(.easeOut(duration: 0.12), value: tooltip.visible?.text)
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: showsTeleprompter ? BarMetrics.expandedCornerRadius : BarMetrics.cornerRadius,
            style: .continuous
        )
    }
}
