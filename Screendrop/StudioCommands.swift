//
//  StudioCommands.swift
//  Screendrop
//
//  The Clip and Playback menus for the Studio editor. They act on the
//  front Studio window's model, published by its timeline as a focused
//  scene value. Items with modifier keys carry their shortcuts here; the
//  bare-letter keys (J K L, S, V, I, O, M...) stay in `StudioKeyCommands`,
//  because a menu key equivalent without a modifier would take typing
//  away from the inspector's text fields.
//

import SwiftUI

extension FocusedValues {
    @Entry var studioModel: RecordingStudioModel?
}

struct StudioCommands: Commands {
    @FocusedValue(\.studioModel) private var model

    var body: some Commands {
        CommandMenu("Clip") {
            Group {
            Button("Split at Playhead") { model?.blade(at: model?.currentTime ?? 0) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Split Video and All Audio") { model?.blade(at: model?.currentTime ?? 0, everything: true) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Trim Start to Playhead") { model?.trimToPlayhead(.start) }
                .keyboardShortcut("[", modifiers: .option)
            Button("Trim End to Playhead") { model?.trimToPlayhead(.end) }
                .keyboardShortcut("]", modifiers: .option)
            Divider()
            Button("Mark In (I)") { model?.markRange(.start) }
            Button("Mark Out (O)") { model?.markRange(.end) }
            Button("Delete Marked Range") { model?.deleteRange() }
                .disabled(model?.rangeSelection == nil)
            Button("Clear Marked Range") { model?.clearRange() }
                .keyboardShortcut("x", modifiers: .option)
                .disabled(model?.rangeSelection == nil)
            Divider()
            Button("Detach Audio") {
                if let model, let clip = model.soundTargetClip { model.detachAudio(fromClipID: clip.id) }
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Button("Mute or Unmute (V)") {
                guard let model else { return }
                if let id = model.selectedAudioClipID {
                    model.toggleAudioClipMuted(id: id)
                } else if let clip = model.soundTargetClip {
                    model.toggleClipMuted(id: clip.id)
                }
            }
            Button("Duplicate Audio") {
                if let model, let id = model.selectedAudioClipID { model.duplicateAudioClip(id: id) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(model?.selectedAudioClipID == nil)
            Divider()
            Button("Add or Remove Marker (M)") { model?.toggleMarker() }
            }
            .disabled(model?.isLoaded != true)
        }

        CommandMenu("Playback") {
            Group {
            Button("Play Backward (J)") { model?.shuttle(forward: false) }
            Button("Pause (K)") { model?.pause() }
            Button("Play Forward (L)") { model?.shuttle(forward: true) }
            Divider()
            Button("Previous Cut (↑)") { model?.seekToEditPoint(forward: false) }
            Button("Next Cut (↓)") { model?.seekToEditPoint(forward: true) }
            Button("Previous Frame (←)") { model?.stepFrames(-1) }
            Button("Next Frame (→)") { model?.stepFrames(1) }
            Divider()
            Button("Go to Start (Home)") {
                model?.pause()
                model?.seek(to: 0)
            }
            Button("Go to End (End)") {
                guard let model else { return }
                model.pause()
                model.seek(to: model.duration)
            }
            }
            .disabled(model?.isLoaded != true)
        }
    }
}
