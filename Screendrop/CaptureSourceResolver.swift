//
//  CaptureSourceResolver.swift
//  Screendrop
//

import AppKit
import CoreGraphics

/// Works out which app and window a capture came from, for the `%a` and `%t`
/// file name tokens. Window and area captures go through `screencapture`,
/// which never reports what was clicked, so this reads the on-screen window
/// list right after the capture returns instead.
@MainActor
enum CaptureSourceResolver {
    /// The window under the pointer, which is where the user just clicked
    /// (window capture) or finished dragging (area capture). Falls back to
    /// the frontmost window when nothing is under the pointer.
    static func namingContextUnderPointer() -> CaptureNamingContext {
        namingContext(from: windowUnderPointer() ?? frontmostWindow())
    }

    /// The frontmost window of the frontmost app, for captures that have no
    /// pointer position worth trusting (fullscreen).
    static func namingContextForFrontmostWindow() -> CaptureNamingContext {
        namingContext(from: frontmostWindow())
    }

    private static func namingContext(from window: WindowInfo?) -> CaptureNamingContext {
        CaptureNamingContext(appName: window?.appName, windowTitle: window?.title)
    }

    // MARK: - Window list

    private struct WindowInfo {
        let ownerPID: pid_t
        let bounds: CGRect
        let appName: String?
        let title: String?
    }

    /// Ordinary app windows, front to back, excluding Screendrop's own
    /// overlays so a capture started from the Library is not named after it.
    private static func visibleWindows() -> [WindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = getpid()
        return windowList.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return nil
            }

            return WindowInfo(
                ownerPID: pid,
                bounds: bounds,
                appName: nonEmpty(info[kCGWindowOwnerName as String] as? String)
                    ?? NSRunningApplication(processIdentifier: pid)?.localizedName,
                title: nonEmpty(info[kCGWindowName as String] as? String)
            )
        }
    }

    private static func windowUnderPointer() -> WindowInfo? {
        // Window bounds are in Quartz coordinates (origin at the top left of
        // the primary display); the pointer comes from AppKit (bottom left).
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: primaryScreen.frame.maxY - location.y)
        return visibleWindows().first { $0.bounds.contains(point) }
    }

    private static func frontmostWindow() -> WindowInfo? {
        let windows = visibleWindows()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let window = windows.first(where: { $0.ownerPID == pid }) {
            return window
        }
        return windows.first
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }
}
