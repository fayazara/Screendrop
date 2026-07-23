//
//  SettingsWindowController.swift
//  Screendrop
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private var didEnterActivationPolicy = false

    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }

        if shared == nil {
            shared = SettingsWindowController()
        }

        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 700, height: 540)),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .miniaturizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }

        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        // AppKit's inferred order-front transition animates the custom
        // full-size-content window's shadow independently from its frame on
        // Tahoe. Keep the WindowServer geometry static and provide a simple
        // opacity entrance in `showWindow` instead.
        window.animationBehavior = .none
        // Keep the window movable only via its title bar. Background dragging
        // makes the whole content area move the window, which both feels off and
        // swallows in-content drag gestures (e.g. the overlay card editor).
        window.isMovableByWindowBackground = false
        window.setFrameAutosaveName("SettingsWindow")
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        window.delegate = self

        let hostingController = NSHostingController(rootView: SettingsView())
        window.contentViewController = hostingController
        PreviewWindowCaptureExclusion.shared.register(window: window)
    }

    override func showWindow(_ sender: Any?) {
        guard let window else { return }

        if !didEnterActivationPolicy {
            AppActivationPolicy.enter()
            didEnterActivationPolicy = true
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        let shouldAnimate = !window.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.alphaValue = shouldAnimate ? 0 : 1

        super.showWindow(sender)

        guard shouldAnimate else { return }
        window.displayIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        if didEnterActivationPolicy {
            AppActivationPolicy.leave()
            didEnterActivationPolicy = false
        }
        Self.shared = nil
    }
}
