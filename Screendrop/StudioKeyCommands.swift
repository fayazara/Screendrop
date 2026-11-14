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
//    K + J / L    hold K and tap J or L to step a frame
//    ←  →         one frame; with ⇧, one second
//    ↑  ↓         previous / next cut or marker
//    Home  End    start / end
//    S            split at the playhead (the selected audio clip, else the video)
//    C            split the video under the pointer
//    V            mute or unmute the selected audio clip, else the video clip
//    I  O         mark the start / end of a range; ⌫ deletes it
//    M            add or remove a marker
//    N            snapping on / off
//    ⇧S           skimming on / off
//    ⌫            delete the selection, or the marked range
//
//  Keys with ⌘ or ⌥ (⌘B, ⇧⌘B, ⌥⌘B, ⌥[, ⌥], ⌥X, ⌘D) are menu items in
//  `StudioCommands`, so they show in the menu bar and fire once.
//

import AppKit
import SwiftUI

struct StudioKeyCommands: NSViewRepresentable {
    /// What the timeline itself has to do; everything else goes to the model.
    enum Command {
        case toggleSnapping
        case toggleSkimming
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
        /// K is down: J and L step a frame instead of playing.
        private var isKHeld = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyUp {
                    if event.charactersIgnoringModifiers?.lowercased() == "k" { self.isKHeld = false }
                    return event
                }
                return self.handle(event) ? nil : event
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
            default:
                break
            }

            if modifiers == .shift, key == "s" {
                perform?(.toggleSkimming)
                return true
            }
            if modifiers.isEmpty {
                switch key {
                case "j", "l":
                    if isKHeld {
                        model.stepFrames(key == "l" ? 1 : -1)
                    } else {
                        model.shuttle(forward: key == "l")
                    }
                case "k":
                    isKHeld = true
                    model.pause()
                case "s": model.blade(at: model.currentTime)
                case "c":
                    guard let time = model.timelineHoverTime else { return false }
                    model.splitClip(at: time)
                case "v": toggleMute(model)
                case "n": perform?(.toggleSnapping)
                case "i": model.markRange(.start)
                case "o": model.markRange(.end)
                case "m": model.toggleMarker()
                default: return false
                }
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

/// Pinch and ⌘-scroll over the timeline zoom it, wherever the pointer is
/// over the tracks. A plain scroll is left alone, so two-finger swipes
/// still pan. It watches the window's events rather than sitting in the
/// view tree, because the tracks' scroll views would take them first.
struct StudioZoomGestureCatcher: NSViewRepresentable {
    /// `(factor, x)`: how much to scale, around which point of the view.
    let onZoom: (Double, CGFloat) -> Void

    /// Scroll distance that doubles the timeline's scale.
    private static let pointsPerDoubling: CGFloat = 220

    func makeNSView(context: Context) -> CatcherView {
        CatcherView()
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onZoom = onZoom
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.removeMonitor()
    }

    final class CatcherView: NSView {
        var onZoom: ((Double, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self, self.handle(event) else { return event }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, let onZoom else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
            switch event.type {
            case .magnify:
                guard event.magnification != 0 else { return true }
                onZoom(1 + Double(event.magnification), point.x)
                return true
            case .scrollWheel:
                guard event.modifierFlags.contains(.command) else { return false }
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
                guard abs(delta) > 0.001 else { return true }
                onZoom(pow(2, Double(delta / StudioZoomGestureCatcher.pointsPerDoubling)), point.x)
                return true
            default:
                return false
            }
        }
    }
}
