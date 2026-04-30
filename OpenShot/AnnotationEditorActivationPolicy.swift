//
//  AnnotationEditorActivationPolicy.swift
//  OpenShot
//

import AppKit

@MainActor
enum AnnotationEditorActivationPolicy {
    private static var activeWindowCount = 0

    static func enter() {
        activeWindowCount += 1
        PreviewWindowCaptureExclusion.shared.hideForAnnotation()
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        activeWindowCount = max(0, activeWindowCount - 1)
        guard activeWindowCount == 0 else { return }

        PreviewWindowCaptureExclusion.shared.restoreAfterAnnotation()

        Task { @MainActor in
            guard activeWindowCount == 0 else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
