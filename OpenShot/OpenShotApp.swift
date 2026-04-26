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
                        openWindow(id: "PREVIEWWINDOW", value: url)
                    }
                }
        }
        
        // Floating preview window — pattern from the premium template
        WindowGroup(id: "PREVIEWWINDOW", for: URL.self) { value in
            PreviewWindowView(url: value)
                .frame(width: previewWindowSize.width, height: previewWindowSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: previewWindowAnchor)
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
    
    var previewWindowSize: CGSize {
        .init(width: 260, height: 200)
    }
    
    var previewWindowAnchor: Alignment {
        .bottomTrailing
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        HotkeyManager.shared.registerHotkeys()
    }
}
