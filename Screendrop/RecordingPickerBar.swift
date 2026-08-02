//
//  RecordingPickerBar.swift
//  Screendrop
//
//  The pre-record floating bar. "Record" anywhere in the app opens this
//  panel at the bottom of the active screen; it picks the source (display /
//  window / area) and toggles the capture inputs (camera, microphone,
//  system audio) for the next recording, then hands off to
//  CaptureCoordinator. Clicks and keystrokes are always logged to the
//  session sidecar; whether they appear is decided later in Studio.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class RecordingPickerPresenter {
    static let shared = RecordingPickerPresenter()

    private var panel: NSPanel?

    private init() {}

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        Task {
            await RecordingSourceCatalog.shared.refresh()
        }
        positionPanel(panel)
        panel.orderFrontRegardless()
        warmCameraPreviewIfEnabled()
    }

    func hide() {
        panel?.orderOut(nil)
        // The composer only makes sense floating above the bar.
        TeleprompterComposerPresenter.shared.hide()
    }

    /// Where the bar currently sits, so satellite windows (the teleprompter
    /// composer) can anchor to it even after the user drags it around. This
    /// is the visible bar, not the panel: the panel is padded out with
    /// transparent slack for the tooltips, and anchoring to that would leave
    /// satellites floating a tooltip's height clear of the bar.
    var barFrame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return CGRect(
            x: panel.frame.minX + BarTooltip.reservedWidth,
            y: panel.frame.minY + BarMetrics.shadowSlack,
            width: panel.frame.width - BarTooltip.reservedWidth * 2,
            height: BarMetrics.height
        )
    }

    /// The bar's hosting view is created once and just reordered in/out on
    /// every `show()`/`hide()`, so its SwiftUI `.task` never reruns after the
    /// first appearance. Reading the camera preference here — on every real
    /// `show()` — is what makes a camera left on from a previous session
    /// warm up immediately instead of needing an off/on toggle to kick it.
    private func warmCameraPreviewIfEnabled() {
        let cameraID = ScreendropPreferences.recordingCameraDeviceID
        guard !cameraID.isEmpty else { return }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        Task {
            await CameraRecordingManager.shared.startPreview(deviceID: cameraID, displayID: displayID)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = RecordingPickerPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Shadows are drawn in SwiftUI, not by AppKit. The window shadow is
        // derived from the window's alpha silhouette and recomputed lazily,
        // so anything that fades in or out inside the panel — the tooltip —
        // leaves its shadow outline hanging for a frame or two after the fill
        // has gone. The panel reserves slack on all four sides (see
        // BarMetrics) so SwiftUI's shadows aren't clipped by the panel edge,
        // which was the original reason for using the AppKit one.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        let hostingView = RecordingPickerHostingView(rootView: RecordingPickerView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.isOpaque = false

        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = panel.frame.size
        let origin = CGPoint(
            x: visibleFrame.midX - size.width / 2,
            // Dropped by the bottom slack so the bar — not the panel — lands
            // 48pt above the visible frame.
            y: visibleFrame.minY + 48 - BarMetrics.shadowSlack
        )
        panel.setFrameOrigin(origin)
    }
}

private final class RecordingPickerPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func cancelOperation(_ sender: Any?) {
        RecordingPickerPresenter.shared.hide()
        Task { await CameraRecordingManager.shared.stopPreview() }
    }
}

private final class RecordingPickerHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }

    /// The panel is padded out with transparent slack on three sides so the
    /// tooltip — which draws outside the bar — isn't clipped at the window
    /// edge. AppKit hit-tests by view bounds, not alpha, so without this the
    /// slack would silently swallow clicks meant for whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard barRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// The bar sits one slack's height up from the bottom edge of the padded
    /// content. `NSHostingView` is flipped, so "bottom" is `maxY` here —
    /// reading it off `bounds` keeps this correct either way.
    private var barRect: NSRect {
        let bottomInset = BarMetrics.shadowSlack
        return NSRect(
            x: BarTooltip.reservedWidth,
            y: isFlipped
                ? bounds.maxY - bottomInset - BarMetrics.height
                : bounds.minY + bottomInset,
            width: bounds.width - BarTooltip.reservedWidth * 2,
            height: BarMetrics.height
        )
    }
}

