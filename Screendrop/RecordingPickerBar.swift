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
    }

    func hide() {
        panel?.orderOut(nil)
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
        // AppKit window shadow follows the bar's rounded alpha shape and,
        // unlike a SwiftUI .shadow, can't be clipped by the panel bounds.
        panel.hasShadow = true
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
            y: visibleFrame.minY + 48
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
    }
}

private final class RecordingPickerHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

// MARK: - Bar

private struct RecordingPickerView: View {
    @State private var sources = RecordingSourceCatalog.shared
    @AppStorage(ScreendropPreferences.recordingCameraDeviceIDKey) private var cameraID = ""
    @AppStorage(ScreendropPreferences.recordingMicrophoneDeviceIDKey) private var microphoneID = ""
    @AppStorage(ScreendropPreferences.recordingSystemAudioKey) private var systemAudio = false

    var body: some View {
        HStack(spacing: 6) {
            iconButton(systemImage: "xmark", help: "Close") {
                RecordingPickerPresenter.shared.hide()
            }

            barDivider

            displaySource
            windowSource
            sourceButton(title: "Area", systemImage: "rectangle.dashed") {
                startAreaRecording()
            }

            barDivider

            inputToggle(
                isOn: !cameraID.isEmpty,
                onIcon: "video.fill",
                offIcon: "video.slash",
                help: cameraID.isEmpty ? "Camera off — click to record camera" : "Camera on"
            ) {
                toggleCamera()
            }
            .contextMenu {
                cameraDeviceMenu
            }

            microphonePicker

            inputToggle(
                isOn: systemAudio,
                onIcon: "speaker.wave.2.fill",
                offIcon: "speaker.slash",
                help: systemAudio ? "System audio on" : "System audio off"
            ) {
                systemAudio.toggle()
            }

            barDivider

            iconButton(systemImage: "gearshape.fill", help: "Recording settings") {
                RecordingPickerPresenter.shared.hide()
                SettingsWindowController.show(tab: .video)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 66)
        .background(Color(white: 0.14).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
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
                sourceLabel(title: "Display", systemImage: "display")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } else {
            sourceButton(title: "Display", systemImage: "display") {
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
        RecordingPickerPresenter.shared.hide()
        start()
    }

    // MARK: Input toggles

    private func toggleCamera() {
        if cameraID.isEmpty {
            selectCamera(RecordingDeviceCatalog.cameras().first?.uniqueID)
        } else {
            cameraID = ""
        }
    }

    private var microphoneHelp: String {
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
        .help(microphoneHelp)
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
            cameraID = await RecordingInputAuthorization.ensureAccess(for: .camera) ? deviceID : ""
        }
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
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            sourceLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }

    private func inputToggle(
        isOn: Bool,
        onIcon: String,
        offIcon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: isOn ? onIcon : offIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.35))
                .frame(width: 34, height: 34)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
