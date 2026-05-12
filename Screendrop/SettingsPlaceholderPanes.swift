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
        SettingsPane {
            SettingsSection {
                SettingsRow("Mouse indicators:") {
                    Toggle("Show clicks and drags while recording", isOn: $showMouseIndicators)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("Key captions:") {
                    Toggle("Show pressed keys while recording", isOn: $showKeyPressCaptions)
                        .toggleStyle(.checkbox)
                }

                SettingsRow("Color:") {
                    ColorPicker("", selection: indicatorColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 56)
                }

                SettingsRow("Size:") {
                    HStack(spacing: 12) {
                        Slider(value: $mouseIndicatorSize, in: 24...96, step: 2)
                            .frame(width: 220)

                        Text("\(Int(mouseIndicatorSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct OverlaySettingsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("Overlay")
                .font(.title3.weight(.medium))

            Text("Configure the preview card that appears\nafter taking a screenshot or recording.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension NSColor {
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
