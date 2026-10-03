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
    /// Vertical padding above/below each section's content. Sections are
    /// separated by this whitespace alone - no rules - so it stays generous.
    static let sectionVerticalPadding: CGFloat = 14
    /// Gap between a section header and its content.
    static let headerSpacing: CGFloat = 10
    /// Gap between stacked rows inside a section.
    static let rowSpacing: CGFloat = 8
    /// Gap between a group sub-label and its content.
    static let groupLabelSpacing: CGFloat = 7
    /// Gap between labelled groups inside one section.
    static let groupSpacing: CGFloat = 16

    /// The one true height for every interactive field (scrub fields, menus,
    /// steppers, pickers, segmented controls).
    static let controlHeight: CGFloat = 28
    static let sliderHeight: CGFloat = controlHeight
    /// Corner radius for fields and segmented tracks.
    static let fieldRadius: CGFloat = 7
    static let sliderRadius: CGFloat = fieldRadius
    /// Shared inner inset for compound controls such as segmented pickers,
    /// tool grids, and placement surfaces.
    static let controlInset: CGFloat = 2
    /// Corner radius for square tiles (swatches, tool cells, wallpapers).
    static let tileRadius: CGFloat = 6

    /// Fixed width for left-aligned row labels so values line up.
    static let labelColumnWidth: CGFloat = 58
    /// Radius for inset list surfaces (subtitle list, transcript).
    static let listRadius: CGFloat = 8

    /// Inspector column widths shared by every editor.
    static let columnMinWidth: CGFloat = 260
    static let columnIdealWidth: CGFloat = 280
    static let columnMaxWidth: CGFloat = 440
}

enum InspectorControlPalette {
    /// The opaque surface every fill below is tuned against. Track and
    /// selection fills sit at 4–10% opacity, so they only read as a control
    /// when something solid is behind them - over a popover's vibrancy they
    /// wash out to nothing. Any presentation hosting these controls has to
    /// paint this itself.
    static func panelBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    static func trackFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
    }

    static func selectionFill(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
    }

    /// A selected segment or tool: a raised white chip in light mode, a
    /// brighter fill in dark mode. No outline in either.
    static func selectedChipFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.13) : .white
    }

    static func selectedChipShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .clear : Color.black.opacity(0.14)
    }

    static var hoverFill: Color { Color.primary.opacity(0.04) }
    static var border: Color { Color.primary.opacity(0.10) }
    static var selectedForeground: Color { Color.primary.opacity(0.92) }
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
    /// Text labels inside segmented controls.
    static let inspectorSegment = Font.system(size: 11, weight: .medium)
}

// MARK: - Field chrome

/// The uniform "field" background - a subtly filled, borderless rounded
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
                    .fill(InspectorControlPalette.trackFill(for: colorScheme))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

    init(
        title: LocalizedStringResource,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: String(localized: title), accessory: accessory, content: content)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(
        title: Title,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = String(title)
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.inspectorSectionHeader)
                    .foregroundStyle(.secondary)

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
    init(_ title: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// A compact accordion section for the inspector's heavier control groups.
/// The title and chevron toggle expansion while header accessories keep their
/// own independent hit targets.
struct InspectorDisclosureSection<Content: View, Accessory: View>: View {
    let title: String
    /// A short readout of the section's active state, shown while collapsed
    /// so the whole setup can be scanned without expanding anything.
    var summary: String? = nil
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(
        title: LocalizedStringResource,
        summary: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = String(localized: title)
        self.summary = summary
        self._isExpanded = isExpanded
        self.accessory = accessory
        self.content = content
    }

    @State private var isHeaderHovering = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: toggleExpansion) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.inspectorSectionHeader)
                            .foregroundStyle(isExpanded || isHeaderHovering ? Color.primary.opacity(0.85) : Color.secondary)
                            .fixedSize()

                        if let summary, !isExpanded {
                            Text(summary)
                                .font(.inspectorLabel)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .transition(.opacity)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(isExpanded ? Text("Collapse section") : Text("Expand section"))

                accessory()

                Button(action: toggleExpansion) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, InspectorMetrics.horizontalPadding)
            .frame(height: 36)
            .onHover { isHeaderHovering = $0 }

            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
                    content()
                        .padding(.horizontal, InspectorMetrics.horizontalPadding)
                        .padding(.top, 2)
                        .padding(.bottom, InspectorMetrics.sectionVerticalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // SwiftUI can paint a moving transition beyond its interpolated
            // layout height. Keep the disclosure body inside its own animated
            // bounds so it never overlaps the header or neighboring sections.
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityValue: String {
        let state = isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        guard let summary else { return state }
        return String(localized: "\(state), \(summary)", comment: "Accessibility value: section expansion state, then its summary")
    }

    private func toggleExpansion() {
        withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}

extension InspectorDisclosureSection where Accessory == EmptyView {
    init(
        _ title: LocalizedStringResource,
        summary: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            summary: summary,
            isExpanded: isExpanded,
            accessory: { EmptyView() },
            content: content
        )
    }
}

