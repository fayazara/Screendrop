//
//  AnnotationInspectorStyle.swift
//  Screendrop
//
//  Shared design system for the annotation editor inspector. Every section is
//  built from these primitives so the panel reads as one consistent control:
//  a single control height, a single corner radius, one label style, one
//  section-header style, and a consistent spacing rhythm. Inspired by the
//  density and precision of pro creative tools (Sketch).
//

import AppKit
import SwiftUI

// MARK: - Tokens

enum InspectorMetrics {
    /// Horizontal inset applied to every section's content.
    static let horizontalPadding: CGFloat = 12
    /// Vertical padding above/below each section's content.
    static let sectionVerticalPadding: CGFloat = 12
    /// Gap between a section header and its content.
    static let headerSpacing: CGFloat = 10
    /// Gap between stacked rows inside a section.
    static let rowSpacing: CGFloat = 8
    /// Gap between a group sub-label and its content.
    static let groupLabelSpacing: CGFloat = 7

    /// The one true height for every interactive field (menus, steppers,
    /// pickers, segmented controls).
    static let controlHeight: CGFloat = 24
    /// Corner radius for fields and segmented tracks.
    static let fieldRadius: CGFloat = 5
    /// Corner radius for square tiles (swatches, tool cells, wallpapers).
    static let tileRadius: CGFloat = 6

    /// Fixed width for left-aligned row labels so values line up.
    static let labelColumnWidth: CGFloat = 58
}

// MARK: - Typography

extension Font {
    /// Section title, e.g. "Background". Title-case, quietly prominent.
    static let inspectorSectionHeader = Font.system(size: 11, weight: .semibold)
    /// Field / row label, e.g. "Color".
    static let inspectorLabel = Font.system(size: 11, weight: .regular)
    /// Value text rendered inside or beside a field.
    static let inspectorValue = Font.system(size: 11, weight: .medium)
    /// Numeric readout for sliders/steppers.
    static let inspectorNumeric = Font.system(size: 11, weight: .medium).monospacedDigit()
}

// MARK: - Field chrome

/// The uniform "field" background — a subtly filled, hairline-stroked rounded
/// rectangle at the standard control height. Used by every input affordance so
/// menus, steppers and pickers share one silhouette.
private struct InspectorFieldChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat?
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fill: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.035)
    }

    private var stroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
}

extension View {
    /// Applies the standard inspector field chrome.
    func inspectorField(
        height: CGFloat? = InspectorMetrics.controlHeight,
        cornerRadius: CGFloat = InspectorMetrics.fieldRadius
    ) -> some View {
        modifier(InspectorFieldChrome(height: height, cornerRadius: cornerRadius))
    }
}

// MARK: - Section

/// A titled section with consistent padding. An optional trailing accessory
/// (reset, add, info) sits opposite the title, the way Sketch decorates its
/// inspector groups.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.inspectorSectionHeader)
                    .foregroundStyle(.primary.opacity(0.85))

                Spacer(minLength: 0)

                accessory()
            }

            content()
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.vertical, InspectorMetrics.sectionVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// A small, restrained "clear" affordance for a section header's accessory
/// slot — an X that reads as an action without competing with the title.
struct InspectorClearButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(isHovering ? Color.primary.opacity(0.10) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

/// A muted secondary label introducing a sub-group inside a section
/// (e.g. "Color", "Gradient", "Wallpaper").
struct InspectorGroupLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.inspectorLabel)
            .foregroundStyle(.secondary)
    }
}

/// A label + content row with a fixed-width label column so values align.
struct InspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.inspectorLabel)
                .foregroundStyle(.secondary)
                .frame(width: InspectorMetrics.labelColumnWidth, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Hairline divider between sections, matching the panel inset.
struct InspectorSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.45))
            .frame(height: 0.5)
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
    }
}

// MARK: - Segmented control

/// One unified segmented control used for every segmented picker in the panel
/// (text style, alignment, wallpaper source). The track uses liquid glass at
/// the standard field radius so the "glass" treatment is applied consistently,
/// and the active segment is filled with the accent color.
struct InspectorSegmented<Option: Hashable, Label: View>: View {
    let options: [Option]
    let isSelected: (Option) -> Bool
    let onTap: (Option) -> Void
    @ViewBuilder let label: (Option) -> Label

    var height: CGFloat = InspectorMetrics.controlHeight
    var equalWidths: Bool = true

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    segment(for: option)
                }
            }
            .padding(2)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
            )
        }
        .frame(height: height)
    }

    private func segment(for option: Option) -> some View {
        let selected = isSelected(option)
        let segmentRadius = InspectorMetrics.fieldRadius - 2

        return Button {
            onTap(option)
        } label: {
            label(option)
                .frame(maxWidth: equalWidths ? .infinity : nil)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, equalWidths ? 0 : 11)
                .contentShape(RoundedRectangle(cornerRadius: segmentRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: segmentRadius, style: .continuous)
                    .fill(Color.accentColor)
                    .padding(1)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Slider

/// A labeled slider with an optional right-aligned numeric readout, matching
/// the pro-panel convention of always surfacing the underlying value.
struct InspectorSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var formatted: ((CGFloat) -> String)?

    init(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        formatted: ((CGFloat) -> String)? = nil
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.formatted = formatted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.inspectorLabel)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if let formatted {
                    Text(formatted(value))
                        .font(.inspectorNumeric)
                        .foregroundStyle(.secondary)
                }
            }

            Slider(value: $value, in: range)
                .controlSize(.mini)
                .tint(.accentColor)
        }
    }
}

// MARK: - Selectable tile

/// A square (or aspect-ratioed) tile with one consistent selection treatment:
/// a hairline border at rest, an accent ring when selected. Used for color,
/// gradient and wallpaper swatches so every picker tile reads identically.
struct InspectorTile<Content: View>: View {
    var aspectRatio: CGFloat = 1
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    private let cornerRadius = InspectorMetrics.tileRadius

    var body: some View {
        Button(action: action) {
            content()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .padding(2.5)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: cornerRadius + 2.5, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
