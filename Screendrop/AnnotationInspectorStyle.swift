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
    static let controlHeight: CGFloat = 32
    static let sliderHeight: CGFloat = controlHeight
    /// Corner radius for fields and segmented tracks.
    static let fieldRadius: CGFloat = 8
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
        Palette.panel
    }

    static func trackFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.04)
    }

    static func selectionFill(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
    }

    /// A selected tool cell: a raised white chip in light mode, a brighter
    /// fill in dark mode. No outline in either.
    static func selectedChipFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.13) : .white
    }

    static func selectedChipShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .clear : Color.black.opacity(0.14)
    }

    static var hoverFill: Color { Palette.hoverFill.opacity(0.6) }
    static var border: Color { Palette.hairline }
    static var selectedForeground: Color { Palette.label }
    /// The ring around a selected swatch or tile.
    static var selectionRing: Color { Palette.accent }
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

/// One inspector section, shared by every editor: a title row and a body,
/// separated from the next section by whitespace alone.
///
/// A section folds in one of two ways. A feature with an on/off state passes
/// `isOn`; its switch sits at the end of the title row and turning it off
/// folds the body away. A heavy group with no state of its own passes
/// `isExpanded` and gets a chevron instead. Either way a folded section can
/// show a one-line `summary` so the setup can be scanned without opening it.
/// `symbol` marks sections that edit a selection rather than the document.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    var summary: String? = nil
    var symbol: String? = nil
    var isOn: Binding<Bool>? = nil
    var toggleTitle: String = ""
    var isExpanded: Binding<Bool>? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @State private var isHeaderHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsContent: Bool {
        (isOn?.wrappedValue ?? true) && (isExpanded?.wrappedValue ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if showsContent {
                content()
                    .padding(.top, InspectorMetrics.headerSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, InspectorMetrics.horizontalPadding)
        .padding(.vertical, InspectorMetrics.sectionVerticalPadding / 2 + 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The folding body never paints over the next section mid-fold.
        .clipped()
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: toggleExpansion) {
                HStack(spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.highlight)
                    }

                    Text(title)
                        .font(.inspectorSectionHeader)
                        .foregroundStyle(titleColor)
                        .fixedSize()

                    // The fold mark rides beside the title rather than at
                    // the row's end, so every section's switch and reset
                    // button share one trailing column with the switches
                    // in the section bodies.
                    if let isExpanded {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.tertiaryLabel)
                            .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                            .opacity(isHeaderHovering || !isExpanded.wrappedValue ? 1 : 0.6)
                            .accessibilityHidden(true)
                    }

                    if let summary, !showsContent {
                        Text(summary)
                            .font(.inspectorLabel)
                            .foregroundStyle(Palette.tertiaryLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .transition(.opacity)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Not `.disabled`: that dims the title, so a section that
            // can't fold (Canvas) read as a sub-label of the one above.
            .allowsHitTesting(isExpanded != nil)
            .accessibilityLabel(title)
            .accessibilityValue(summary ?? "")
            .accessibilityHint(isExpanded.map { $0.wrappedValue ? "Collapse" : "Expand" } ?? "")
            .accessibilityAddTraits(.isHeader)

            accessory()

            if let isOn {
                InspectorToggle(
                    toggleTitle.isEmpty ? title : toggleTitle,
                    isOn: Binding(
                        get: { isOn.wrappedValue },
                        set: { value in
                            withAnimation(.foldIfAllowed) { isOn.wrappedValue = value }
                        }
                    )
                )
            }

        }
        .onHover { isHeaderHovering = $0 }
    }

    private var titleColor: Color {
        if showsContent || (isExpanded != nil && isHeaderHovering) {
            return Palette.label.opacity(0.95)
        }
        return Palette.secondaryLabel
    }

    private func toggleExpansion() {
        guard let isExpanded else { return }
        withAnimation(.foldIfAllowed) {
            isExpanded.wrappedValue.toggle()
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(
        _ title: String,
        summary: String? = nil,
        symbol: String? = nil,
        isOn: Binding<Bool>? = nil,
        toggleTitle: String = "",
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            summary: summary,
            symbol: symbol,
            isOn: isOn,
            toggleTitle: toggleTitle,
            isExpanded: isExpanded,
            accessory: { EmptyView() },
            content: content
        )
    }
}

extension InspectorSection {
    init(
        _ title: String,
        summary: String? = nil,
        symbol: String? = nil,
        isOn: Binding<Bool>? = nil,
        toggleTitle: String = "",
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            summary: summary,
            symbol: symbol,
            isOn: isOn,
            toggleTitle: toggleTitle,
            isExpanded: isExpanded,
            accessory: accessory,
            content: content
        )
    }
}

/// The break between groups of related sections: more air than separates
/// sections within a group, and no rule.
struct InspectorGroupBreak: View {
    var body: some View {
        Color.clear
            .frame(height: 16)
            .accessibilityHidden(true)
    }
}

/// A small, restrained "clear" affordance for a section header's accessory
/// slot - an X that reads as an action without competing with the title.
/// Reserved for removing something; restoring defaults uses
/// `InspectorResetButton` so the two never look alike.
struct InspectorClearButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        InspectorIconButton(systemName: "xmark", help: help, action: action)
    }
}

/// Restores a section's defaults from the header's accessory slot.
struct InspectorResetButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        InspectorIconButton(systemName: "arrow.counterclockwise", help: help, action: action)
    }
}

/// Screendrop's one on/off switch: an ink track with a knob that springs
/// across. Inspectors use the small size in section headers; Settings forms
/// get the regular size through `.toggleStyle(.ink)`.
struct InspectorToggle: View {
    enum Size {
        case small
        case regular

