//
//  RecordingControlPresenter.swift
//  OpenShot
//
//  Created by Codex on 01/05/26.
//

import AppKit
import SwiftUI

@MainActor
final class RecordingControlPresenter {
    static let shared = RecordingControlPresenter()

    private let panelSize = CGSize(width: 320, height: 56)
    private var panel: NSPanel?

    private init() {}

    func show(displayID: CGDirectDisplayID?) {
        let panel = panel ?? makePanel()
        positionPanel(panel, displayID: displayID)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = RecordingControlPanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: RecordingControlView())

        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel, displayID: CGDirectDisplayID?) {
        let screen = ActiveDisplayResolver.screen(for: displayID) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let origin = CGPoint(x: visibleFrame.midX - panelSize.width / 2, y: visibleFrame.minY + 60)
        panel.setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }
}

private final class RecordingControlPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

private struct RecordingControlView: View {
    @State private var manager = ScreenRecordingManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(manager.state == .paused ? 0.4 : 1)

            Text(manager.formattedElapsedTime)
                .font(.system(.body, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 56, alignment: .leading)

            Divider()
                .frame(height: 20)

            controlButton(
                systemImage: manager.state == .paused ? "play.fill" : "pause.fill",
                help: manager.state == .paused ? "Resume recording" : "Pause recording"
            ) {
                if manager.state == .paused {
                    manager.resumeRecording()
                } else {
                    manager.pauseRecording()
                }
            }
            .disabled(manager.state == .starting || manager.state == .finishing)

            controlButton(systemImage: "arrow.counterclockwise", help: "Restart recording") {
                manager.restartRecording()
            }
            .disabled(manager.state == .starting || manager.state == .finishing)

            controlButton(systemImage: "stop.fill", help: "Stop recording") {
                manager.stopRecording()
            }
            .disabled(manager.state == .starting || manager.state == .finishing)

            controlButton(systemImage: "trash.fill", help: "Delete recording") {
                manager.deleteRecording()
            }
            .disabled(manager.state == .starting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 320, height: 56)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }

    private func controlButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout)
                .frame(width: 20, height: 20)
                .foregroundStyle(systemImage == "stop.fill" ? .red : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
