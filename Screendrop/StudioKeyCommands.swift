//
//  StudioKeyCommands.swift
//  Screendrop
//
//  The Studio editor's keys. They work wherever the pointer is in the
//  editor's window, not only over the clips, and stand aside while text is
//  being typed or the crop is open.
//
//    Space        play / pause (the transport's own shortcut)
//    J  K  L      play backward / pause / play forward; again to go faster
//    ←  →         one frame; with ⇧, one second
//    ↑  ↓         previous / next cut
//    Home  End    start / end
//    ⌘B  or  S    split at the playhead (the selected audio clip, else the video)
//    ⇧⌘B          split the video and every audio clip
//    C            split the video under the pointer
//    ⌥[  ⌥]       trim the start / end to the playhead
//    ⌘D           duplicate the selected audio clip
//    V            mute or unmute the selected audio clip, else the video clip
//    ⌥⌘B          detach the clip's audio onto a lane
//    N            snapping on / off
//    ⌫            delete the selection
//

import AppKit
import SwiftUI

struct StudioKeyCommands: NSViewRepresentable {
    /// What the timeline itself has to do; everything else goes to the model.
    enum Command {
        case toggleSnapping
        case delete
    }

    let model: RecordingStudioModel
    let perform: (Command) -> Void

    func makeNSView(context: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.model = model
        view.perform = perform
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    final class MonitorView: NSView {
        weak var model: RecordingStudioModel?
        var perform: ((Command) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the key was one of the editor's and has been dealt with.
        private func handle(_ event: NSEvent) -> Bool {
            guard let model, model.isLoaded, !model.isCroppingVideo,
                  let window, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return false }

            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            switch event.keyCode {
            case 123, 124: // ← →
                guard modifiers.subtracting(.shift).isEmpty else { return false }
                let forward = event.keyCode == 124
                if modifiers.contains(.shift) {
                    model.pause()
                    model.seek(to: model.currentTime + (forward ? 1 : -1))
                } else {
                    model.stepFrames(forward ? 1 : -1)
                }
                return true
            case 126, 125: // ↑ ↓
                guard modifiers.isEmpty else { return false }
                model.seekToEditPoint(forward: event.keyCode == 125)
                return true
            case 115, 119: // Home, End
                guard modifiers.isEmpty else { return false }
                model.pause()
                model.seek(to: event.keyCode == 115 ? 0 : model.duration)
                return true
            case 51, 117: // ⌫, ⌦
                guard modifiers.isEmpty else { return false }
                perform?(.delete)
                return true
            case 33, 30: // [ ]
                guard modifiers == .option else { return false }
                model.trimToPlayhead(event.keyCode == 33 ? .start : .end)
                return true
            default:
                break
            }

            if modifiers.isEmpty {
                switch key {
                case "j": model.shuttle(forward: false)
                case "k": model.pause()
                case "l": model.shuttle(forward: true)
                case "s": model.blade(at: model.currentTime)
                case "c":
                    guard let time = model.timelineHoverTime else { return false }
                    model.splitClip(at: time)
                case "v": toggleMute(model)
                case "n": perform?(.toggleSnapping)
                default: return false
                }
                return true
            }
            if key == "b", modifiers == [.command, .shift] {
                model.blade(at: model.currentTime, everything: true)
                return true
            }
            if key == "b", modifiers == [.command, .option] {
                if let clip = model.soundTargetClip { model.detachAudio(fromClipID: clip.id) }
                return true
            }
            if key == "d", modifiers == .command, let id = model.selectedAudioClipID {
                model.duplicateAudioClip(id: id)
                return true
            }
            return false
        }

        private func toggleMute(_ model: RecordingStudioModel) {
            if let id = model.selectedAudioClipID {
                model.toggleAudioClipMuted(id: id)
            } else if let clip = model.soundTargetClip {
                model.toggleClipMuted(id: clip.id)
            }
        }
    }
}
