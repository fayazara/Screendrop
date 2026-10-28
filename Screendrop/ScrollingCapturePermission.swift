//
//  ScrollingCapturePermission.swift
//  Screendrop
//  Contributed by Rochak Agrawal (Screenshot X).
//
//  Accessibility access for automatic scrolling capture. macOS 26 folds the
//  old Accessibility list into Privacy & Security → Device Control and Data
//  Access; an app only appears there after it asks with
//  AXIsProcessTrustedWithOptions(prompt: true).
//

import AppKit
import ApplicationServices

@MainActor
enum ScrollingCapturePermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks macOS to add Screendrop X to the list, opens the pane that holds
    /// it, and explains where to look on macOS 26.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for Screendrop"
        alert.informativeText = """
        On macOS 26 this setting lives in Privacy & Security → Device Control and Data Access. \
        Turn on Screendrop there (use + if it is not listed yet), then quit and reopen the app.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
