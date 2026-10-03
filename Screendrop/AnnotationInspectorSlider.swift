//
//  AnnotationInspectorSlider.swift
//  Screendrop
//

import AppKit
import SwiftUI

/// Display and editing rules for an inspector value. The bound value always
/// stays in model units; `multiplier` only transforms what the user sees and
/// types (for example, 0.45 is displayed as 45%).
struct InspectorValueFormat {
    let multiplier: CGFloat
    let fractionDigits: Int
    let suffix: String
    let showsPositiveSign: Bool
    let step: CGFloat
    let acceptedSuffixes: [String]

    static let integer = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 0,
        suffix: "",
        showsPositiveSign: false,
        step: 1,
        acceptedSuffixes: []
    )

    static let pixels = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 0,
        suffix: " px",
        showsPositiveSign: false,
        step: 1,
        acceptedSuffixes: ["pixels", "pixel", "px"]
    )

    static func percent(
        signed: Bool = false,
        fractionDigits: Int = 0
    ) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 100,
            fractionDigits: fractionDigits,
            suffix: "%",
            showsPositiveSign: signed,
            step: step(forFractionDigits: fractionDigits) / 100,
            acceptedSuffixes: ["%"]
        )
    }

    static func degrees(signed: Bool = false) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 1,
            fractionDigits: 0,
            suffix: "°",
            showsPositiveSign: signed,
            step: 1,
            acceptedSuffixes: ["degrees", "degree", "deg", "°"]
        )
    }

    static func decimal(fractionDigits: Int) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 1,
            fractionDigits: fractionDigits,
            suffix: "",
            showsPositiveSign: false,
            step: step(forFractionDigits: fractionDigits),
            acceptedSuffixes: []
        )
    }

    static func magnification(fractionDigits: Int) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 1,
            fractionDigits: fractionDigits,
            suffix: "×",
            showsPositiveSign: false,
            step: step(forFractionDigits: fractionDigits),
            acceptedSuffixes: ["×", "x"]
        )
    }

    func displayString(for value: CGFloat) -> String {
        let scaledValue = value * multiplier
        let number = formattedNumber(scaledValue)
        let sign = showsPositiveSign && roundedForDisplay(scaledValue) > 0 ? "+" : ""
        return sign + number + suffix
    }

    func editingString(for value: CGFloat) -> String {
        formattedNumber(value * multiplier)
    }

    func parse(_ text: String) -> CGFloat? {
        var numericText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")

        for acceptedSuffix in acceptedSuffixes {
            numericText = numericText.replacingOccurrences(
                of: acceptedSuffix,
                with: "",
                options: [.caseInsensitive, .anchored, .backwards]
            )
        }

        numericText = numericText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsed = try? FloatingPointFormatStyle<Double>.number
            .parseStrategy
            .parse(numericText), parsed.isFinite else {
            return nil
        }

        return CGFloat(parsed) / multiplier
    }

    private func formattedNumber(_ value: CGFloat) -> String {
        let normalizedValue = roundedForDisplay(value)
        return Double(normalizedValue).formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.never)
        )
    }

    private func roundedForDisplay(_ value: CGFloat) -> CGFloat {
        let scale = CGFloat(pow(10, Double(fractionDigits)))
        let rounded = (value * scale).rounded() / scale
        return abs(rounded) < CGFloat.ulpOfOne ? 0 : rounded
    }

    private static func step(forFractionDigits fractionDigits: Int) -> CGFloat {
        1 / CGFloat(pow(10, Double(max(fractionDigits, 0))))
    }
}

