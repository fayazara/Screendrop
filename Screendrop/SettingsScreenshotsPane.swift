//
//  SettingsScreenshotsPane.swift
//  Screendrop
//

import SwiftUI

struct ScreenshotsSettingsPane: View {
    @AppStorage(ScreendropPreferences.autoCompressKey) private var autoCompress = false
    @AppStorage(ScreendropPreferences.exportFormatKey) private var exportFormatRawValue = ""
    @AppStorage(ScreendropPreferences.compressionQualityKey) private var compressionQuality = 0.8
    @AppStorage(ScreendropPreferences.captureWindowShadowKey) private var captureWindowShadow = false
    @AppStorage(ScreendropPreferences.captureDelaySecondsKey) private var captureDelaySeconds = 0
    @AppStorage(ScreendropPreferences.lowResolutionEditorPreviewKey) private var lowResolutionEditorPreview = true
    @AppStorage(ScreendropPreferences.autoNameCapturesKey) private var autoNameCaptures = false
    @AppStorage(ScreendropPreferences.trimFullscreenMenuBarKey) private var trimFullscreenMenuBar = true
    @AppStorage(ScreendropPreferences.annotationStartingToolKey) private var startingTool = AnnotationTool.select.rawValue

    private let delayOptions: [Int] = [0, 3, 5, 10]

    private var exportFormat: ScreenshotExportFormat {
        get {
            ScreenshotExportFormat(rawValue: exportFormatRawValue) ?? (autoCompress ? .jpeg : .png)
        }
        nonmutating set {
            exportFormatRawValue = newValue.rawValue
            autoCompress = newValue.usesLossyQuality
        }
    }

    var body: some View {
        SettingsPage {
            CaptureHotkeySettingsSection(actions: [.fullscreen, .window, .area, .textCapture, .scrollingCapture])

            Section("Capture") {
                Picker(selection: $captureDelaySeconds) {
                    ForEach(delayOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    SettingsControlLabel(
                        "Self-timer",
                        detail: "Show a countdown before the capture is taken."
                    )
                }

                Toggle(isOn: $autoNameCaptures) {
                    SettingsControlLabel(
                        "Name screenshots from their content",
                        detail: "Reads each capture on device and gives it a descriptive file name using Apple Intelligence. Nothing leaves your Mac; it takes a moment after the capture."
                    )
                }
                .toggleStyle(.ink)

                Toggle(isOn: $captureWindowShadow) {
                    SettingsControlLabel(
                        "Capture window shadow",
                        detail: "Include the window's drop shadow when capturing a window."
                    )
                }
                .toggleStyle(.ink)

                Toggle(isOn: $trimFullscreenMenuBar) {
                    SettingsControlLabel(
                        "Trim menu bar from fullscreen captures",
                        detail: "On notched Macs, removes the empty black bar at the top of a fullscreen capture. A visible menu bar is kept."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Annotation Editor") {
                Picker(selection: $startingTool) {
                    Text("Last Used").tag(ScreendropPreferences.startingToolLastUsed)
                    Divider()
                    ForEach(AnnotationTool.allCases) { tool in
                        Text(tool.title).tag(tool.rawValue)
                    }
                } label: {
                    SettingsControlLabel(
                        "Starting tool",
                        detail: "The tool picked when the editor opens."
                    )
                }

                Toggle(isOn: $lowResolutionEditorPreview) {
                    SettingsControlLabel(
                        "Use low-resolution preview to save memory",
                        detail: "Shows a downscaled image while editing to reduce memory use. Saved and exported screenshots are always full resolution."
                    )
                }
                .toggleStyle(.ink)
            }

            AfterCaptureActionsSection(type: .screenshot, title: "After Capture")

            Section("File Format") {
                Picker("Format", selection: Binding(
                    get: { exportFormat },
                    set: { exportFormat = $0 }
                )) {
                    ForEach(ScreenshotExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                if exportFormat.usesLossyQuality {
                    LabeledContent("Compression quality") {
                        HStack(spacing: 12) {
                            Slider(value: $compressionQuality, in: 0.1...1, step: 0.05)
                                .frame(width: 180)
                                .accessibilityLabel("Compression quality")
                                .accessibilityValue(compressionQuality.formatted(.percent.precision(.fractionLength(0))))

                            Text(compressionQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }

                    Text("Lower values produce smaller files with reduced image quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
