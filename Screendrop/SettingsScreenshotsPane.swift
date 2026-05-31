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
        Form {
            CaptureHotkeySettingsSection(actions: [.fullscreen, .window, .area])

            Section("Capture") {
                Picker(selection: $captureDelaySeconds) {
                    ForEach(delayOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Self-timer")
                        Text("Show a countdown before the capture is taken.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $captureWindowShadow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capture window shadow")
                        Text("Include the window's drop shadow when capturing a window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
