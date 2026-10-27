//
//  AnnotationEditorActivationPolicy.swift
//  Screendrop
//

import AppKit

/// Manages the app's activation policy so that regular windows (annotation
/// editor, settings) show the Dock icon and appear in Cmd-Tab.  Uses
/// reference counting so the policy stays `.regular` until *all* windows leave.
@MainActor
enum AppActivationPolicy {
    private static var activeWindowCount = 0
    /// Editors opened from the capture shelf, which tuck it while open.
    private static var shelfEditorCount = 0

    /// Call when a regular window (annotation editor, video editor, settings, etc.) appears.
    /// Pass `hidePreview: true` for editing flows launched from the preview panel.
    static func enter(hidePreview: Bool = false) {
        activeWindowCount += 1
        if hidePreview {
            // The shelf tucks into the screen edge rather than covering the
            // editor; its handle stays to bring it back.
            shelfEditorCount += 1
            CaptureShelf.shared.tuck(.editor)
        }
        // This build is a menu-bar app: it never takes a Dock icon, even
        // while an editor or the Library is open. The window still comes
        // forward and can be focused.
        NSApp.setActivationPolicy(.accessory)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call when a regular window closes.
    /// Pass `restorePreview: true` for editing flows launched from the preview panel.
    static func leave(restorePreview: Bool = false) {
        activeWindowCount = max(0, activeWindowCount - 1)
        if restorePreview {
            shelfEditorCount = max(0, shelfEditorCount - 1)
            if shelfEditorCount == 0 {
                CaptureShelf.shared.untuck(.editor)
            }
        }
        guard activeWindowCount == 0 else { return }


    }
}

/// Legacy alias so existing annotation editor callsites still compile.
typealias AnnotationEditorActivationPolicy = AppActivationPolicy
