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

    private static let toastSize = NSSize(width: 300, height: 52)
    /// Room around the glass for the shadow it casts.
    private static let shadowSlack: CGFloat = 24
    /// Wide enough for the Retake button beside the text.
    private static let actionToastSize = NSSize(width: 390, height: 52)
    /// Clears the bottom edge by more than the toast is tall, so it reads as
    /// floating over the work rather than stuck to the screen edge.
    private static let bottomInset: CGFloat = 96
    private static let visibleDuration: Duration = .seconds(1.8)
    /// Long enough to read the toast and reach for its button.
    private static let actionVisibleDuration: Duration = .seconds(6)
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

    /// The browser showed a different page by the time the shot finished,
    /// usually because another app is driving it. The capture is kept.
    func showBrowserPageChanged(
        appName: String,
        displayID: CGDirectDisplayID?,
        onRetake: @escaping @MainActor () -> Void
    ) {
        present(
            symbol: "exclamationmark.triangle",
            title: "\(appName) changed during capture",
            detail: "Another app may be controlling it.",
            displayID: displayID,
            action: ToastAction(title: "Retake", perform: onRetake)
        )
    }

    private func present(
        symbol: String,
        title: String,
        detail: String,
        displayID: CGDirectDisplayID?,
        action: ToastAction? = nil
    ) {
        dismissTask?.cancel()
        dismiss()

        let toastSize = action == nil ? Self.toastSize : Self.actionToastSize
        let size = NSSize(width: toastSize.width + 2 * Self.shadowSlack, height: toastSize.height + 2 * Self.shadowSlack)
        let boundAction = action.map { action in
            ToastAction(title: action.title) { [weak self] in
                self?.dismissTask?.cancel()
                self?.dismiss()
                action.perform()
            }
        }
        let hostingView = NSHostingView(
            rootView: CaptureTextFeedbackView(
                symbol: symbol,
                title: title,
                detail: detail,
                action: boundAction,
                size: toastSize
            )
            .padding(Self.shadowSlack)
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
        panel.ignoresMouseEvents = action == nil
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
            try? await Task.sleep(for: action == nil ? Self.visibleDuration : Self.actionVisibleDuration)
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
            y: frame.minY + Self.bottomInset - Self.shadowSlack
        )
    }

    private func screen(for displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }
}

private struct ToastAction {
    let title: String
    let perform: @MainActor () -> Void
}

private struct CaptureTextFeedbackView: View {
    let symbol: String
    let title: String
    let detail: String
    let action: ToastAction?
    let size: NSSize

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.label)
                .frame(width: 30, height: 30)
                .background(Palette.fill, in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.dsHeadline)
                    .foregroundStyle(Palette.label)
                Text(detail)
                    .font(.dsCaption)
                    .foregroundStyle(Palette.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.plain)
                    .font(.dsCaption.weight(.semibold))
                    .foregroundStyle(Palette.label)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Palette.fill, in: Capsule())
            }
        }
        .padding(.horizontal, 11)
        .frame(width: size.width, height: size.height)
        .glassHUD(radius: size.height / 2)
    }
}
