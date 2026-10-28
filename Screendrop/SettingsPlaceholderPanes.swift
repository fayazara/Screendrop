import AppKit
import SwiftUI

struct VideoSettingsPane: View {
    @AppStorage(ScreendropPreferences.revealExportInFinderKey) private var revealExportInFinder = true

    var body: some View {
        SettingsPage {
            CaptureHotkeySettingsSection(actions: [.screenRecording])

            AfterCaptureActionsSection(type: .recording, title: "After Recording")

            Section("After Export") {
                Toggle(isOn: $revealExportInFinder) {
                    SettingsControlLabel(
                        "Reveal in Finder",
                        detail: "Select the exported file in Finder once the render finishes."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Projects") {
                LabeledContent {
                    SettingsButton("Open Library", systemImage: "square.grid.2x2") {
                        CaptureLibraryModel.shared.show(filter: .recordings)
                    }
                } label: {
                    SettingsControlLabel(
                        "Recording projects",
                        detail: "Reopen a past recording with every edit intact."
                    )
                }
            }
        }
    }
}

struct OverlaySettingsPane: View {
    @AppStorage(ScreendropPreferences.previewPositionKey) private var previewPositionRaw = PreviewOverlayPosition.right.rawValue
    @AppStorage(ScreendropPreferences.previewAutoCloseSecondsKey) private var autoCloseSeconds = 0
    @AppStorage(ScreendropPreferences.previewCloseAfterDraggingKey) private var closeAfterDragging = true
    @AppStorage(ScreendropPreferences.confirmPinnedCloseKey) private var confirmPinnedClose = true

    private let autoCloseOptions: [Int] = [0, 5, 10, 15, 30, 60]

    var body: some View {
        SettingsPage {
            Section("Capture Cards") {
                Picker(selection: $previewPositionRaw) {
                    ForEach(PreviewOverlayPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    SettingsControlLabel(
                        "Screen corner",
                        detail: "The capture preview opens in this bottom corner."
                    )
                }

                LabeledContent {
                    SettingsButton("Reset Position", systemImage: "arrow.counterclockwise") {
                        CaptureShelfPresenter.shared.resetPlacement()
                    }
                } label: {
                    SettingsControlLabel(
                        "Preview position",
                        detail: "The preview opens in the bottom corner above. If you drag it, it stays where you leave it; Reset puts it back in that corner."
                    )
                }

                Picker(selection: $autoCloseSeconds) {
                    ForEach(autoCloseOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    SettingsControlLabel(
                        "Auto-close",
                        detail: "Dismiss the preview after this delay, unless you're using it."
                    )
                }

                Toggle(isOn: $closeAfterDragging) {
                    SettingsControlLabel(
                        "Close after dragging",
                        detail: "Dismiss the preview once you drag it out to another app."
                    )
                }
                .toggleStyle(.ink)

                Toggle(isOn: $confirmPinnedClose) {
                    SettingsControlLabel(
                        "Confirm closing pins",
                        detail: "Ask before ⌘W closes a pinned screenshot. The image file is never deleted."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Preview Controls") {
                SettingsControlLabel(
                    "Controls",
                    detail: "Hover the preview for copy, annotate, save, pin and close. Drag the picture to move the preview; drag the grip, or hold Option and drag, to drag the file into Finder, Mail or another app."
                )
            }
        }
    }
}