        var track: CGSize {
            switch self {
            case .small: CGSize(width: 26, height: 15)
            case .regular: CGSize(width: 34, height: 20)
            }
        }
    }

    let title: String
    @Binding var isOn: Bool
    var size: Size = .regular

    private static let knobInset: CGFloat = 2

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovering = false

    init(_ title: String, isOn: Binding<Bool>, size: Size = .regular) {
        self.title = title
        self._isOn = isOn
        self.size = size
    }

    var body: some View {
        Button {
            withAnimation(accessibilityReduceMotion ? nil : .morphQuick) {
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
                        .fill(isOn ? Palette.onAccent : Color.white)
                        .shadow(color: .black.opacity(isOn ? 0 : 0.2), radius: 1, y: 0.5)
                        .padding(Self.knobInset)
                }
                .frame(width: size.track.width, height: size.track.height)
                .frame(height: max(24, size.track.height))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private var trackFill: Color {
        if isOn {
            return isHovering && isEnabled ? Palette.accent.opacity(0.82) : Palette.accent
        }
        return Color.primary.opacity(isHovering && isEnabled ? 0.2 : 0.14)
    }
}

/// The app's accent switch as a form toggle: the label on the leading edge, the
/// switch trailing, the way a native switch sits in a grouped form.
struct InkSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            InspectorToggle("", isOn: configuration.$isOn, size: .regular)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

extension ToggleStyle where Self == InkSwitchToggleStyle {
    static var ink: InkSwitchToggleStyle { InkSwitchToggleStyle() }
}

/// A labelled on/off row inside a section body.
struct InspectorToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
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
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
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
        .foregroundStyle(role == .destructive ? Palette.record.opacity(0.88) : Color.primary.opacity(0.85))
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

    init(_ text: String, tint: Color? = nil) {
        self.text = text
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

// MARK: - Segmented control

/// One segmented control for every choice in the panel. Its track is the
/// same filled rounded rectangle as every field and slider, and the selected
/// option sits on a plain chip inset concentrically inside it - white in
/// light mode, a lighter grey in dark - like the selected tool cells. The
/// chip jumps to the new option rather than sliding. It keeps the inspector's one control height so it lines up with
/// sliders and fields.
struct InspectorSegmented<Option: Hashable, Label: View>: View {
    let options: [Option]
    let isSelected: (Option) -> Bool
    let onTap: (Option) -> Void
    @ViewBuilder let label: (Option) -> Label

    var height: CGFloat = InspectorMetrics.sliderHeight
    var equalWidths: Bool = true

    @State private var hoveredOption: Option?
    @Environment(\.colorScheme) private var colorScheme

    private static var inset: CGFloat { 3 }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(InspectorMetrics.fieldRadius, height / 2), style: .continuous)
    }

    /// Nested inside the track: its radius less the inset, never equal.
    private var segmentShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: max(0, min(InspectorMetrics.fieldRadius, height / 2) - Self.inset),
            style: .continuous
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(Self.inset)
        .frame(height: height)
        .background(trackShape.fill(InspectorControlPalette.trackFill(for: colorScheme)))
    }

    private func segment(for option: Option) -> some View {
        let selected = isSelected(option)
        let isHovering = hoveredOption == option

        return Button {
            onTap(option)
        } label: {
            label(option)
                .frame(maxWidth: equalWidths ? .infinity : nil)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, equalWidths ? 0 : 11)
                .background {
                    if selected {
                        segmentShape
                            .fill(InspectorControlPalette.selectedChipFill(for: colorScheme))
                            .shadow(color: InspectorControlPalette.selectedChipShadow(for: colorScheme), radius: 1, y: 0.5)
                    } else if isHovering {
                        segmentShape.fill(InspectorControlPalette.hoverFill)
                    }
                }
                .contentShape(segmentShape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .onHover { isHovering in
            if isHovering {
                hoveredOption = option
            } else if hoveredOption == option {
                hoveredOption = nil
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                            .strokeBorder(InspectorControlPalette.selectionRing, lineWidth: 2)
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

// MARK: - Popovers

/// The layout every option popover shares: a title, an optional line of
/// explanation, the controls, and Cancel beside one inked confirm button.
/// Popovers paint the panel surface so inspector fills keep reading as
/// controls over the popover's vibrancy.
struct InspectorPopover<Content: View>: View {
    let title: String
    var message: String? = nil
    let confirmTitle: String
    var isConfirmDisabled = false
    var width: CGFloat = 280
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.headerSpacing + 2) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.dsHeadline)
                    .foregroundStyle(Palette.label)
                if let message {
                    Text(message)
                        .font(.inspectorLabel)
                        .foregroundStyle(Palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()

            GlassEffectContainer(spacing: GlassMetrics.containerSpacing) {
                HStack(spacing: GlassMetrics.gap) {
                    Spacer(minLength: 0)
                    GlassCapsuleButton(title: "Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    GlassCapsuleButton(title: confirmTitle, isProminent: true, action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isConfirmDisabled)
                }
            }
            .padding(.top, 4)
        }
        .padding(Space.l + 2)
        .frame(width: width)
        .presentationBackground(Palette.panel)
    }
}

extension View {
    /// A plain text field drawn as an inspector field: filled, borderless,
    /// at the standard control height.
    func inspectorTextField() -> some View {
        textFieldStyle(.plain)
            .font(.inspectorValue)
            .padding(.horizontal, 10)
            .inspectorField()
    }
}
