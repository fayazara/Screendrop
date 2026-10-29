//
//  GlassControls.swift
//  Screendrop
//
//  Liquid Glass building blocks for chrome: editor toolbars and docks, the
//  floating recording bar, HUDs, the Library's action bar and Settings'
//  buttons. Each control is one glass shape; callers group them in a
//  `GlassEffectContainer` and give each a `glassEffectID` so controls that
//  appear or leave are born out of, and melt back into, their neighbours
//  instead of fading in place.
//
//  The container's spacing must stay below the resting gap between shapes:
//  glass closer than the container spacing merges, so a wider resting gap is
//  what lets a shape settle as its own clean capsule after the morph.
//
//  A selected or prominent control is filled with the system accent
//  (`Palette.accent`, called "inked" below); every other control is clear
//  glass with label-colored glyphs.
//

import AppKit
import SwiftUI

enum GlassMetrics {
    /// Glass closer than this melts together while shapes move.
    static let containerSpacing: CGFloat = 6
    /// Resting gap between neighbouring glass shapes; wider than
    /// `containerSpacing` so settled shapes stand apart.
    static let gap: CGFloat = 8
    /// Small icon buttons in docks and floating bars.
    static let buttonSize: CGFloat = 30
    /// Compact buttons inside forms and lists.
    static let compactHeight: CGFloat = 26
    /// Primary actions, such as an inspector footer's export capsule.
    static let actionHeight: CGFloat = 34
    /// Glyph size inside a `buttonSize` control.
    static let symbolSize: CGFloat = 12
}

private extension Glass {
    /// Clear glass, accent glass when selected or prominent, or a functional tint.
    static func screendrop(isInked: Bool, tint: Color?, isEnabled: Bool) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tint)
        } else if isInked {
            glass = glass.tint(Palette.accent.opacity(isEnabled ? 1 : 0.35))
        }
        return glass.interactive(isEnabled)
    }
}

private func glassForeground(isInked: Bool, tint: Color?, isEnabled: Bool) -> Color {
    if tint != nil { return .white.opacity(isEnabled ? 1 : 0.5) }
    if isInked { return Palette.onAccent.opacity(isEnabled ? 1 : 0.5) }
    return isEnabled ? Palette.label : Palette.disabledLabel
}

// MARK: - Buttons

/// A round glass icon button. `isOn` inks it solid, for the selected tool in
/// a dock. Disabled buttons keep their glass but drop the interactive press
/// response and dim their glyph.
struct GlassIconButton: View {
    let systemImage: String
    let help: String
    var size: CGFloat = GlassMetrics.buttonSize
    var symbolSize: CGFloat = GlassMetrics.symbolSize
    var isOn = false
    /// A functional color such as `Palette.record`; wins over `isOn`.
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(glassForeground(isInked: isOn, tint: tint, isEnabled: isEnabled))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.screendrop(isInked: isOn, tint: tint, isEnabled: isEnabled), in: .circle)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A glass capsule holding an optional icon and a title. `isProminent` inks
/// it solid for the one primary action of a surface.
struct GlassCapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = GlassMetrics.buttonSize
    var isProminent = false
    /// A functional color such as `Palette.record`; wins over `isProminent`.
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: height < 28 ? 10.5 : GlassMetrics.symbolSize - 1, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
                Text(title)
                    .font(.system(size: height < 28 ? 11.5 : 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.interpolate)
            }
            .foregroundStyle(glassForeground(isInked: isProminent, tint: tint, isEnabled: isEnabled))
            .padding(.horizontal, height < 28 ? 11 : 13)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.screendrop(isInked: isProminent, tint: tint, isEnabled: isEnabled), in: .capsule)
    }
}

/// A glass capsule that opens a menu, drawn like `GlassCapsuleButton` with a
/// quiet chevron so it reads as a choice rather than an action.
struct GlassMenuButton<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = GlassMetrics.buttonSize
    var help: String? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: GlassMetrics.symbolSize - 1, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: height < 28 ? 11.5 : 12, weight: .semibold))
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.secondaryLabel)
            }
            .foregroundStyle(isEnabled ? Palette.label : Palette.disabledLabel)
            .padding(.horizontal, height < 28 ? 11 : 13)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular.interactive(isEnabled), in: .capsule)
        .help(help ?? title)
    }
}

/// An action whose glyph confirms it: the icon blurs into a check for a
/// moment after the action runs, then settles back. For Copy and friends,
/// where the result is otherwise invisible.
struct GlassConfirmButton: View {
    let systemImage: String
    let help: String
    var confirmation: String = "Copied"
    var size: CGFloat = GlassMetrics.buttonSize
    let action: () -> Void

    @State private var confirmed = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        GlassIconButton(
            systemImage: confirmed ? "checkmark" : systemImage,
            help: confirmed ? confirmation : help,
            size: size
        ) {
            action()
            confirmed = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                confirmed = false
            }
        }
        .motion(.morphQuick, value: confirmed)
        .onDisappear { resetTask?.cancel() }
    }
}

// MARK: - Action capsule

