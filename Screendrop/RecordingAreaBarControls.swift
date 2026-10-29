//
//  RecordingAreaBarControls.swift
//  Screendrop
//
//  The pill that hangs off the recording bar's trailing end while the area
//  picker is up: the selection's size in pixels, which can be typed over, a
//  swap between them, and the ratio it's locked to.
//
//  Every control in it is the same box - one height, one radius, one resting
//  fill - so the three read as a set. The radius is the pill's less the
//  inset, so the boxes sit concentric with the pill's corners.
//

import SwiftUI

enum AreaPillMetrics {
    static let boxHeight: CGFloat = 32
    static var inset: CGFloat { (BarMetrics.height - boxHeight) / 2 }
    static var boxRadius: CGFloat { BarMetrics.cornerRadius - inset }
    static let restingFill = Color(nsColor: .labelColor).opacity(0.06)
    static let font = Font.system(size: 13, weight: .medium).monospacedDigit()

    static var boxShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: boxRadius, style: .continuous)
    }
}

struct RecordingAreaBarPill: View {
    @State private var area = RecordingAreaSelectionPresenter.shared

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BarMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            RecordingAreaDimensionField(
                id: .areaWidth,
                title: "Width in pixels",
                prompt: "Width",
                value: area.selection?.pixelSize.width
            ) { area.setPixelWidth($0) }

            swapButton

            RecordingAreaDimensionField(
                id: .areaHeight,
                title: "Height in pixels",
                prompt: "Height",
                value: area.selection?.pixelSize.height
            ) { area.setPixelHeight($0) }

            RecordingAreaAspectMenu()
                .padding(.leading, 6)
        }
        .padding(.horizontal, AreaPillMetrics.inset)
        .frame(height: BarMetrics.height)
        .glassEffect(.regular, in: shape)
        .overlay {
            shape.strokeBorder(BarMetrics.edge, lineWidth: 0.5)
        }
    }

    /// The × between the two sizes turns the selection on its side. Nothing
    /// to turn until there's a selection or a ratio that isn't square.
    private var swapButton: some View {
        RecordingAreaSwapButton(isEnabled: area.selection != nil || (area.aspect.map { $0.width != $0.height } ?? false)) {
            area.swapOrientation()
        }
    }
}

// MARK: - Size field

/// One side of the selection, in pixels. Commits on Return or when focus
/// leaves; Esc puts back what was there. Either way the keyboard goes back
/// to the sheet, so the next Return records.
private struct RecordingAreaDimensionField: View {
    let id: BarTooltipID
    let title: String
    let prompt: String
    let value: Int?
    let onCommit: (Int) -> Void

