//
//  AnnotationTextStyleControls.swift
//  Screendrop
//

import AppKit
import SwiftUI

struct AnnotationTextStyleControls: View {
    @Bindable var model: AnnotationEditorModel
    @State private var fontSizeText = ""
    @FocusState private var isFontSizeFieldFocused: Bool

    private let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted()
    }()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                fontFamilyMenu
                    .frame(minWidth: 0, maxWidth: .infinity)

                AnnotationColorWellMenu(selectedSwatch: model.selectedSwatch) { swatch in
                    model.setSwatch(swatch)
                }
            }

            HStack(spacing: 6) {
                fontSizeStepper

                Spacer()

                AnnotationInspectorSegmentedToggles(
                    options: TextStyleSegment.allCases,
                    isSelected: { segment in
                        switch segment {
                        case .bold: model.selectedTextIsBold
                        case .italic: model.selectedTextIsItalic
                        case .underline: model.selectedTextIsUnderline
                        }
                    },
                    onToggle: { segment in
                        switch segment {
                        case .bold: model.selectedTextIsBold.toggle()
                        case .italic: model.selectedTextIsItalic.toggle()
                        case .underline: model.selectedTextIsUnderline.toggle()
                        }
                    },
                    label: { segment in
                        Text(segment.title)
                            .font(segment.font)
                            .underline(segment == .underline)
                    }
                )
                .frame(width: 96)
            }

            AnnotationInspectorSegmentedControl(
                options: TextAlignmentSegment.allCases,
                selection: Binding(
                    get: { TextAlignmentSegment(model.selectedTextAlignment) },
                    set: { model.selectedTextAlignment = $0.nsTextAlignment }
                ),
                label: { segment in
                    Image(systemName: segment.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
            )
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncFontSizeText)
        .onDisappear(perform: commitFontSizeText)
        .onChange(of: model.selectedTextFontSize) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: model.selectedItemID) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: isFontSizeFieldFocused) { _, isFocused in
            if isFocused {
                syncFontSizeText()
            } else {
                commitFontSizeText()
            }
        }
    }

    private var fontFamilyMenu: some View {
        Menu {
            ForEach(fontFamilies, id: \.self) { family in
                Button {
                    model.selectedTextFontName = family
                } label: {
                    if model.selectedTextFontName == family {
                        Label(family, systemImage: "checkmark")
                    } else {
                        Text(family)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.selectedTextFontName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Font family")
    }

    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            Button {
                adjustFontSize(by: -1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Divider().frame(height: 14)

            TextField("", text: $fontSizeText)
                .focused($isFontSizeFieldFocused)
                .onSubmit(commitFontSizeText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 32)

            Divider().frame(height: 14)

            Button {
                adjustFontSize(by: 1)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private func syncFontSizeText() {
        fontSizeText = String(Int(model.selectedTextFontSize.rounded()))
    }

    private func commitFontSizeText() {
        let trimmedText = fontSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmedText) else {
            syncFontSizeText()
            return
        }

        let clampedSize = max(size.rounded(), Double(AnnotationTextMetrics.minimumFontSize))
        model.selectedTextFontSize = CGFloat(clampedSize)
        fontSizeText = String(Int(clampedSize))
    }

    private func adjustFontSize(by delta: CGFloat) {
        commitFontSizeText()
        let size = max(model.selectedTextFontSize + delta, AnnotationTextMetrics.minimumFontSize)
        model.selectedTextFontSize = size
        syncFontSizeText()
    }
}

private enum TextStyleSegment: CaseIterable, Hashable {
    case bold
    case italic
    case underline

    var title: String {
        switch self {
        case .bold: "B"
        case .italic: "I"
        case .underline: "U"
        }
    }

    var font: Font {
        switch self {
        case .bold:
            .system(size: 12, weight: .bold)
        case .italic:
            .system(size: 12, weight: .regular, design: .serif).italic()
        case .underline:
            .system(size: 12, weight: .regular)
        }
    }
}

private enum TextAlignmentSegment: CaseIterable, Hashable {
    case left
    case center
    case right
    case justified

    init(_ alignment: NSTextAlignment) {
        switch alignment {
        case .center:
            self = .center
        case .right:
            self = .right
        case .justified:
            self = .justified
        default:
            self = .left
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    var systemImage: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify.leading"
        }
    }
}

private struct AnnotationInspectorSegmentedControl<Option: Hashable, Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [Option]
    @Binding var selection: Option
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(controlBackground))
        .overlay(Capsule().stroke(controlBorder, lineWidth: 0.5))
    }

    private func segment(for option: Option) -> some View {
        let isSelected = selection == option

        return Button {
            selection = option
        } label: {
            label(option)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var controlBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var controlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(nsColor: .separatorColor).opacity(0.45)
    }
}

private struct AnnotationInspectorSegmentedToggles<Option: Hashable, Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [Option]
    let isSelected: (Option) -> Bool
    let onToggle: (Option) -> Void
    @ViewBuilder let label: (Option) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(controlBackground))
        .overlay(Capsule().stroke(controlBorder, lineWidth: 0.5))
    }

    private func segment(for option: Option) -> some View {
        let selected = isSelected(option)

        return Button {
            onToggle(option)
        } label: {
            label(option)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background {
            if selected {
                Capsule()
                    .fill(Color.accentColor)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var controlBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var controlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color(nsColor: .separatorColor).opacity(0.45)
    }
}
