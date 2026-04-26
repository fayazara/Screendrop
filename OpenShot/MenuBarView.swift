//
//  MenuBarView.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import SwiftUI

struct MenuBarView: View {
    var body: some View {
        Group {
            Button {
                CaptureCoordinator.shared.captureFullscreen()
            } label: {
                Label("Capture Fullscreen", systemImage: "macwindow")
            }
            .keyboardShortcut("1", modifiers: [.option])
            
            Button {
                CaptureCoordinator.shared.captureWindow()
            } label: {
                Label("Capture Window", systemImage: "macwindow.on.rectangle")
            }
            .keyboardShortcut("2", modifiers: [.option])
            
            Button {
                CaptureCoordinator.shared.captureArea()
            } label: {
                Label("Capture Area", systemImage: "rectangle.dashed")
            }
            .keyboardShortcut("3", modifiers: [.option])
            
            Divider()
            
            Button("Quit OpenShot") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
