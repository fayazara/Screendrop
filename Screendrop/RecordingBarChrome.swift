//
//  RecordingBarChrome.swift
//  Screendrop
//
//  Shared chrome for the floating recording bar — its geometry and the
//  control style both of its modes are built from. The pre-record picker and
//  the in-session controls are the same bar with different contents, not two
//  bars that resemble each other, which is what lets one morph into the other.
//

import SwiftUI

enum BarMetrics {
    static let height: CGFloat = 66
    static let cornerRadius: CGFloat = 16
    static let itemSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 12

    /// Transparent slack around the bar so its drop shadow isn't clipped by
    /// the panel edge. The panel is positioned lower by exactly this much so
    /// the bar itself doesn't move.
    static let shadowSlack: CGFloat = 28

    /// The panel is a fixed size that both modes sit centred inside, so
    /// morphing between them never resizes the window — only the bar's own
    /// rounded rect animates. Comfortably wider than the widest mode.
    static let panelWidth: CGFloat = 760
    static var panelHeight: CGFloat { height + shadowSlack * 2 }

    static let fill = Color(white: 0.14).opacity(0.97)
    static let stroke = Color.white.opacity(0.14)
    /// A control that's off is dimmed, never shrunk — the target stays the
    /// same size whichever state it's in.
    static let inactiveTint = Color.white.opacity(0.35)

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
    var tint: Color = .white

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
    }
}

struct BarActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .white
    /// Only worth setting where the visible label leaves something out — the
    /// device a control is bound to, what a destructive action destroys.
    var accessibility: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BarActionLabel(title: title, systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
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
