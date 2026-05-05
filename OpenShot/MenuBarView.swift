//
//  MenuBarView.swift
//  OpenShot
//
//  Created by Fayaz Ahmed Aralikatti on 26/04/26.
//

import ScreenCaptureKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var recordingSources = RecordingSourceCatalog.shared
    
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

            Menu {
                recordingMenuContent
            } label: {
                Label("Record Screen", systemImage: "record.circle")
            }
            
            Divider()

            Button {
                openWindow(id: "HISTORY")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut("h", modifiers: [.command])
            
            Button {
                openWindow(id: "SETTINGS")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])
            
            Divider()
            
            Button("Quit OpenShot") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .task {
            await recordingSources.refresh()
        }
    }

    @ViewBuilder
    private var recordingMenuContent: some View {
        if recordingSources.isLoading {
            Label("Loading sources...", systemImage: "hourglass")
        }

        if let errorMessage = recordingSources.errorMessage {
            Text("Unable to load sources")
            Text(errorMessage)
        }

        Menu("Full Screen") {
            if recordingSources.displays.isEmpty {
                Text("No displays found")
            } else {
                ForEach(Array(recordingSources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        CaptureCoordinator.shared.recordFullscreen(display)
                    }
                }
            }
        }

        Menu("Area") {
            if recordingSources.displays.isEmpty {
                Text("No displays found")
            } else {
                ForEach(Array(recordingSources.displays.enumerated()), id: \.element.displayID) { index, display in
                    Button(RecordingSourceCatalog.displayTitle(display, index: index)) {
                        CaptureCoordinator.shared.recordArea(display)
                    }
                }
            }
        }

        Menu("Window") {
            if recordingSources.windows.isEmpty {
                Text("No app windows found")
            } else {
                ForEach(recordingSources.windows, id: \.windowID) { window in
                    Button(RecordingSourceCatalog.windowTitle(window)) {
                        CaptureCoordinator.shared.recordWindow(window)
                    }
                }
            }

            Divider()

            Button {
                Task {
                    await recordingSources.refresh()
                }
            } label: {
                Label("Refresh Windows", systemImage: "arrow.clockwise")
            }
        }

        Divider()

        Button {
            Task {
                await recordingSources.refresh()
            }
        } label: {
            Label("Refresh Sources", systemImage: "arrow.clockwise")
        }
    }
}