/// A Sketch-style scrub field: one quiet box with the label on the left and
/// the exact value on the right. Hovering the label shows a left/right resize
/// cursor; dragging nudges the value relative to where it started (right
/// increases, left decreases), and clicking the value edits it directly.
/// Hold Option while dragging for fine adjustments.
struct InspectorSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let format: InspectorValueFormat

    /// Points of horizontal drag that sweep the full range.
    private static let fullRangeDragDistance: CGFloat = 200
    private static let fineDragMultiplier: CGFloat = 0.1
    /// Drag distance around zero that lands exactly on zero for signed ranges.
    private static let zeroDetentDistance: CGFloat = 4
    private static let valueWidth: CGFloat = 46

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focusedPart: FocusedPart?
    @State private var draftText = ""
    @State private var editingBaselineText = ""
    @State private var valueSelection: TextSelection?
    @State private var isHovering = false
    @State private var dragStartValue: CGFloat?

    private enum FocusedPart: Hashable {
        case scrubber
        case value
    }

    init(
        _ title: LocalizedStringResource,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        format: InspectorValueFormat
    ) {
        self.init(String(localized: title), value: value, range: range, format: format)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(
        _ title: Title,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        format: InspectorValueFormat
    ) {
        self.title = String(title)
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)

        HStack(spacing: 4) {
            scrubHandle
            valueField
        }
        .frame(height: InspectorMetrics.controlHeight)
        .frame(maxWidth: .infinity)
        .background(shape.fill(fieldFill))
        .overlay {
            if focusedPart != nil {
                shape.stroke(Color.accentColor.opacity(0.72), lineWidth: 1)
            }
        }
        .onHover { isHovering = $0 }
        .onAppear(perform: syncDraftText)
        .onDisappear {
            if focusedPart == .value {
                commitDraftText()
            }
        }
        .onChange(of: value) { _, _ in
            syncDraftText()
        }
        .onChange(of: focusedPart) { oldPart, newPart in
            if newPart == .value {
                beginValueEditing()
            } else if oldPart == .value {
                commitDraftText()
            }
        }
    }

    private var scrubHandle: some View {
        Text(title)
            .font(.inspectorLabel)
            .foregroundStyle(isActive ? Color.primary.opacity(0.85) : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        if dragStartValue == nil {
                            if focusedPart == .value {
                                commitDraftText()
                            }
                            focusedPart = .scrubber
                            dragStartValue = value
                        }
                        scrub(by: drag.translation.width)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )
            .allowsHitTesting(isEnabled)
            .pointerStyle(isEnabled ? PointerStyle.columnResize : nil)
            .focusable(isEnabled)
            .focusEffectDisabled()
            .focused($focusedPart, equals: .scrubber)
            .onKeyPress(.leftArrow) {
                guard isEnabled else { return .ignored }
                adjustValue(by: -format.step)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard isEnabled else { return .ignored }
                adjustValue(by: format.step)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(format.displayString(for: value))
            .accessibilityHint("Drag horizontally to adjust, or edit the value field")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustValue(by: format.step)
                case .decrement:
                    adjustValue(by: -format.step)
                @unknown default:
                    break
                }
            }
    }

    private var valueField: some View {
        TextField(title, text: $draftText, selection: $valueSelection)
            .textFieldStyle(.plain)
            .font(.inspectorNumeric)
            .foregroundStyle(.primary.opacity(0.85))
            .multilineTextAlignment(.trailing)
            .frame(width: Self.valueWidth)
            .padding(.trailing, 8)
            .frame(maxHeight: .infinity)
            .focused($focusedPart, equals: .value)
            .onSubmit {
                commitDraftText()
                focusedPart = nil
            }
            .onExitCommand {
                draftText = editingBaselineText
                focusedPart = nil
            }
            .onKeyPress(.upArrow) {
                guard isEnabled else { return .ignored }
                commitDraftText()
                adjustValue(by: format.step)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard isEnabled else { return .ignored }
                commitDraftText()
                adjustValue(by: -format.step)
                return .handled
            }
            .accessibilityLabel("\(title) value")
            .help("Enter an exact value for \(title)")
    }

    private var isActive: Bool {
        isEnabled && (isHovering || dragStartValue != nil || focusedPart != nil)
    }

    private var fieldFill: Color {
        let base = InspectorControlPalette.trackFill(for: colorScheme)
        guard isActive else { return base }
        return colorScheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.06)
    }

    private func scrub(by translation: CGFloat) {
        guard let dragStartValue else { return }
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0 else { return }

        let isFine = NSEvent.modifierFlags.contains(.option)
        let perPoint = span / Self.fullRangeDragDistance * (isFine ? Self.fineDragMultiplier : 1)
        var proposed = dragStartValue + translation * perPoint

        // Soft detent: dragging through zero on a signed range rests on it
        // briefly. Typed and keyboard input stay precise and never snap.
        if range.lowerBound < 0, range.upperBound > 0,
           abs(proposed) <= perPoint * Self.zeroDetentDistance {
            proposed = 0
        }

        setValue(proposed)
    }

    private func adjustValue(by delta: CGFloat) {
        guard delta.isFinite else { return }
        setValue(value + delta)
    }

    private func setValue(_ proposedValue: CGFloat) {
        guard isEnabled,
              proposedValue.isFinite,
              range.lowerBound.isFinite,
              range.upperBound.isFinite else { return }

        // Pointer dragging stays continuous; `step` is reserved for keyboard
        // and accessibility nudges, so existing preset/document precision is
        // never silently quantized.
        let clampedValue = min(max(proposedValue, range.lowerBound), range.upperBound)
        guard clampedValue != value else { return }
        value = clampedValue
    }

    private func syncDraftText() {
        if focusedPart == .value {
            beginValueEditing()
        } else {
            draftText = format.displayString(for: value)
        }
    }

    private func beginValueEditing() {
        let editingText = format.editingString(for: value)
        editingBaselineText = editingText
        draftText = editingText
        valueSelection = TextSelection(range: editingText.startIndex..<editingText.endIndex)
    }

    private func commitDraftText() {
        guard draftText != editingBaselineText else {
            syncDraftText()
            return
        }

        guard let parsedValue = format.parse(draftText) else {
            syncDraftText()
            return
        }

        setValue(parsedValue)
        editingBaselineText = format.editingString(for: value)
        syncDraftText()
    }
}

/// Lays two related fields side by side at equal widths, the way Sketch pairs
/// X/Y and W/H.
struct InspectorFieldPair<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            leading()
                .frame(maxWidth: .infinity)
            trailing()
                .frame(maxWidth: .infinity)
        }
    }
}
