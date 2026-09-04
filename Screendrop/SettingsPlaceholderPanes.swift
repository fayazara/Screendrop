import AppKit
import SwiftUI

struct VideoSettingsPane: View {
    @AppStorage(ScreendropPreferences.revealExportInFinderKey) private var revealExportInFinder = true

    var body: some View {
        Form {
            CaptureHotkeySettingsSection(actions: [.screenRecording])

            AfterCaptureActionsSection(type: .recording, title: "After Recording")

            Section("After Export") {
                Toggle(isOn: $revealExportInFinder) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reveal in Finder")
                        Text("Select the exported file in Finder once the render finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Projects") {
                LabeledContent {
                    Button("Show All Projects…") {
                        RecordingProjectsWindowController.show()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording projects")
                        Text("Reopen a past recording with every edit intact.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

struct OverlaySettingsPane: View {
    @AppStorage(ScreendropPreferences.previewPositionKey) private var previewPositionRaw = PreviewOverlayPosition.right.rawValue
    @AppStorage(ScreendropPreferences.previewAutoCloseSecondsKey) private var autoCloseSeconds = 0
    @AppStorage(ScreendropPreferences.previewCloseAfterDraggingKey) private var closeAfterDragging = true
    @AppStorage(ScreendropPreferences.previewCloseAfterCopyingKey) private var closeAfterCopying = true

    private let autoCloseOptions: [Int] = [0, 5, 10, 30, 60]

    var body: some View {
        Form {
            Section("Preview Overlay") {
                Picker(selection: $previewPositionRaw) {
                    ForEach(PreviewOverlayPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Position on screen")
                        Text("Where the floating preview cards appear after a capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Picker(selection: $autoCloseSeconds) {
                    ForEach(autoCloseOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-close")
                        Text("Automatically dismiss a preview after this delay, unless you're using it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $closeAfterDragging) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Close after dragging")
                        Text("Dismiss the preview once you drag it out to another app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $closeAfterCopying) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Close after Ctrl+C")
                        Text("Copy and dismiss the focused preview when you press Ctrl+C.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("Card Actions") {
                OverlayCardEditor()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
