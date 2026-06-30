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

        configureWindowChrome()
        // Keep the window movable only via its title bar. Background dragging
        // makes the whole content area move the window, which both feels off and
        // swallows in-content drag gestures (e.g. the overlay card editor).
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        window.delegate = self

        let hostingController = NSHostingController(rootView: SettingsView())
        window.contentViewController = hostingController
    }

    private func configureWindowChrome() {
        guard let window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
    }

    override func showWindow(_ sender: Any?) {
        configureWindowChrome()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
        if !didEnterActivationPolicy {
            AppActivationPolicy.enter()
            didEnterActivationPolicy = true
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if didEnterActivationPolicy {
            AppActivationPolicy.leave()
            didEnterActivationPolicy = false
        }
    }
}