/// A primary action that carries its own job. Idle it reads as a button;
/// running, the capsule fills with ink as its own progress bar and offers
/// Cancel on hover; when the job lands it flashes a check in green before
/// settling back. Collapsed, it folds to an icon-only circle so a sibling
/// action can take the room.
struct GlassActionCapsule: View {
    let title: String
    let systemImage: String
    /// Nil while idle; the job's 0...1 progress while it runs.
    var progress: Double? = nil
    /// Names the running stage ahead of the percentage, e.g. "Uploading".
    var stage: String? = nil
    /// A transient success message, shown with a check on green glass.
    var flash: String? = nil
    var isProminent = false
    var isCollapsed = false
    var height: CGFloat = GlassMetrics.actionHeight
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var isRunning: Bool { progress != nil }

    var body: some View {
        Button(action: action) {
            GeometryReader { proxy in
                let filled = proxy.size.width * min(max(progress ?? 0, 0), 1)
                ZStack(alignment: .leading) {
                    if isRunning {
                        Rectangle()
                            .fill(Palette.accent)
                            .frame(width: filled)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }

                    label.foregroundStyle(baseInk)

                    if isRunning {
                        // The same label in reverse ink, revealed only over
                        // the filled part of the capsule.
                        label
                            .foregroundStyle(Palette.onAccent)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: filled)
                            }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                .clipShape(Capsule())
                .motion(.smooth(duration: 0.35), value: progress)
            }
            .frame(height: height)
            .frame(minWidth: height, maxWidth: isCollapsed ? height : .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .capsule)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityValue(
            progress.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text("")
        )
    }

    @ViewBuilder
    private var label: some View {
        ZStack {
            if isCollapsed {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .transition(.blurPop)
            } else if let flash, !isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(flash)
                        .font(.system(size: 13, weight: .semibold))
                }
                .transition(AnyTransition(.blurReplace))
            } else if isRunning {
                Text(runningTitle)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .motion(.morphQuick, value: runningTitle)
                    .transition(AnyTransition(.blurReplace))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .transition(AnyTransition(.blurReplace))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }

    private var runningTitle: String {
        if isHovering { return "Cancel" }
        let percent = (progress ?? 0).formatted(.percent.precision(.fractionLength(0)))
        guard let stage else { return percent }
        return "\(stage) \(percent)"
    }

    private var baseInk: Color {
        if !isEnabled { return isProminent ? Palette.onAccent.opacity(0.5) : Palette.disabledLabel }
        if !isRunning, flash != nil { return .white }
        if !isRunning, isProminent { return Palette.onAccent }
        return Palette.label
    }

    private var glass: Glass {
        var glass = Glass.regular
        if !isRunning {
            if flash != nil, isEnabled {
                glass = glass.tint(Palette.success)
            } else if isProminent {
                glass = glass.tint(Palette.accent.opacity(isEnabled ? 1 : 0.45))
            }
        }
        return glass.interactive(isEnabled)
    }

    private var helpText: String {
        if isRunning { return "Cancel \(title)" }
        return title
    }
}

// MARK: - Small pieces

/// One keyboard key drawn as a small glass cap.
struct KeyCap: View {
    let label: String
    var isSmall = false

    var body: some View {
        Text(label)
            .font(.system(size: isSmall ? 10.5 : 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.label)
            .padding(.horizontal, label.count > 1 ? (isSmall ? 5 : 7) : 0)
            .frame(minWidth: isSmall ? 18 : 22, minHeight: isSmall ? 18 : 22)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: isSmall ? 5 : 6, style: .continuous))
    }
}

/// A shortcut as a row of key caps that melt together.
struct KeyCaps: View {
    let tokens: [String]
    var isSmall = false

    var body: some View {
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: isSmall ? 3 : 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    KeyCap(label: token, isSmall: isSmall)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tokens.joined())
    }
}

/// A quiet pill label, e.g. "Edited" or "Draft".
struct Tag: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8.5, weight: .bold))
            }
            Text(text)
                .font(.dsMicro)
        }
        .foregroundStyle(tint ?? Palette.secondaryLabel)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.14), in: Capsule())
    }
}

/// A small status light, e.g. a setting that needs attention.
struct StatusDot: View {
    var color: Color = Palette.success

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

// MARK: - HUD surface

extension View {
    /// The surface of floating HUDs and toasts: Liquid Glass with a hairline
    /// so it keeps its edge over content of the same brightness.
    func glassHUD(radius: CGFloat = Radius.hud) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return glassEffect(.regular, in: shape)
            .overlay { shape.strokeBorder(Color.ink.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false) }
    }
}

// MARK: - Empty state

/// What a surface shows when it has nothing yet: a glyph on glass, a title,
/// one line of guidance and the actions that fill it.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, Space.xs)

            Text(title)
                .font(.dsTitle)
                .foregroundStyle(Palette.label)

            Text(message)
                .font(.dsCallout)
                .foregroundStyle(Palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if Actions.self != EmptyView.self {
                GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                    HStack(spacing: GlassMetrics.gap) {
                        actions()
                    }
                }
                .padding(.top, Space.s)
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
