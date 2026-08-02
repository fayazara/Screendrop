//
//  RecordingPickerBar.swift
//  Screendrop
//
//  The pre-record mode of the floating bar. "Record" anywhere in the app
//  brings the bar up at the bottom of the active screen; it picks the source
//  (display / window / area) and toggles the capture inputs (camera,
//  microphone, system audio) for the next recording, then hands off to
//  CaptureCoordinator — at which point the same bar morphs into the in-session
//  controls (RecordingControlPresenter). Clicks and keystrokes are always
//  logged to the session sidecar; whether they appear is decided later in
//  Studio.
//
//  The panel, the chrome and the morph live in RecordingBarPresenter.
//

import AppKit
import ScreenCaptureKit
import SwiftUI

/// Retained as the entry point callers already use; the bar itself is owned
/// by RecordingBarPresenter.
@MainActor
enum RecordingPickerPresenter {
    static var shared: RecordingBarPresenter { RecordingBarPresenter.shared }
}

extension RecordingBarPresenter {
    func toggle() {
        togglePicker()
    }

    func show() {
        showPicker()
    }
}

// MARK: - Controls

struct RecordingPickerControls: View {
    let tooltip: BarTooltipModel

    @State private var sources = RecordingSourceCatalog.shared
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(ScreendropPreferences.recordingSystemAudioKey) private var systemAudio = false
    @AppStorage(ScreendropPreferences.recordingStartDelaySecondsKey) private var startDelaySeconds = 0
    @AppStorage(ScreendropPreferences.recordingTeleprompterEnabledKey) private var teleprompterEnabled = false

    private static let timerOptions = [0, 1, 3, 5]

    var body: some View {
        HStack(spacing: BarMetrics.itemSpacing) {
            displaySource
            windowSource
            BarActionButton(
                id: .area,
                title: "Area",
                systemImage: "rectangle.dashed",
                tooltip: "Drag to select a region",
                accessibility: "Area — drag to select the region to record",
                model: tooltip
            ) {
                startAreaRecording()
            }

            BarDivider()

            inputToggle(
                id: .camera,
                title: "Camera",
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
                title: "System",
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
                title: "Script",
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

            BarActionButton(
                id: .close,
                title: "Close",
                systemImage: "xmark",
                tooltip: "Close",
                accessibility: "Close the recorder — Esc",
                model: tooltip
            ) {
                dismissPicker()
            }
        }
        .task {
            await sources.refresh()
        }
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
                BarActionLabel(title: "Display", systemImage: "menubar.rectangle")
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
            BarActionButton(
                id: .display,
                title: "Display",
                systemImage: "menubar.rectangle",
                tooltip: "Record the whole screen",
                accessibility: "Display — record the whole screen",
                model: tooltip
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
            BarActionLabel(title: "Window", systemImage: "macwindow")
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
        // Area is the one source that can't morph: the bar has to get out of
        // the way of the selection overlay, so it leaves and comes back as the
        // session controls.
        RecordingBarPresenter.shared.hide()
        CaptureCoordinator.shared.recordArea(display)
    }

    /// Leaves the bar on screen: it stays as the picker through any start
    /// delay, then morphs into the session controls the moment capture
    /// actually begins. The warm camera preview (if any) is left running so it
    /// flows straight into the recording instead of restarting and refading.
    private func startRecording(_ start: () -> Void) {
        TeleprompterComposerPresenter.shared.hide()
        start()
    }

    /// Backs out of the picker without recording: stop any warm camera
    /// preview so it doesn't keep running in the background.
    private func dismissPicker() {
        RecordingBarPresenter.shared.hide()
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
            BarActionLabel(
                title: "Mic",
                systemImage: microphoneID.isEmpty ? "mic.slash" : "mic.fill",
                tint: microphoneID.isEmpty ? BarMetrics.inactiveTint : .white
            )
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
            BarActionLabel(
                title: "Timer",
                systemImage: "timer",
                tint: startDelaySeconds == 0 ? BarMetrics.inactiveTint : .white
            )
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

    /// An input toggle is the same control as a source button — the "off"
    /// state is carried by dimming the tint, not by shrinking the target.
    private func inputToggle(
        id: BarTooltipID,
        title: String,
        isOn: Bool,
        onIcon: String,
        offIcon: String,
        tooltip text: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        BarActionButton(
            id: id,
            title: title,
            systemImage: isOn ? onIcon : offIcon,
            tint: isOn ? .white : BarMetrics.inactiveTint,
            tooltip: text,
            accessibility: accessibility,
            model: tooltip,
            action: action
        )
    }
}
