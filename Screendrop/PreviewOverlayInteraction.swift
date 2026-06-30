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
    required init(rootView: Content) {
        super.init(rootView: rootView)
        configureForPreviewPanel()
    }

    required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        configureForPreviewPanel()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

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

    private func configureForPreviewPanel() {
        sizingOptions = []
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
    /// passthrough hosting view. Pass `active: false` to stop reporting (e.g.
    /// while the view is slid off-screen) so it doesn't capture clicks at its
    /// resting layout position.
    func reportsInteractiveRect(active: Bool = true) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: InteractiveRectsKey.self,
                    value: active ? [proxy.frame(in: .global)] : []
                )
            }
        )
    }
}

/// Width of the peek tab — matched to the card width so the pill lines up
/// exactly under the card column.
let previewPeekTabWidth: CGFloat = previewCardSize.width

/// The collapsed "peek" representation of the overlay: a small tab tucked
/// against the bottom edge, the same width and x-position as the cards. The
/// leading end shows an up-chevron + count and expands the stack; the trailing
/// "x" clears it. Uses the system liquid-glass material so it matches the rest
/// of the app and gets native interactive hover/press feedback.
struct PreviewPeekTab: View {
    /// Height of the pill's inner content row.
    static let contentHeight: CGFloat = 24

    /// Full pill height: content height plus the top/bottom insets. Exposed so
    /// other surfaces (e.g. the annotation inspector) can reserve clearance for
    /// the floating pill.
    static let pillHeight: CGFloat = contentHeight + 18

    let title: String
    let onExpand: () -> Void
    let onDismissAll: () -> Void

    private var contentHeight: CGFloat { Self.contentHeight }
    private var pillHeight: CGFloat { Self.pillHeight }

    /// Trailing space reserved inside the expand button so the label clears the
    /// dismiss control that's overlaid on the trailing edge.
    private var trailingControlsWidth: CGFloat { contentHeight + 16 }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: 16,
            style: .continuous
        )
    }

    var body: some View {
        // The expand button fills the entire pill so clicking anywhere toggles
        // the stack. The dismiss control is layered on top of the trailing edge,
        // so taps there hit it first while the rest of the pill expands.
        Button(action: onExpand) {
            ZStack(alignment: .leading) {
                // A real, near-transparent hit surface. In this AppKit-backed
                // passthrough panel, contentShape alone can still leave only
                // rendered glyphs/text hittable; this gives SwiftUI a concrete
                // full-pill view to receive the click without changing visuals.
                Rectangle()
                    .fill(.black.opacity(0.001))

                HStack(spacing: 7) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))

                    Text(title)
                        .font(.system(size: 12, weight: .medium))

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .padding(.trailing, trailingControlsWidth)
            }
            // Concrete size so the label actually fills the pill. A plain button
            // proposes an unbounded size to its label, so maxWidth/maxHeight here
            // would collapse to the text size and shrink the tap target.
            .frame(width: previewPeekTabWidth, height: pillHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show recent captures")
        // Keep the dismiss control as part of the glass foreground content
        // (before .glassEffect) so the "x" gets the same vibrancy/appearance
        // adaptation as the chevron + label and stays visible in light mode.
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                Divider()
                    .frame(height: 14)

                PeekDismissButton(diameter: contentHeight, action: onDismissAll)
            }
            .padding(.trailing, 6)
        }
        .glassEffect(.regular.interactive(), in: shape)
        .overlay {
            // Match the cards' border exactly (colour, thickness, opacity).
            shape
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
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