private enum BarMetrics {
    static let height: CGFloat = 66
    /// Transparent slack below the bar so its own drop shadow isn't clipped
    /// by the panel edge. The panel is positioned lower by exactly this much
    /// so the bar itself doesn't move.
    static let shadowSlack: CGFloat = 28
}

// MARK: - Tooltips

/// Geometry and timing for the bar's own tooltips. macOS' native `.help()`
/// tooltip takes about a second to appear, which is far too slow for a bar
/// you're meant to scan and dismiss; these show in a fraction of that and,
/// once one has appeared, follow the pointer across the bar instantly.
private enum BarTooltip {
    static let coordinateSpace = "recordingPickerBar"
    static let pillHeight: CGFloat = 24
    /// Space between the top of the bar and the bottom of the pill.
    static let gap: CGFloat = 8
    /// Transparent slack the panel reserves above the bar for the pill and
    /// its shadow.
    static let reservedHeight: CGFloat = gap + pillHeight + 16
    /// Transparent slack at each end, so a pill centred on an edge control
    /// isn't cut off by the panel.
    static let reservedWidth: CGFloat = 72

    static let showDelay = Duration.milliseconds(160)
    /// How long after leaving a control the bar stays "warm" — hover another
    /// control inside this window and its tooltip appears with no delay.
    static let warmWindow = Duration.milliseconds(500)
}

/// Stable identity per control, so a tooltip can be re-texted in place when
/// the control it describes changes state under the pointer.
private enum BarTooltipID: String {
    case display
    case window
    case area
    case camera
    case microphone
    case systemAudio
    case teleprompter
    case timer
    case close
}

private struct BarTooltipTarget {
    var id: BarTooltipID
    var text: String
    var frame: CGRect
}

@Observable
private final class BarTooltipModel {
    private(set) var visible: BarTooltipTarget?

    private var hovered: BarTooltipID?
    private var isWarm = false
    private var showTask: Task<Void, Never>?
    private var coolTask: Task<Void, Never>?

    func hover(id: BarTooltipID, text: String, frame: CGRect) {
        hovered = id
        showTask?.cancel()
        coolTask?.cancel()

        guard !isWarm else {
            visible = BarTooltipTarget(id: id, text: text, frame: frame)
            return
        }
        showTask = Task {
            try? await Task.sleep(for: BarTooltip.showDelay)
            guard !Task.isCancelled, hovered == id else { return }
            visible = BarTooltipTarget(id: id, text: text, frame: frame)
            isWarm = true
        }
    }

    /// Guarded on the item that's leaving: SwiftUI can deliver the new
    /// control's `onHover(true)` before the old one's `onHover(false)`, and
    /// an unguarded hide would blank the tooltip that just took over.
    func endHover(id: BarTooltipID) {
        guard hovered == id else { return }
        hovered = nil
        showTask?.cancel()
        visible = nil
        coolTask = Task {
            try? await Task.sleep(for: BarTooltip.warmWindow)
            guard !Task.isCancelled, hovered == nil else { return }
            isWarm = false
        }
    }

    /// Clicking a control means the user is done reading about it. Cut
    /// without a fade: the click already happened, and a pill dissolving
    /// after the fact reads as lag.
    func dismiss() {
        hovered = nil
        showTask?.cancel()
        withTransaction(Transaction(animation: nil)) {
            visible = nil
        }
    }
}

private struct BarTooltipPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .frame(height: BarTooltip.pillHeight)
            .background(Color(white: 0.16).opacity(0.98))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            // Fainter than the bar's own 0.14 border: at pill scale that
            // weight reads as a hard outline rather than an edge highlight.
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .transition(.opacity)
    }
}

private struct BarTooltipModifier: ViewModifier {
    let id: BarTooltipID
    let text: String
    let accessibility: String
    let model: BarTooltipModel

    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(BarTooltip.coordinateSpace))
            } action: {
                frame = $0
            }
            .onHover { isInside in
                if isInside {
                    model.hover(id: id, text: text, frame: frame)
                } else {
                    model.endHover(id: id)
                }
            }
            .accessibilityLabel(accessibility)
    }
}

