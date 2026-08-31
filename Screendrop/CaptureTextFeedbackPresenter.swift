//
//  CaptureTextFeedbackPresenter.swift
//  Screendrop
//
//  Capture Text is the one capture action that leaves nothing behind - no
//  file, no history entry, no preview card - so the capture sound was its
//  only signal that anything happened, and users with sounds turned off got
//  no feedback at all. This is the missing surface: a brief centered toast
//  that confirms what landed on the clipboard, or says nothing was found.
//

import AppKit
import SwiftUI

@MainActor
final class CaptureTextFeedbackPresenter {
    static let shared = CaptureTextFeedbackPresenter()

    private static let panelSize = NSSize(width: 300, height: 52)
    /// Clears the bottom edge by more than the toast is tall, so it reads as
    /// floating over the work rather than stuck to the screen edge.
    private static let bottomInset: CGFloat = 96
    private static let visibleDuration: Duration = .seconds(1.8)
    private static let fadeOutDuration: TimeInterval = 0.2

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Confirms the copy, previewing the text itself so the user can tell at a
    /// glance that the right region was read.
    func showCopied(text: String, displayID: CGDirectDisplayID?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let title = lines.count == 1
            ? "Copied 1 line"
            : "Copied \(lines.count) lines"
        present(
            symbol: "text.viewfinder",
            title: title,
            detail: lines.first.map(String.init) ?? text,
            displayID: displayID
        )
    }

    /// The capture succeeded but Vision found nothing. Not a failure worth an
    /// `NSAlert` - the user just picked an empty region and will try again.
    func showNoTextFound(displayID: CGDirectDisplayID?) {
        present(
            symbol: "text.viewfinder",
            title: "No text found",
            detail: "Nothing was recognized in that area.",
            displayID: displayID
        )
    }

    private func present(
        symbol: String,
        title: String,
        detail: String,
        displayID: CGDirectDisplayID?
    ) {
        dismissTask?.cancel()
        dismiss()

        let size = Self.panelSize
        let hostingView = NSHostingView(
            rootView: CaptureTextFeedbackView(
                symbol: symbol,
                title: title,
                detail: detail,
                size: size
            )
        )
        // The panel is framed by hand below, so the hosting view must not try
        // to resize the window to its own intrinsic content size.
        hostingView.sizingOptions = []

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = hostingView
        panel.setFrame(
            NSRect(origin: origin(size: size, displayID: displayID), size: size),
            display: true
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // A back-to-back capture should not photograph the previous toast.
        PreviewWindowCaptureExclusion.shared.register(window: panel)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            await self?.fadeOutAndDismiss()
        }
    }

    /// Awaits the fade rather than tearing down in an animation completion
    /// handler, which would run outside this type's MainActor isolation.
    private func fadeOutAndDismiss() async {
        guard let panel else { return }

        await NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }

        // A newer toast may have replaced this one mid-fade, in which case it
        // has already ordered this panel out.
        guard self.panel === panel else { return }
        dismiss()
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func origin(size: NSSize, displayID: CGDirectDisplayID?) -> CGPoint {
        let screen = screen(for: displayID) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + Self.bottomInset
        )
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

private struct CaptureTextFeedbackView: View {
    let symbol: String
    let title: String
    let detail: String
    let size: NSSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }
}
