//
//  SettingsDecor.swift
//  Screendrop
//
//  The friendlier pieces of the Settings window: picture choices, the
//  shortcut well and the glass segmented choice.
//

import AppKit
import SwiftUI

// MARK: - Picture choices

/// One choice drawn as a small picture with its name under it, ringed when
/// it's picked.
struct SettingsVisualChoice<Picture: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var picture: () -> Picture

    private let pictureRadius: CGFloat = 8
    private let ringGap: CGFloat = 3

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                picture()
                    .frame(width: 120, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: pictureRadius, style: .continuous))
                    .hairline(radius: pictureRadius)
                    .padding(ringGap)
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: Radius.nested(inner: pictureRadius, padding: ringGap),
                            style: .continuous
                        )
                        .strokeBorder(Palette.accent, lineWidth: 2.5)
                        .opacity(isSelected ? 1 : 0)
                    }

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(.morphQuick, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A Mac desktop in miniature, for picture choices about where things
/// appear on screen: a solid blue wallpaper, a menu bar with the Apple menu,
/// app menus and a clock, and a Dock. It follows the appearance, as the real
/// desktop does: pale by day, a deep night blue in Dark Mode.
struct SettingsMiniDesktop<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }
    private var ink: Color { isDark ? .white.opacity(0.7) : .black.opacity(0.55) }

    var body: some View {
        (isDark ? Color(red: 0.13, green: 0.17, blue: 0.26) : Color(red: 0.80, green: 0.88, blue: 0.99))
            .overlay(alignment: .top) { menuBar }
            .overlay(alignment: .bottom) { dock }
            .overlay { content() }
    }

    private var menuBar: some View {
        HStack(spacing: 3) {
            Image(systemName: "apple.logo")
                .font(.system(size: 4.5, weight: .semibold))
                .foregroundStyle(ink)
            menuItem(width: 8, bold: true)
            menuItem(width: 5)
            menuItem(width: 6)
            menuItem(width: 5)
            Spacer(minLength: 0)
            menuItem(width: 4)
            menuItem(width: 10)
        }
        .padding(.horizontal, 5)
        .frame(height: 7)
        .background(isDark ? .black.opacity(0.35) : .white.opacity(0.6))
    }

    private func menuItem(width: CGFloat, bold: Bool = false) -> some View {
        Capsule()
            .fill(ink.opacity(bold ? 1 : 0.6))
            .frame(width: width, height: 1.6)
    }

    private var dock: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(.white.opacity(isDark ? 0.35 : 0.9))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(2)
        .background(.white.opacity(isDark ? 0.12 : 0.45), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .padding(.bottom, 3)
    }
}

// MARK: - Shortcut well

/// A shortcut as a field you click to record a new one: key caps at rest,
/// a prompt while recording.
struct SettingsShortcutWell: View {
    let tokens: [String]
    let isRecording: Bool
    let action: () -> Void

    private let radius: CGFloat = 7

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Text("Press keys…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.accent)
                        .phaseAnimator([1.0, 0.5]) { content, opacity in
                            content.opacity(opacity)
                        } animation: { _ in .easeInOut(duration: 0.7) }
                        .transition(.blurPop)
                } else {
                    Text(tokens.joined(separator: " "))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.label)
                        .transition(.blurPop)
                }
            }
            .frame(width: 112, height: 26)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.panel)
            }
            .overlay {
                // Flat: no shadow, just a faint neutral edge at rest and the
                // accent while listening.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        isRecording ? Palette.accent : Color.primary.opacity(0.08),
                        lineWidth: isRecording ? 1.5 : 1
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .motion(.morphQuick, value: isRecording)
        .help(isRecording ? "Press a new shortcut, or Esc to cancel" : "Click to record a new shortcut")
        .accessibilityLabel(isRecording ? "Recording shortcut" : tokens.joined())
    }
}

// MARK: - Segmented choice

/// A short set of choices as a capsule track with a Liquid Glass capsule
/// under the picked one, which slides when the choice changes. Labels stay
/// in label ink either way; the glass alone marks the choice.
struct SettingsSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var systemImage: ((Option) -> String?)? = nil

    @Namespace private var namespace
    @State private var hovered: Option?

    private let height: CGFloat = 28
    private let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(inset)
        .frame(height: height)
        .background(Capsule().fill(Palette.fill))
        .fixedSize()
    }

    private func segment(_ option: Option) -> some View {
        let isSelected = option == selection
        return Button {
            withAnimation(.morphQuick) { selection = option }
        } label: {
            HStack(spacing: 5) {
                if let symbol = systemImage?(option) {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .medium))
                }
                Text(title(option))
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background {
                if isSelected {
                    // Capsules are concentric at any inset, so the chip's
                    // ends stay parallel with the track's.
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular, in: Capsule())
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovered == option {
                    Capsule().fill(Palette.hoverFill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering in
            if isHovering {
                hovered = option
            } else if hovered == option {
                hovered = nil
            }
        }
        .accessibilityLabel(title(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
