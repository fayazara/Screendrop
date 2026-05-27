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
        Form {
            CaptureHotkeySettingsSection(actions: [.fullscreen, .window, .area])

            Section("After Capture") {
                Toggle(isOn: $autoSave) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto save captures")
                        Text("Automatically save screenshots to the export folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $autoCopy) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy to clipboard")
                        Text("Automatically copy the captured image to your clipboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

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
