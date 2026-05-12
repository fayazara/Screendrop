//
//  SettingsScreenshotsPane.swift
//  Screendrop
//

import SwiftUI

struct ScreenshotsSettingsPane: View {
    @AppStorage(ScreendropPreferences.autoSaveKey) private var autoSave = false
    @AppStorage(ScreendropPreferences.autoCopyKey) private var autoCopy = false
    @AppStorage(ScreendropPreferences.autoCompressKey) private var autoCompress = false
    @AppStorage(ScreendropPreferences.exportFormatKey) private var exportFormatRawValue = ""
    @AppStorage(ScreendropPreferences.compressionQualityKey) private var compressionQuality = 0.8

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
        SettingsPane {
            SettingsSection {
                SettingsRow("After capture:") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto save captures", isOn: $autoSave)
                            .toggleStyle(.checkbox)
                        Toggle("Copy to clipboard", isOn: $autoCopy)
                            .toggleStyle(.checkbox)
                    }
                }
            }

            SettingsSectionDivider()

            SettingsSection {
                SettingsRow("File format:") {
                    Picker("", selection: Binding(
                        get: { exportFormat },
                        set: { exportFormat = $0 }
                    )) {
                        ForEach(ScreenshotExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                if exportFormat.usesLossyQuality {
                    SettingsRow("Quality:") {
                        HStack(spacing: 12) {
                            Slider(value: $compressionQuality, in: 0.1...1, step: 0.05)
                                .frame(width: 200)

                            Text(compressionQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}