/// A small, restrained "clear" affordance for a section header's accessory
/// slot - an X that reads as an action without competing with the title.
/// Reserved for removing something; restoring defaults uses
/// `InspectorResetButton` so the two never look alike.
struct InspectorClearButton: View {
    let help: String
    let action: () -> Void

    init(help: LocalizedStringResource, action: @escaping () -> Void) {
        self.help = String(localized: help)
        self.action = action
    }

    @_disfavoredOverload
    init<Help: StringProtocol>(help: Help, action: @escaping () -> Void) {
        self.help = String(help)
        self.action = action
    }

    var body: some View {
        InspectorIconButton(systemName: "xmark", help: help, action: action)
    }
}

/// Restores a section's defaults from the header's accessory slot.
struct InspectorResetButton: View {
    let help: String
    let action: () -> Void

    init(help: LocalizedStringResource, action: @escaping () -> Void) {
        self.help = String(localized: help)
        self.action = action
    }

    @_disfavoredOverload
    init<Help: StringProtocol>(help: Help, action: @escaping () -> Void) {
        self.help = String(help)
        self.action = action
    }

    var body: some View {
        InspectorIconButton(systemName: "arrow.counterclockwise", help: help, action: action)
    }
}

/// The inspector's on/off switch for section headers. A compact capsule that
/// uses the panel's track and border tokens when off and the accent when on,
/// so it sits alongside the header's icon buttons instead of AppKit chrome.
struct InspectorToggle: View {
    let title: String
    @Binding var isOn: Bool

    private static let trackSize = CGSize(width: 26, height: 15)
    private static let knobInset: CGFloat = 2

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false

    init(_ title: LocalizedStringResource, isOn: Binding<Bool>) {
        self.init(String(localized: title), isOn: isOn)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(_ title: Title, isOn: Binding<Bool>) {
        self.title = String(title)
        self._isOn = isOn
    }

    var body: some View {
        Button {
            withAnimation(accessibilityReduceMotion ? nil : .snappy(duration: 0.16)) {
                isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(trackFill)
                .overlay {
                    Capsule().strokeBorder(
                        isOn ? Color.clear : InspectorControlPalette.border,
                        lineWidth: 0.5
                    )
                }
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .padding(Self.knobInset)
                }
                .frame(width: Self.trackSize.width, height: Self.trackSize.height)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(.isToggle)
    }

    private var trackFill: Color {
        if isOn {
            return isHovering && isEnabled ? Color.accentColor.opacity(0.88) : Color.accentColor
        }
        return Color.primary.opacity(isHovering && isEnabled ? 0.2 : 0.14)
    }
}

/// A labelled on/off row inside a section body.
struct InspectorToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: LocalizedStringResource, isOn: Binding<Bool>) {
        self.init(String(localized: title), isOn: isOn)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(_ title: Title, isOn: Binding<Bool>) {
        self.title = String(title)
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.inspectorLabel)
                .foregroundStyle(.primary.opacity(0.82))

            Spacer(minLength: 8)

            InspectorToggle(title, isOn: $isOn)
        }
        .frame(minHeight: InspectorMetrics.controlHeight)
    }
}

/// A full-width field-styled action: symbol plus title at the standard
/// control height. Destructive actions tint red; `isBusy` dims and blocks it.
struct InspectorActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    var isBusy = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    init(
        _ title: LocalizedStringResource,
        systemImage: String,
        role: ButtonRole? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(String(localized: title), systemImage: systemImage, role: role, isBusy: isBusy, action: action)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(
        _ title: Title,
        systemImage: String,
        role: ButtonRole? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = String(title)
        self.systemImage = systemImage
        self.role = role
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.inspectorValue)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .inspectorField()
            .overlay {
                if isHovering && isEnabled && !isBusy {
                    RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
                        .fill(InspectorControlPalette.hoverFill)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red.opacity(0.88) : Color.primary.opacity(0.85))
        .disabled(isBusy)
        .opacity(isEnabled && !isBusy ? 1 : 0.5)
        .onHover { isHovering = $0 }
    }
}

/// Muted explanatory copy inside a section. Reserved for empty states and
/// errors; routine guidance belongs in tooltips.
struct InspectorHint: View {
    let text: String
    var tint: Color? = nil

    init(_ text: LocalizedStringResource, tint: Color? = nil) {
        self.init(String(localized: text), tint: tint)
    }

