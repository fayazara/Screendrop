//
//  CaptureHotkeySettingsSection.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct CaptureHotkeySettingsSection: View {
    let actions: [CaptureHotkeyAction]

    @State private var shortcuts = CaptureHotkeyPreferences.shortcuts()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var recordingAction: CaptureHotkeyAction?
    @State private var errorMessage: String?

    var body: some View {
        Section("Keyboard Shortcuts") {
            ForEach(actions) { action in
                LabeledContent(action.title) {
                    HStack(spacing: 8) {
                        HotkeyShortcutDisplay(shortcut: shortcut(for: action))

                        Button(isRecording(action) ? "Press keys..." : "Record") {
                            toggleRecording(for: action)
                        }
                        .controlSize(.small)

                        Button("Reset") {
                            resetShortcut(for: action)
                        }
                        .controlSize(.small)
                        .disabled(shortcut(for: action) == action.defaultShortcut)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if recordingAction != nil {
                Text("Press a key combination with at least one modifier. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            reloadShortcuts()
            configureRecorder()
        }
        .onDisappear {
            recorder.stop()
            recordingAction = nil
        }
    }

    private func shortcut(for action: CaptureHotkeyAction) -> HotkeyShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    private func isRecording(_ action: CaptureHotkeyAction) -> Bool {
        recorder.isRecording && recordingAction == action
    }

    private func toggleRecording(for action: CaptureHotkeyAction) {
        errorMessage = nil

        if isRecording(action) {
            recorder.stop()
            recordingAction = nil
            return
        }

        recordingAction = action
        recorder.start()
    }

    private func resetShortcut(for action: CaptureHotkeyAction) {
        apply(action.defaultShortcut, to: action)
    }

    private func configureRecorder() {
        recorder.onShortcutRecorded = { shortcut in
            guard let recordingAction else { return }
            apply(shortcut, to: recordingAction)
        }

        recorder.onCancel = {
            recordingAction = nil
        }
    }

    private func apply(_ shortcut: HotkeyShortcut, to action: CaptureHotkeyAction) {
        if let conflict = CaptureHotkeyPreferences.conflictingAction(for: shortcut, excluding: action) {
            errorMessage = "\(shortcut.displayString) is already assigned to \(conflict.title)."
            NSSound.beep()
            recorder.stop()
            recordingAction = nil
            return
        }

        CaptureHotkeyPreferences.saveShortcut(shortcut, for: action)
        shortcuts[action] = shortcut
        errorMessage = nil
        recordingAction = nil
        HotkeyManager.shared.reloadHotkeys()
    }

    private func reloadShortcuts() {
        shortcuts = CaptureHotkeyPreferences.shortcuts()
    }
}

private struct HotkeyShortcutDisplay: View {
    let shortcut: HotkeyShortcut

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shortcut.displayTokens, id: \.self) { token in
                HotkeyKeyCap(token: token)
            }
        }
        .accessibilityLabel(shortcut.displayString)
    }
}

private struct HotkeyKeyCap: View {
    let token: String

    var body: some View {
        Text(token)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .frame(minWidth: 22, minHeight: 21)
            .padding(.horizontal, token.count > 1 ? 6 : 0)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.separator.opacity(0.35))
            }
    }
}
