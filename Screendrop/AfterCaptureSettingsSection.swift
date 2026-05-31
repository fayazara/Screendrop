//
//  AfterCaptureSettingsSection.swift
//  Screendrop
//

import SwiftUI

/// A Form section listing the configurable after-capture actions for a given
/// capture type (screenshot or recording).
struct AfterCaptureActionsSection: View {
    let type: AfterCaptureType
    let title: String

    var body: some View {
        Section(title) {
            ForEach(AfterCaptureAction.actions(for: type)) { action in
                AfterCaptureToggleRow(action: action, type: type)
            }
        }
    }
}

private struct AfterCaptureToggleRow: View {
    @AppStorage private var isOn: Bool
    private let title: String
    private let subtitle: String

    init(action: AfterCaptureAction, type: AfterCaptureType) {
        _isOn = AppStorage(wrappedValue: action.defaultValue, action.storageKey(for: type))
        title = action.title
        subtitle = action.subtitle
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
