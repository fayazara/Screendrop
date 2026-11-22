//
//  SettingsShortcutsPane.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Settings → Shortcuts: every global capture shortcut in one list, in the
/// order of their default keys (⌥1 to ⌥5). One recorder serves every row,
/// so only one well can listen at a time.
struct ShortcutsSettingsPane: View {
    private let actions: [CaptureHotkeyAction] = [.fullscreen, .window, .area, .screenRecording, .textCapture]

    @State private var shortcuts = CaptureHotkeyPreferences.shortcuts()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var recordingAction: CaptureHotkeyAction?
    @State private var errorMessage: String?

    var body: some View {
        SettingsPage {
            Section {
                ForEach(actions) { action in
                    row(for: action)
                }
            } header: {
                Text("Capture")
            } footer: {
                footer
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

    private func row(for action: CaptureHotkeyAction) -> some View {
        SettingsRow {
            HStack(spacing: Space.m) {
                if shortcut(for: action) != action.defaultShortcut, !isRecording(action) {
                    InspectorResetButton(help: "Restore the default shortcut") {
                        resetShortcut(for: action)
                    }
                    .transition(.blurPop)
                }

                SettingsShortcutWell(
                    tokens: shortcut(for: action).displayTokens,
                    isRecording: isRecording(action)
                ) {
                    toggleRecording(for: action)
                }
            }
            .motion(.morphQuick, value: shortcut(for: action))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: action))
                if let failure = HotkeyManager.shared.registrationErrors[action] {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Palette.record)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Palette.record)
            }
            Text(recordingAction != nil
                 ? "Press a key combination with at least one modifier. Press Esc to cancel."
                 : "Click a shortcut to record a new one.")
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .font(.caption)
        .motion(value: recordingAction)
    }

    private func title(for action: CaptureHotkeyAction) -> String {
        switch action {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        case .textCapture: "Capture Text"
        case .screenRecording: "Record Screen"
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

        // Switching straight to another well restarts the one recorder.
        recorder.stop()
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
            errorMessage = "\(shortcut.displayString) is already assigned to \(title(for: conflict))."
            NSSound.beep()
            recorder.stop()
            recordingAction = nil
            return
        }

        do {
            try HotkeyManager.shared.setShortcut(shortcut, for: action)
            shortcuts[action] = shortcut
            errorMessage = nil
        } catch {
            errorMessage = "\(error.localizedDescription) Your previous shortcut has been kept."
            NSSound.beep()
        }
        recordingAction = nil
    }

    private func reloadShortcuts() {
        shortcuts = CaptureHotkeyPreferences.shortcuts()
    }
}
