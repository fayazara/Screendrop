//
//  PreviewWindowCaptureExclusion.swift
//  Screendrop
//
//  Created by Codex on 27/04/26.
//

import AppKit
import SwiftUI

@MainActor
final class PreviewWindowCaptureExclusion {
    static let shared = PreviewWindowCaptureExclusion()

    /// Whether Screendrop's UI should be available to screenshot and screen
    /// recording APIs. Opt in via Settings; the pre-record reminder can turn it off.
    static var includesAppWindowsInCaptures: Bool {
        ScreendropPreferences.includeAppWindowsInCaptures
    }

    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    /// Registers any Screendrop-owned window whose capture visibility should
    /// follow the production preference.
    func register(window: NSWindow?) {
        guard let window else { return }

        registeredWindows.add(window)
        applyCaptureVisibility(to: window)
    }

    /// Window numbers that should be removed from a ScreenCaptureKit filter.
    /// Only windows we deliberately marked as hidden from captures belong
    /// here: excluding a whole process also removes the *area* of every window
    /// it owns, even when another app covers that window, which punched
    /// transparent holes in region captures.
    var excludedWindowIDs: Set<CGWindowID> {
        guard !Self.includesAppWindowsInCaptures else { return [] }
        var ids: Set<CGWindowID> = []
        for window in registeredWindows.allObjects
        where window.isVisible && window.sharingType == .none {
            ids.insert(CGWindowID(window.windowNumber))
        }
        return ids
    }

    /// Applies a changed preference immediately to windows that already
    /// exist, rather than waiting for them to be recreated.
    func refreshRegisteredWindows() {
        for window in registeredWindows.allObjects {
            applyCaptureVisibility(to: window)
        }
    }

    private func applyCaptureVisibility(to window: NSWindow) {
        window.sharingType = Self.includesAppWindowsInCaptures ? .readOnly : .none
    }
}
