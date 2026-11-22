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
    @AppStorage(ScreendropPreferences.trimFullscreenMenuBarKey) private var trimFullscreenMenuBar = true

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
            Section("Capture") {
                SettingsRow {
                    SettingsSegmented(
                        options: delayOptions,
                        selection: $captureDelaySeconds,
                        title: { $0 == 0 ? "Off" : "\($0)s" }
                    )
                } label: {
                    SettingsControlLabel(
                        "Self-timer",
                        detail: "Show a countdown before the capture is taken."
                    )
                }

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

            AfterCaptureActionsSection(type: .screenshot, title: "After Capture")

            Section("File Format") {
                SettingsRow("Format") {
                    SettingsSegmented(
                        options: ScreenshotExportFormat.allCases,
                        selection: Binding(
                            get: { exportFormat },
                            set: { exportFormat = $0 }
                        ),
                        title: \.title
                    )
                }

                if exportFormat.usesLossyQuality {
                    SettingsRow("Compression quality") {
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