extension View {
    /// `text` is what the pill shows — keep it short. `accessibility` carries
    /// the longer description for VoiceOver, where length costs nothing.
    fileprivate func barTooltip(
        _ id: BarTooltipID,
        _ text: String,
        accessibility: String? = nil,
        model: BarTooltipModel
    ) -> some View {
        modifier(
            BarTooltipModifier(
                id: id,
                text: text,
                accessibility: accessibility ?? text,
                model: model
            )
        )
    }
}

// MARK: - Bar

private struct RecordingPickerView: View {
    @State private var sources = RecordingSourceCatalog.shared
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(ScreendropPreferences.recordingSystemAudioKey) private var systemAudio = false
    @AppStorage(ScreendropPreferences.recordingStartDelaySecondsKey) private var startDelaySeconds = 0
    @AppStorage(ScreendropPreferences.recordingTeleprompterEnabledKey) private var teleprompterEnabled = false

    @State private var tooltip = BarTooltipModel()

    private static let timerOptions = [0, 1, 3, 5]

    var body: some View {
        HStack(spacing: 6) {
            displaySource
            windowSource
            sourceButton(
                id: .area,
                title: "Area",
                systemImage: "rectangle.dashed",
                tooltip: "Drag to select a region",
                accessibility: "Area — drag to select the region to record"
            ) {
                startAreaRecording()
            }

            barDivider

            inputToggle(
                id: .camera,
                isOn: !cameraID.isEmpty,
                onIcon: "video.fill",
                offIcon: "video.slash",
                tooltip: cameraID.isEmpty ? "Camera off" : "Camera on",
                accessibility: cameraAccessibilityLabel
            ) {
                toggleCamera()
            }
            .contextMenu {
                cameraDeviceMenu
            }

            microphonePicker

            inputToggle(
                id: .systemAudio,
                isOn: systemAudio,
                onIcon: "speaker.wave.2.fill",
                offIcon: "speaker.slash",
                tooltip: systemAudio ? "System audio on" : "System audio off",
                accessibility: systemAudio
                    ? "System audio on — click to stop capturing what you hear"
                    : "System audio off — click to capture what you hear"
            ) {
                systemAudio.toggle()
            }

            inputToggle(
                id: .teleprompter,
                isOn: teleprompterEnabled,
                onIcon: "text.line.first.and.arrowtriangle.forward",
                offIcon: "text.line.first.and.arrowtriangle.forward",
                tooltip: teleprompterEnabled ? "Teleprompter on" : "Teleprompter off",
                accessibility: teleprompterEnabled
                    ? "Teleprompter on — click to edit the script"
                    : "Teleprompter off — click to write a script"
            ) {
                TeleprompterComposerPresenter.shared.toggle()
            }

            timerMenu

            iconButton(
                id: .close,
                systemImage: "xmark",
                tooltip: "Close",
                accessibility: "Close the recorder — Esc"
            ) {
                dismissPicker()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: BarMetrics.height)
        .background(Color(white: 0.14).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 5)
        .coordinateSpace(.named(BarTooltip.coordinateSpace))
        .overlay(tooltipLayer)
        // Transparent slack around the bar so the tooltip and the shadows —
        // both of which draw outside the bar's bounds — aren't clipped by the
        // panel edge.
        .padding(.top, BarTooltip.reservedHeight)
        .padding(.bottom, BarMetrics.shadowSlack)
        .padding(.horizontal, BarTooltip.reservedWidth)
        .preferredColorScheme(.dark)
        .task {
            await sources.refresh()
        }
    }

    /// Positioned off the hovered control's measured frame rather than a
    /// hardcoded index, so it keeps tracking when the bar's contents change —
    /// e.g. the display picker swapping between button and menu on a second
    /// monitor.
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

    // MARK: Sources

    @ViewBuilder
    private var displaySource: some View {
        if sources.displays.count > 1 {
            Menu {
                ForEach(Array(sources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        startRecording {
                            CaptureCoordinator.shared.recordFullscreen(display)
                        }
                    }
                }
            } label: {
                sourceLabel(title: "Display", systemImage: "menubar.rectangle")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .barTooltip(
                .display,
                "Pick a screen to record",
                accessibility: "Display — choose which screen to record",
                model: tooltip
            )
        } else {
            sourceButton(
                id: .display,
                title: "Display",
                systemImage: "menubar.rectangle",
                tooltip: "Record the whole screen",
                accessibility: "Display — record the whole screen"
            ) {
                guard let display = sources.displays.first else { return }
                startRecording {
                    CaptureCoordinator.shared.recordFullscreen(display)
                }
            }
        }
    }

    private var windowSource: some View {
        Menu {
            if sources.windows.isEmpty {
                Text("No app windows found")
            }
            ForEach(sources.windows, id: \.windowID) { window in
                Button(RecordingSourceCatalog.windowTitle(window)) {
                    startRecording {
                        CaptureCoordinator.shared.recordWindow(window)
                    }
                }
            }

            Divider()

            Button("Refresh Windows") {
                Task {
                    await sources.refresh()
                }
            }
        } label: {
            sourceLabel(title: "Window", systemImage: "macwindow")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .barTooltip(
            .window,
            "Pick an app window",
            accessibility: "Window — choose an app window to record",
            model: tooltip
        )
    }

    private func startAreaRecording() {
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        guard let display = sources.displays.first(where: { $0.displayID == displayID })
            ?? sources.displays.first else { return }
        startRecording {
            CaptureCoordinator.shared.recordArea(display)
        }
    }

    private func startRecording(_ start: () -> Void) {
        // Only hides the bar — the warm camera preview (if any) is left
        // running so it flows straight into the actual recording instead of
        // restarting the session and refading.
        RecordingPickerPresenter.shared.hide()
        start()
    }

    /// Backs out of the picker without recording: stop any warm camera
    /// preview so it doesn't keep running in the background.
    private func dismissPicker() {
        RecordingPickerPresenter.shared.hide()
        Task { await CameraRecordingManager.shared.stopPreview() }
    }

    // MARK: Input toggles

    private func toggleCamera() {
        if cameraID.isEmpty {
            selectCamera(RecordingDeviceCatalog.cameras().first?.uniqueID)
        } else {
            cameraID = ""
            Task { await CameraRecordingManager.shared.stopPreview() }
        }
    }

    private var cameraAccessibilityLabel: String {
        guard !cameraID.isEmpty else {
            return "Camera off — click to record your camera, right-click to pick one"
        }
        guard let camera = RecordingDeviceCatalog.cameras().first(where: { $0.uniqueID == cameraID }) else {
            return "Camera unavailable — right-click to choose another camera"
        }
        return "Camera on — \(camera.localizedName), right-click to switch"
    }

    /// The pill only has room for the state, so an attached-but-missing
    /// device is worth calling out there — it's the one case where the icon
    /// alone is misleading.
    private var microphoneTooltip: String {
        guard !microphoneID.isEmpty else { return "Microphone off" }
        guard RecordingDeviceCatalog.microphone(withID: microphoneID) != nil else {
            return "Microphone unavailable"
        }
        return "Microphone on"
    }

    private var microphoneAccessibilityLabel: String {
        guard !microphoneID.isEmpty else {
            return "Microphone off — click to choose an input"
        }
        guard let microphone = RecordingDeviceCatalog.microphone(withID: microphoneID) else {
            return "Microphone unavailable — choose another input"
        }
        return "Microphone on — \(microphone.localizedName)"
    }

    @ViewBuilder
    private var cameraDeviceMenu: some View {
        ForEach(RecordingDeviceCatalog.cameras(), id: \.uniqueID) { device in
            Toggle(isOn: Binding(
                get: { cameraID == device.uniqueID },
                set: { selected in
                    if selected {
                        selectCamera(device.uniqueID)
                    } else {
                        cameraID = ""
                        Task { await CameraRecordingManager.shared.stopPreview() }
                    }
                }
            )) {
                Text(device.localizedName)
            }
        }
    }

    private var microphonePicker: some View {
        Menu {
            Button {
                microphoneID = ""
            } label: {
                menuSelectionLabel("Off", isSelected: microphoneID.isEmpty)
            }

            Divider()

            ForEach(RecordingDeviceCatalog.microphones(), id: \.uniqueID) { device in
                Button {
                    selectMicrophone(device.uniqueID)
                } label: {
                    menuSelectionLabel(
                        device.localizedName,
                        isSelected: microphoneID == device.uniqueID
                    )
                }
            }
        } label: {
            Image(systemName: microphoneID.isEmpty ? "mic.slash" : "mic.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(microphoneID.isEmpty ? Color.white.opacity(0.35) : Color.white)
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .barTooltip(
            .microphone,
            microphoneTooltip,
            accessibility: microphoneAccessibilityLabel,
            model: tooltip
        )
    }

    /// Replaces the old gear button that opened Settings: a self-contained
    /// menu for options that only matter for the next recording, starting
    /// with a start-delay timer.
    private var timerMenu: some View {
        Menu {
            ForEach(Self.timerOptions, id: \.self) { seconds in
                Button {
                    startDelaySeconds = seconds
                } label: {
                    menuSelectionLabel(timerLabel(seconds), isSelected: startDelaySeconds == seconds)
                }
            }
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(startDelaySeconds == 0 ? Color.white.opacity(0.35) : Color.white)
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .barTooltip(
            .timer,
            timerTooltip,
            accessibility: timerAccessibilityLabel,
            model: tooltip
        )
    }

    private func timerLabel(_ seconds: Int) -> String {
        seconds == 0 ? "None" : "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    private var timerTooltip: String {
        startDelaySeconds == 0 ? "Timer off" : "Timer \(startDelaySeconds)s"
    }

    private var timerAccessibilityLabel: String {
        startDelaySeconds == 0
            ? "Timer off — click to add a countdown before recording starts"
            : "Timer: \(timerLabel(startDelaySeconds)) before recording starts"
    }

    @ViewBuilder
    private func menuSelectionLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func selectCamera(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            let authorized = await RecordingInputAuthorization.ensureAccess(for: .camera)
            cameraID = authorized ? deviceID : ""
            if authorized {
                await warmCameraPreview()
            }
        }
    }

    /// Starts the camera session (and its floating preview) ahead of "Start
    /// Recording", so its exposure/white-balance ramp — the fade-in macOS
    /// shows whenever a capture session starts cold — finishes before
    /// anything is actually being recorded.
    private func warmCameraPreview() async {
        guard !cameraID.isEmpty else { return }
        let displayID = ActiveDisplayResolver.activeDisplayID(preferPointer: false)
        await CameraRecordingManager.shared.startPreview(deviceID: cameraID, displayID: displayID)
    }

    private func selectMicrophone(_ deviceID: String?) {
        guard let deviceID else { return }
        Task { @MainActor in
            microphoneID = await RecordingInputAuthorization.ensureAccess(for: .microphone) ? deviceID : ""
        }
    }

    // MARK: Pieces

    private var barDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 34)
            .padding(.horizontal, 4)
    }

    private func sourceLabel(title: String, systemImage: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(height: 22)
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(width: 56, height: 46)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sourceButton(
        id: BarTooltipID,
        title: String,
        systemImage: String,
        tooltip text: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tooltip.dismiss()
            action()
        } label: {
            sourceLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .barTooltip(id, text, accessibility: accessibility, model: tooltip)
    }

    private func inputToggle(
        id: BarTooltipID,
        isOn: Bool,
        onIcon: String,
        offIcon: String,
        tooltip text: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tooltip.dismiss()
            action()
        } label: {
            Image(systemName: isOn ? onIcon : offIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.35))
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .barTooltip(id, text, accessibility: accessibility, model: tooltip)
    }

    private func iconButton(
        id: BarTooltipID,
        systemImage: String,
        tooltip text: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            tooltip.dismiss()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .barTooltip(id, text, accessibility: accessibility, model: tooltip)
    }
}
