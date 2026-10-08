//
//  FileNameSettingsSection.swift
//  Screendrop
//

import SwiftUI

/// Form section for the capture file name template: the editable pattern, a
/// live preview, a palette of tokens to insert, and the time zone switch.
struct FileNameSettingsSection: View {
    @AppStorage(ScreendropPreferences.fileNameTemplateKey) private var template = CaptureFileNameTemplate.defaultTemplate
    @AppStorage(ScreendropPreferences.fileNameUsesUTCKey) private var usesUTC = false

    /// Tokens laid out in two columns, like the token sheet users know
    /// from other capture tools.
    private static let tokenColumns: [[CaptureFileNameTemplate.Token]] = [
        [.year, .month, .monthName, .day, .weekday, .windowTitle, .appName],
        [.hour, .minute, .second, .meridiem, .random, .sequence],
    ]

    private var preview: String {
        let sample = CaptureNamingContext(appName: "App name", windowTitle: "Window title", sequenceNumber: 1)
        let stem = CaptureFileNameTemplate.stem(
            template: ScreendropPreferences.fileNameTemplate,
            context: sample,
            timeZone: usesUTC ? .gmt : .current
        )
        return "\(stem).\(ScreendropPreferences.exportFormat.fileExtension)"
    }

    var body: some View {
        Section("File Name") {
            TextField("Template", text: $template)
                .autocorrectionDisabled()

            LabeledContent("Preview") {
                Text(preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Click a token to add it to the template.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 40) {
                    ForEach(Self.tokenColumns, id: \.self) { column in
                        tokenGrid(column)
                    }
                }
            }
            .padding(.vertical, 4)

            Toggle(isOn: $usesUTC) {
                SettingsControlLabel(
                    "Use UTC time zone",
                    detail: "Date and time tokens use UTC instead of the local time zone."
                )
            }
            .toggleStyle(.switch)

            HStack {
                Spacer()
                Button("Restore Default") {
                    template = CaptureFileNameTemplate.defaultTemplate
                }
                .controlSize(.small)
                .disabled(ScreendropPreferences.fileNameTemplate == CaptureFileNameTemplate.defaultTemplate)
            }
        }
    }

    private func tokenGrid(_ tokens: [CaptureFileNameTemplate.Token]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(tokens) { token in
                GridRow {
                    Text(token.title)
                    TokenChipButton(token: token) {
                        template.append(token.placeholder)
                    }
                }
            }
        }
    }
}

/// A file name token drawn as the same key cap the hotkey section uses.
private struct TokenChipButton: View {
    let token: CaptureFileNameTemplate.Token
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HotkeyKeyCap(token: token.placeholder)
        }
        .buttonStyle(.plain)
        .help("Insert \(token.title)")
        .accessibilityLabel("Insert \(token.title)")
    }
}
