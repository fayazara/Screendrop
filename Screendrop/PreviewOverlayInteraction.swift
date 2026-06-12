//
//  PreviewOverlayInteraction.swift
//  Screendrop
//
//  Hit-test passthrough + peek tab for the always-on preview overlay.
//

import AppKit
import SwiftUI

/// Hosting view for the preview overlay panel that lets mouse events fall
/// through to the windows beneath it everywhere except the actual interactive
/// elements (the cards, or the collapsed peek tab).
///
/// The overlay is a full-screen, high-level floating panel that now stays
/// visible at all times (it collapses to a peek tab instead of hiding). Without
/// passthrough it would swallow every click across the whole screen and block
/// the editor underneath. We read the live interactive frames published by the
/// SwiftUI layer and return `nil` from `hitTest` for any point outside them, so
/// the panel is "transparent" to clicks except where there's something to hit.
final class PassthroughPreviewHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let rects = ScreenshotPreviewStack.shared.interactiveRects

        // Nothing interactive yet (or not reported): fail safe by passing the
        // event through so we never accidentally block the windows below.
        guard !rects.isEmpty else { return nil }

        // `point` is in the superview's coordinate system. Converting it into
        // this (flipped, top-left origin) hosting view's space matches the
        // SwiftUI `.global` frames the cards/peek tab publish, so no manual
        // y-flip is required.
        let local = convert(point, from: superview)
        let isInteractive = rects.contains { $0.insetBy(dx: -3, dy: -3).contains(local) }

        return isInteractive ? super.hitTest(point) : nil
    }
}

/// Collects the `.global` frames of the overlay's interactive elements so the
/// hosting view can route clicks through everything else.
struct InteractiveRectsKey: PreferenceKey {
    static var defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

extension View {
    /// Publishes this view's `.global` frame as an interactive region for the
    /// passthrough hosting view.
    func reportsInteractiveRect() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InteractiveRectsKey.self,
                    value: [proxy.frame(in: .global)]
                )
            }
        )
    }
}

/// Fixed width of the peek tab, also used to centre it under the card column.
let previewPeekTabWidth: CGFloat = 132

/// The collapsed "peek" representation of the overlay: a small tab tucked
/// against the bottom edge with an up-chevron and a count label. Clicking it
/// expands the stack. Uses the system liquid-glass material so it matches the
/// rest of the app and gets native interactive hover/press feedback.
struct PreviewPeekTab: View {
    let title: String
    let onExpand: () -> Void

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 13,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 13,
            style: .continuous
        )
    }

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(minWidth: previewPeekTabWidth)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: shape)
        .overlay {
            shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .help("Show recent captures")
    }
}