    @State private var text = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // No prompt: a plain field's prompt ignores the field's font and
        // alignment. An empty, unfocused field shows a centred dash instead.
        TextField(prompt, text: $text)
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(AreaPillMetrics.font)
            .foregroundStyle(BarMetrics.activeTint)
            .focused($isFocused)
            .padding(.horizontal, 6)
            .frame(width: 60, height: AreaPillMetrics.boxHeight)
            .background {
                AreaPillMetrics.boxShape
                    .fill(isFocused || isHovering ? BarMetrics.hoverFill : AreaPillMetrics.restingFill)
            }
            .overlay {
                if text.isEmpty && !isFocused {
                    Text("–")
                        .font(AreaPillMetrics.font)
                        .foregroundStyle(BarMetrics.inactiveTint)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                AreaPillMetrics.boxShape
                    .strokeBorder(Palette.accent, lineWidth: 1.5)
                    .opacity(isFocused ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .modifier(RecordingAreaBarHover(id: id, title: title, isHovering: $isHovering))
            .onAppear { text = Self.display(value) }
            .onChange(of: value) { _, value in
                guard !isFocused else { return }
                text = Self.display(value)
            }
            .onChange(of: text) { _, newValue in
                let digits = String(newValue.filter(\.isNumber).prefix(5))
                if digits != newValue { text = digits }
            }
            .onChange(of: isFocused) { _, focused in
                guard !focused else { return }
                if let typed = Int(text), typed > 0, typed != value {
                    onCommit(typed)
                } else {
                    text = Self.display(value)
                }
            }
            .onSubmit {
                isFocused = false
                RecordingAreaSelectionPresenter.shared.focusSheet()
            }
            .onExitCommand {
                text = Self.display(value)
                isFocused = false
                RecordingAreaSelectionPresenter.shared.focusSheet()
            }
            .accessibilityLabel(title)
    }

    private static func display(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}

// MARK: - Swap

private struct RecordingAreaSwapButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @Environment(BarTooltipModel.self) private var tooltip: BarTooltipModel?
    @State private var isHovering = false

    var body: some View {
        Button {
            tooltip?.dismiss()
            action()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(BarMetrics.activeTint.opacity(isEnabled ? 0.7 : 0.3))
                .frame(width: 24, height: AreaPillMetrics.boxHeight)
                .background {
                    AreaPillMetrics.boxShape
                        .fill(BarMetrics.hoverFill)
                        .opacity(isHovering ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .contentShape(Rectangle())
                .modifier(RecordingAreaBarHover(id: .areaSwap, title: "Swap width and height", isHovering: $isHovering))
        }
        .buttonStyle(BarButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Swap width and height")
    }
}

// MARK: - Ratio

/// The ratio the selection is held to. Dimmed while freeform, like an input
/// that's off; full strength once a ratio is locked.
private struct RecordingAreaAspectMenu: View {
    @State private var area = RecordingAreaSelectionPresenter.shared
    @State private var isHovering = false

    var body: some View {
        Menu {
            Toggle(isOn: selection(nil)) {
                Text("Freeform")
            }
            if area.aspect == nil, let current = area.currentAspect {
                Button("Lock Current Ratio (\(current.title))") {
                    area.lockCurrentRatio()
                }
            }

            Section("Landscape") {
                ForEach(RecordingAreaAspect.landscapePresets, id: \.self, content: item)
            }
            Section {
                item(.square)
            }
            Section("Portrait") {
                ForEach(RecordingAreaAspect.portraitPresets, id: \.self, content: item)
            }

            if let aspect = area.aspect, !RecordingAreaAspect.allPresets.contains(aspect) {
                Section("Custom") {
                    item(aspect)
                }
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(BarButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(area.aspect.map { "Aspect ratio locked to \($0.title)" } ?? "Aspect ratio: freeform")
    }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: area.aspect?.isPortrait == true ? "rectangle.portrait" : "aspectratio")
                .font(.system(size: 13, weight: .regular))
            Text(area.aspect?.title ?? "Free")
                .font(AreaPillMetrics.font)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BarMetrics.inactiveTint)
        }
        .foregroundStyle(area.aspect == nil ? BarMetrics.inactiveTint : BarMetrics.activeTint)
        .padding(.horizontal, 10)
        .frame(height: AreaPillMetrics.boxHeight)
        .background {
            AreaPillMetrics.boxShape
                .fill(isHovering ? BarMetrics.hoverFill : AreaPillMetrics.restingFill)
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .contentShape(AreaPillMetrics.boxShape)
        .modifier(RecordingAreaBarHover(
            id: .areaAspect,
            title: area.aspect.map { "Locked to \($0.title)" } ?? "Aspect ratio",
            isHovering: $isHovering
        ))
    }

    private func item(_ aspect: RecordingAreaAspect) -> some View {
        Toggle(isOn: selection(aspect)) {
            Text(aspect.title)
            if let purpose = aspect.purpose {
                Text(purpose)
            }
        }
    }

    private func selection(_ aspect: RecordingAreaAspect?) -> Binding<Bool> {
        Binding {
            area.aspect == aspect
        } set: { _ in
            area.setAspect(aspect)
        }
    }
}

// MARK: - Hover

/// The puck and tooltip plumbing every bar control has (see
/// BarActionLabel), for the area controls that aren't icons.
private struct RecordingAreaBarHover: ViewModifier {
    let id: BarTooltipID
    let title: String
    @Binding var isHovering: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(BarTooltipModel.self) private var tooltip: BarTooltipModel?
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(BarCoordinateSpace.bar))
            } action: {
                frame = $0
            }
            .background {
                BarControlHover(isEnabled: isEnabled, onChange: setHovering)
            }
            .onChange(of: title) { _, title in
                guard isHovering else { return }
                tooltip?.hover(id: id, text: title, frame: frame)
            }
            .onDisappear {
                tooltip?.endHover(id: id)
            }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            tooltip?.hover(id: id, text: title, frame: frame)
        } else {
            tooltip?.endHover(id: id)
        }
    }
}
