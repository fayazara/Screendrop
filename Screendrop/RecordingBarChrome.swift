//
//  RecordingBarChrome.swift
//  Screendrop
//
//  Shared chrome for the floating recording bar — its geometry and the
//  control style both of its modes are built from. The pre-record picker and
//  the in-session controls are the same bar with different contents, not two
//  bars that resemble each other, which is what lets one morph into the other.
//

import AppKit
import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 66
    static let cornerRadius: CGFloat = 16
    static let itemSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 12

    /// Transparent slack around the bar so the shadow Liquid Glass casts
    /// isn't clipped by the panel edge. The panel is positioned lower by
    /// exactly this much so the bar itself doesn't move.
    static let shadowSlack: CGFloat = 28

    /// The panel is a fixed size that both modes sit centred inside, so
    /// morphing between them never resizes the window — only the bar's own
    /// rounded rect animates. Comfortably wider than the widest mode.
    static let panelWidth: CGFloat = 760
    static var panelHeight: CGFloat { height + shadowSlack * 2 }

    /// The bar's surface is Liquid Glass, which brings its own fill and
    /// shadow. These are the marks drawn on top of it.
    ///
    /// They're all AppKit label colours rather than SwiftUI's `.primary` and
    /// friends. Hierarchical styles also resolve against the *control* active
    /// state, and this bar lives in a `.nonactivatingPanel` that never becomes
    /// key — so `.primary` renders dimmed to near-invisible inside a `Button`
    /// while a `Menu` label right beside it stays full strength. These invert
    /// with the appearance and nothing else.
    static let activeTint = Color(nsColor: .labelColor)
    /// A control that's off is dimmed, never shrunk — the target stays the
    /// same size whichever state it's in.
    static let inactiveTint = Color(nsColor: .labelColor).opacity(0.4)
    static let stroke = Color(nsColor: .separatorColor)
    /// A hairline to define the pill's edge against a background of the same
    /// brightness — grey in light mode, white in dark, and faint in both.
    static let edge = Color(nsColor: .labelColor).opacity(0.12)
    /// Stop and the recording dot. The system red so it stays legible
    /// whichever variant the glass is in.
    static let recordTint = Color(nsColor: .systemRed)

    /// The morph between modes. Enough travel to read as one bar changing
    /// shape rather than two bars swapping.
    static let modeChange = Animation.spring(response: 0.34, dampingFraction: 0.86)
}

// MARK: - Controls

/// The bar's only control shape: icon over label, sized for a comfortable
/// pointer target rather than for the icon. Used bare as a `Menu` label and
/// wrapped by `BarActionButton` everywhere else.
///
/// The label under each icon is why the bar carries no tooltips — every
/// control already says what it is.
struct BarActionLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = BarMetrics.activeTint

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .frame(height: 22)
            Text(title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.3))
        .frame(width: 56, height: 46)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Every control here is clickable, including the ones that are only a
        // Menu's label; a disabled one shouldn't claim to be.
        .pointerStyle(isEnabled ? .link : nil)
    }
}

/// Renders the label and nothing else.
///
/// `.plain` isn't neutral on macOS: it still fades its content for the
/// inactive control state, and this bar lives in a `.nonactivatingPanel` that
/// never becomes key — so every button reads as permanently disabled no matter
/// what colour it's given. Owning `makeBody` opts out of that, and buys a real
/// press state on the way past.
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct BarActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = BarMetrics.activeTint
    /// Only worth setting where the visible label leaves something out — the
    /// device a control is bound to, what a destructive action destroys.
    var accessibility: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BarActionLabel(title: title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(BarButtonStyle())
        .accessibilityLabel(accessibility ?? title)
    }
}

struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(BarMetrics.stroke)
            .frame(width: 1, height: 34)
            .padding(.horizontal, 4)
    }
}
