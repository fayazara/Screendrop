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
/// against the bottom edge. A leading "x" clears the whole stack, and the rest
/// (up-chevron + count) expands it. Uses the system liquid-glass material so it
/// matches the rest of the app and gets native interactive hover/press feedback.
struct PreviewPeekTab: View {
    let title: String
    let onExpand: () -> Void
    let onDismissAll: () -> Void

    private let contentHeight: CGFloat = 24

    /// Leading space reserved inside the expand button so the title clears the
    /// dismiss control that's overlaid on the leading edge.
    private var leadingControlsWidth: CGFloat { contentHeight + 16 }

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
        // The expand button fills the entire pill so clicking anywhere toggles
        // the stack. The dismiss control is layered on top of the leading edge,
        // so taps there hit it first while the rest of the pill expands.
        Button(action: onExpand) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))

                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, leadingControlsWidth)
            .padding(.trailing, 16)
            .frame(height: contentHeight)
            .frame(minWidth: previewPeekTabWidth, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Show recent captures")
        .glassEffect(.regular.interactive(), in: shape)
        .overlay(alignment: .leading) {
            HStack(spacing: 2) {
                PeekDismissButton(diameter: contentHeight, action: onDismissAll)

                Divider()
                    .frame(height: 14)
            }
            .padding(.leading, 6)
        }
        .overlay {
            shape
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

/// Clear-all button for the peek tab with a generous circular hit target that
/// reveals a subtle circle on hover.
private struct PeekDismissButton: View {
    let diameter: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: diameter, height: diameter)
                .background {
                    Circle()
                        .fill(.secondary.opacity(isHovered ? 0.18 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .help("Dismiss all")
    }
}
