//
//  OpenShotApp.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI

@main
struct OpenShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) var openWindow
    
    var body: some Scene {
        MenuBarExtra("OpenShot", image: "MenuBarIcon") {
            MenuBarView()
                .onAppear {
                    // Wire the coordinator to open the preview window.
                    // This runs once when the menu first appears.
                    CaptureCoordinator.shared.onShowPreview = { [openWindow] url in
                        ScreenshotPreviewStack.shared.add(url: url)
                        openWindow(id: "PREVIEWWINDOW")
                    }
                }
        }
        
        // Single floating preview window. The stack model owns individual cards.
        Window("OpenShot Preview", id: "PREVIEWWINDOW") {
            PreviewWindowView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .background(PreviewWindowCaptureExclusionView())
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        .defaultWindowPlacement { content, context in
            return .init(size: context.defaultDisplay.visibleRect.size)
        }
        
        Window("OpenShot Settings", id: "SETTINGS") {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotkeyManager.shared.registerHotkeys()
    }
}
