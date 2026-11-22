import AppKit
import SwiftUI

struct VideoSettingsPane: View {
    @AppStorage(ScreendropPreferences.revealExportInFinderKey) private var revealExportInFinder = true

    var body: some View {
        SettingsPage {
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
                SettingsRow {
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

    private let autoCloseOptions: [Int] = [0, 5, 10, 30, 60]

    var body: some View {
        SettingsPage {
            Section("Capture Cards") {
                VStack(alignment: .leading, spacing: Space.l) {
                    SettingsControlLabel(
                        "Screen edge",
                        detail: "The edge capture cards dock to after a screenshot or recording. Tucked away, they leave a handle there."
                    )

                    HStack(spacing: Space.xl) {
                        ForEach(PreviewOverlayPosition.allCases) { position in
                            SettingsVisualChoice(
                                title: position.title,
                                isSelected: previewPositionRaw == position.rawValue
                            ) {
                                previewPositionRaw = position.rawValue
                            } picture: {
                                ScreenEdgePicture(position: position)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, Space.xs)

                SettingsRow {
                    SettingsSegmented(
                        options: autoCloseOptions,
                        selection: $autoCloseSeconds,
                        title: { $0 == 0 ? "Never" : $0 == 60 ? "1 min" : "\($0)s" }
                    )
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

/// A desktop with capture cards stacked in one bottom corner, as the shelf
/// places them: inset from the side and the bottom, newest at the bottom.
/// Scaled up from `CaptureShelfMetrics` so the cards read at this size.
private struct ScreenEdgePicture: View {
    let position: PreviewOverlayPosition

    var body: some View {
        SettingsMiniDesktop {
            VStack(spacing: 3) {
                card(opacity: 0.75)
                card(opacity: 1)
            }
            .padding(.bottom, 5)
            .padding(position == .left ? .leading : .trailing, 5)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: position == .left ? .bottomLeading : .bottomTrailing
            )
        }
    }

    /// A capture card: white, with a hairline edge to sit on the pale
    /// wallpaper and a gray block for its screenshot.
    private func card(opacity: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return shape
            .fill(.white)
            .overlay {
                // Nested: the card's radius less the inset.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: 0.82, green: 0.86, blue: 0.93))
                    .padding(2)
            }
            .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .opacity(opacity)
            .frame(width: 30, height: 21)
    }
}