    @_disfavoredOverload
    init<Text: StringProtocol>(_ text: Text, tint: Color? = nil) {
        self.text = String(text)
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.inspectorLabel)
            .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shared section-header action, with a larger hit area than its quiet glyph.
struct InspectorIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(InspectorIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The screenshot and recording preset bars use the same action treatment.
struct PresetBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringResource
    let help: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(InspectorIconButtonStyle())
        .help(Text(help))
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

private struct InspectorIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled && (isHovering || configuration.isPressed) ? Color.primary : Color.secondary)
            .background {
                Circle().fill(Color.primary.opacity(
                    isEnabled ? (configuration.isPressed ? 0.12 : isHovering ? 0.08 : 0) : 0
                ))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

/// A muted secondary label introducing a sub-group inside a section
/// (e.g. "Color", "Gradient", "Wallpaper").
struct InspectorGroupLabel: View {
    let title: String

    init(_ title: LocalizedStringResource) { self.title = String(localized: title) }

    @_disfavoredOverload
    init<Title: StringProtocol>(_ title: Title) { self.title = String(title) }

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

    init(_ title: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content) {
        self.title = String(localized: title)
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

/// Break between sections. Sections are separated by whitespace rather than
/// rules, so this only adds a little extra air.
struct InspectorSectionDivider: View {
    var body: some View {
        Color.clear
            .frame(height: 4)
            .accessibilityHidden(true)
    }
}

// MARK: - Segmented control

/// One unified segmented control used for every segmented picker in the panel.
/// It shares the slider's height, radius, neutral track and value fill so choice
/// controls and numeric controls read as one inspector system.
struct InspectorSegmented<Option: Hashable, Label: View>: View {
    let options: [Option]
    let isSelected: (Option) -> Bool
    let onTap: (Option) -> Void
    @ViewBuilder let label: (Option) -> Label

    var height: CGFloat = InspectorMetrics.sliderHeight
    var equalWidths: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredOption: Option?

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: InspectorMetrics.sliderRadius,
            style: .continuous
        )

        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(InspectorMetrics.controlInset)
        .frame(height: height)
        .background(shape.fill(trackFill))
        .clipShape(shape)
    }

    private func segment(for option: Option) -> some View {
        let selected = isSelected(option)
        let isHovering = hoveredOption == option
        let segmentRadius = InspectorMetrics.sliderRadius - InspectorMetrics.controlInset

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
        .foregroundStyle(selected ? InspectorControlPalette.selectedForeground : Color.secondary)
        .background {
            RoundedRectangle(cornerRadius: segmentRadius, style: .continuous)
                .fill(segmentFill(isSelected: selected, isHovering: isHovering))
                .shadow(
                    color: selected ? InspectorControlPalette.selectedChipShadow(for: colorScheme) : .clear,
                    radius: 1,
                    y: 0.5
                )
        }
        .onHover { isHovering in
            if isHovering {
                hoveredOption = option
            } else if hoveredOption == option {
                hoveredOption = nil
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var trackFill: Color {
        InspectorControlPalette.trackFill(for: colorScheme)
    }

    private func segmentFill(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected {
            return InspectorControlPalette.selectedChipFill(for: colorScheme)
        }
        return isHovering ? InspectorControlPalette.hoverFill : .clear
    }
}

// MARK: - Selectable tile

/// A square (or aspect-ratioed) tile with one consistent selection treatment:
/// a hairline border at rest, an accent ring when selected. Used for color,
/// gradient and wallpaper swatches so every picker tile reads identically.
struct InspectorTile<Content: View>: View {
    let title: String
    var aspectRatio: CGFloat = 1
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        title: LocalizedStringResource,
        aspectRatio: CGFloat = 1,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: String(localized: title), aspectRatio: aspectRatio,
            isSelected: isSelected, action: action, content: content
        )
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(
        title: Title,
        aspectRatio: CGFloat = 1,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = String(title)
        self.aspectRatio = aspectRatio
        self.isSelected = isSelected
        self.action = action
        self.content = content
    }

    private let cornerRadius = InspectorMetrics.tileRadius
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovering && isEnabled ? 0.3 : 0.12), lineWidth: 0.5)
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
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Custom background entry shares the grid's tile size and opens the native picker.
struct InspectorCustomBackgroundColorTile: View {
    @Binding var style: AnnotationBackgroundStyle
    var onSelect: () -> Void = {}

    private var currentColor: AnnotationBackgroundColor {
        if case .solid(let color) = style { return color }
        return .black
    }

    private var isSelected: Bool {
        if case .solid(let color) = style {
            return !AnnotationBackgroundColor.plainPresets.contains(color)
        }
        return false
    }

    var body: some View {
        InspectorTile(title: "Custom color", isSelected: isSelected) {
            AnnotationColorPanelBridge.shared.present(current: currentColor.nsColor) { color in
                onSelect()
                style = .solid(AnnotationBackgroundColor(custom: Color(nsColor: color)))
            }
        } content: {
            Rectangle()
                .fill(Color.primary.opacity(0.05))
                .overlay {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
        }
    }
}
