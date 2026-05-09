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

    private let panelSize = CGSize(width: 244, height: 38)
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

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }

        return panel.frame.contains(point)
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
        let hostingView = RecordingControlHostingView(rootView: RecordingControlView())
        hostingView.frame = CGRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.contentView?.superview?.wantsLayer = true
        panel.contentView?.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.superview?.layer?.isOpaque = false

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

private final class RecordingControlHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool {
        false
    }
}

private struct RecordingControlView: View {
    @State private var manager = ScreenRecordingManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
                .opacity(manager.state == .paused ? 0.4 : 1)

            Text(manager.formattedElapsedTime)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 40, alignment: .leading)

            Divider()
                .frame(height: 14)

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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 38)
        .background(Color(white: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }

    private func controlButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 16, height: 16)
                .foregroundStyle(systemImage == "stop.fill" ? .red : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
