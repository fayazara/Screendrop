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
    @AppStorage(ScreendropPreferences.previewSizeKey) private var previewSizeRaw = PreviewOverlaySize.defaultSize.rawValue
    @AppStorage(ScreendropPreferences.previewAutoCloseSecondsKey) private var autoCloseSeconds = 0
    @AppStorage(ScreendropPreferences.previewCloseAfterDraggingKey) private var closeAfterDragging = true

    private let autoCloseOptions: [Int] = [0, 5, 10, 30, 60]

    private var previewSize: PreviewOverlaySize {
        PreviewOverlaySize(rawValue: previewSizeRaw) ?? .defaultSize
    }

    /// Bridges the stored raw value to the slider's discrete steps.
    private var previewSizeStep: Binding<Double> {
        let sizes = PreviewOverlaySize.allCases
        return Binding(
            get: { Double(sizes.firstIndex(of: previewSize) ?? 0) },
            set: { previewSizeRaw = sizes[Int($0.rounded())].rawValue }
        )
    }

    var body: some View {
        SettingsPage {
            Section("Capture Cards") {
                Picker(selection: $previewPositionRaw) {
                    ForEach(PreviewOverlayPosition.allCases) { position in
                        Text(position.title).tag(position.rawValue)
                    }
                } label: {
                    SettingsControlLabel(
                        "Screen edge",
                        detail: "The edge capture cards dock to after a screenshot or recording. Tucked away, they leave a handle there."
                    )
                }

                LabeledContent {
                    Slider(
                        value: previewSizeStep,
                        in: 0...Double(PreviewOverlaySize.allCases.count - 1),
                        step: 1
                    )
                    .frame(width: 180)
                    .accessibilityLabel("Card size")
                    .accessibilityValue(Double(previewSize.cardScale).formatted(.percent))
                } label: {
                    SettingsControlLabel(
                        "Card size",
                        detail: "How large capture cards appear on the shelf."
                    )
                }

                Picker(selection: $autoCloseSeconds) {
                    ForEach(autoCloseOptions, id: \.self) { seconds in
                        Text(seconds == 0 ? "Never" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    SettingsControlLabel(
                        "Auto-close",
                        detail: "Dismiss a card after this delay, unless you're using it."
                    )
                }

                Toggle(isOn: $closeAfterDragging) {
                    SettingsControlLabel(
                        "Close after dragging",
                        detail: "Dismiss a card once you drag it out to another app."
                    )
                }
                .toggleStyle(.ink)
            }

            Section("Card Actions") {
                OverlayCardEditor()
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
