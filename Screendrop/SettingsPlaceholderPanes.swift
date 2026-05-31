import AppKit
import SwiftUI

struct VideoSettingsPane: View {
    @AppStorage(ScreendropPreferences.showRecordingMouseIndicatorsKey) private var showMouseIndicators = true
    @AppStorage(ScreendropPreferences.showRecordingKeyPressCaptionsKey) private var showKeyPressCaptions = false
    @AppStorage(ScreendropPreferences.recordingMouseIndicatorColorKey) private var mouseIndicatorColor = ScreendropPreferences.defaultRecordingMouseIndicatorColor
    @AppStorage(ScreendropPreferences.recordingMouseIndicatorSizeKey) private var mouseIndicatorSize = ScreendropPreferences.defaultRecordingMouseIndicatorSize

    private var indicatorColor: Binding<Color> {
        Binding(
            get: {
                Color(nsColor: NSColor(hexString: mouseIndicatorColor) ?? .systemBlue)
            },
            set: { color in
                if let hexString = NSColor(color).hexRGBString {
                    mouseIndicatorColor = hexString
                }
            }
        )
    }

    var body: some View {
        Form {
            CaptureHotkeySettingsSection(actions: [.screenRecording])

            AfterCaptureActionsSection(type: .recording, title: "After Recording")

            Section("Recording Indicators") {
                Toggle(isOn: $showMouseIndicators) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show mouse clicks and drags")
                        Text("Displays a visual indicator when you click or drag during recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $showKeyPressCaptions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show key press captions")
                        Text("Displays pressed keys as on-screen captions while recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("Indicator Appearance") {
                LabeledContent("Color") {
                    ColorPicker("", selection: indicatorColor, supportsOpacity: false)
                        .labelsHidden()
                }

                LabeledContent("Size") {
                    HStack(spacing: 12) {
                        Slider(value: $mouseIndicatorSize, in: 24...96, step: 2)
                            .frame(width: 180)

                        Text("\(Int(mouseIndicatorSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
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
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6,
              let integer = Int(value, radix: 16) else {
            return nil
        }

        self.init(
            srgbRed: CGFloat((integer >> 16) & 0xFF) / 255,
            green: CGFloat((integer >> 8) & 0xFF) / 255,
            blue: CGFloat(integer & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexRGBString: String? {
        guard let color = usingColorSpace(.sRGB) else { return nil }

        let red = Int(round(color.redComponent * 255))
        let green = Int(round(color.greenComponent * 255))
        let blue = Int(round(color.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
